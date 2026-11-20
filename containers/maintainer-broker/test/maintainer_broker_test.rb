# frozen_string_literal: true

require "json"
require "fileutils"
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/agentforge/maintainer_broker"

class MaintainerBrokerTest < Minitest::Test
  include AgentForge::MaintainerBroker

  TEST_SECRET = "test-only-placeholder-not-a-credential"

  class TestVerifier < ApprovalVerifier
    def initialize(claims)
      @claims = claims
    end

    def verify(evidence, now:)
      raise AuthorizationError, :invalid_approval_evidence unless evidence == "test-evidence"

      @claims
    end
  end

  class TestReplayStore < ApprovalReplayStore
    def initialize
      @nonces = {}
      @mutex = Mutex.new
    end

    def consume!(nonce:, expires_at:)
      @mutex.synchronize do
        return false if @nonces.key?(nonce)

        @nonces[nonce] = expires_at
        true
      end
    end
  end

  class TestContextProvider < ApprovalContextProvider
    def identities_for(_request)
      { "requester_id" => "requester-a", "agent_identity" => "agent-1" }
    end
  end

  class TestApprovalProvider < ApprovalProvider
    attr_reader :challenge

    def initialize(evidence: "test-evidence", error: nil)
      @evidence = evidence
      @error = error
    end

    def collect(challenge)
      @challenge = challenge
      raise @error if @error

      @evidence
    end
  end

  class TestEmergencyStop
    attr_reader :tripped

    def initialize(registry)
      @registry = registry
      @tripped = false
    end

    def assert_running!
      raise EmergencyStopError, :emergency_stop_active if @tripped

      true
    end

    def trip!(**)
      @tripped = true
      @registry.revoke_all
      true
    end
  end

  class TestIssuer < CredentialIssuer
    attr_reader :events, :credential

    def initialize(now:)
      @now = now
      @events = []
    end

    def issue(request:, operation:)
      @events << :issue
      @credential = AgentForge::MaintainerBroker::Credential.new(
        secret: TEST_SECRET,
        repository: request.repository,
        permissions: operation.provider_permissions,
        expires_at: @now + 300
      )
    end

    def revoke(_credential)
      @events << :revoke
      true
    end

    def revoked_or_expired?(_credential, now:)
      @events << :verify_revocation
      true
    end
  end

  class FailingAuditSink
    def append(_record)
      raise AgentForge::MaintainerBroker::AuditFailure, :audit_unavailable
    end
  end

  class FalseAuditSink
    def append(_record)
      false
    end
  end

  def setup
    @directory = Dir.mktmpdir("agentforge-broker-test-")
    File.chmod(0o700, @directory)
    @audit_path = File.join(@directory, "events.jsonl")
    @audit = FileAuditSink.new(@audit_path)
    @now = Time.utc(2025, 1, 1, 12, 0, 0)
    @spec = OperationSpec.new(
      id: "test.noop",
      approval_count: 2,
      provider_permissions: ["test.permission"],
      api_actions: ["test.noop"]
    )
    @catalog = OperationCatalog.new([@spec])
    @policy = OperationPolicy.new(catalog: @catalog, enabled_operations: ["test.noop"])
    @issuer = TestIssuer.new(now: @now)
    @registry = ActiveCredentialRegistry.new(clock: -> { @now })
    @stop_controller = TestEmergencyStop.new(@registry)
    @claims = claims_for
    @broker = build_broker
  end

  def teardown
    FileUtils.remove_entry(@directory) if @directory && File.directory?(@directory)
  end

  def test_default_policy_denies_and_audits_without_issuing_credentials
    catalog = OperationCatalog.phase7a
    policy = OperationPolicy.new(catalog: catalog, enabled_operations: [])
    issuer = TestIssuer.new(now: @now)
    registry = ActiveCredentialRegistry.new(clock: -> { @now })
    broker = Broker.new(
      catalog: catalog,
      policy: policy,
      credential_issuer: issuer,
      credential_revoker: issuer,
      audit_sink: @audit,
      approval_workflow: build_approval_workflow(claims_for),
      emergency_stop: TestEmergencyStop.new(registry),
      credential_registry: registry,
      clock: -> { @now }
    )

    result = broker.execute(envelope(request: request_hash("pull_request.merge")))

    assert_equal "deny", result["decision"]
    assert_equal "operation_not_enabled", result["code"]
    assert_empty issuer.events
    assert_equal "denied", audit_records.last.fetch("event")
  end

  def test_unknown_operations_and_wildcard_targets_are_denied
    unknown = @broker.execute(envelope(request: request_hash("repository.admin")))
    wildcard = request_hash("test.noop").merge("resource" => "*")
    invalid_target = @broker.execute(envelope(request: wildcard))

    assert_equal "unknown_operation", unknown["code"]
    assert_equal "invalid_request", invalid_target["code"]
    assert_empty @issuer.events
  end

  def test_approval_is_bound_to_exact_request_and_short_lived
    mismatch = @broker.execute(
      envelope(request: request_hash("test.noop").merge("expected_revision" => "changed"))
    )
    expired_claims = claims_for(expires_at: @now - 1)
    expired_broker = build_broker(claims: expired_claims)
    expired = expired_broker.execute(envelope(request: request_hash("test.noop")))

    assert_equal "approval_binding_mismatch", mismatch["code"]
    assert_equal "approval_expired", expired["code"]
    assert_empty @issuer.events
  end

  def test_valid_test_operation_audits_before_issue_and_revokes_and_destroys_credential
    handler = lambda do |_request, credential|
      credential.with_secret { |secret| assert_equal TEST_SECRET, secret }
      true
    end
    broker = build_broker(handlers: { "test.noop" => handler })

    result = broker.execute(envelope(request: request_hash("test.noop")))

    assert_equal "allow", result["decision"]
    assert_equal %i[issue revoke verify_revocation], @issuer.events
    assert @issuer.credential.destroyed?
    assert_equal %w[intent completed], audit_records.map { |record| record.fetch("event") }
    assert_equal "maintainer-a,maintainer-b", audit_records.last.fetch("approver_ids")
    assert_equal '["test.permission"]', audit_records.last.fetch("credential_permissions")
    assert_equal "verified", audit_records.last.fetch("credential_revocation")
    refute_includes File.read(@audit_path), TEST_SECRET
    refute_includes result.inspect, TEST_SECRET
    refute_includes @issuer.credential.inspect, TEST_SECRET
    refute ENV.values.any? { |value| value.include?(TEST_SECRET) }
  end

  def test_approval_nonce_is_single_use_within_the_broker_process
    handler = ->(_request, _credential) { true }
    broker = build_broker(handlers: { "test.noop" => handler })

    first = broker.execute(envelope(request: request_hash("test.noop")))
    second = broker.execute(envelope(request: request_hash("test.noop")))

    assert_equal "allow", first["decision"]
    assert_equal "approval_replayed", second["code"]
    assert_equal 1, @issuer.events.count(:issue)
  end

  def test_audit_failure_denies_before_credential_issuance
    broker = build_broker(audit_sink: FailingAuditSink.new)

    result = broker.execute(envelope(request: request_hash("test.noop")))

    assert_equal "deny", result["decision"]
    assert_equal "audit_unavailable", result["code"]
    assert_empty @issuer.events
  end

  def test_false_audit_receipt_denies_before_credential_issuance
    broker = build_broker(audit_sink: FalseAuditSink.new)

    result = broker.execute(envelope(request: request_hash("test.noop")))

    assert_equal "deny", result["decision"]
    assert_equal "audit_unavailable", result["code"]
    assert_empty @issuer.events
    assert @stop_controller.tripped
  end

  def test_credential_scope_mismatch_denies_and_cleans_up
    wrong_scope_issuer = Class.new(TestIssuer) do
      def issue(request:, operation:)
        super.tap { |credential| credential.instance_variable_set(:@repository, "other/repo") }
      end
    end.new(now: @now)
    broker = build_broker(
      issuer: wrong_scope_issuer,
      handlers: { "test.noop" => ->(*) { flunk "handler must not run" } }
    )

    result = broker.execute(envelope(request: request_hash("test.noop")))

    assert_equal "deny", result["decision"]
    assert_equal "credential_scope_mismatch", result["code"]
    assert wrong_scope_issuer.credential.destroyed?
  end

  def test_credential_permission_mismatch_denies_and_cleans_up
    wrong_permission_issuer = Class.new(TestIssuer) do
      def issue(request:, operation:)
        super.tap { |credential| credential.instance_variable_set(:@permissions, []) }
      end
    end.new(now: @now)
    broker = build_broker(
      issuer: wrong_permission_issuer,
      handlers: { "test.noop" => ->(*) { flunk "handler must not run" } }
    )

    result = broker.execute(envelope(request: request_hash("test.noop")))

    assert_equal "deny", result["decision"]
    assert_equal "credential_permission_mismatch", result["code"]
    assert wrong_permission_issuer.credential.destroyed?
  end

  def test_credential_lifetime_over_one_hour_denies
    long_lived_issuer = Class.new(TestIssuer) do
      def issue(request:, operation:)
        super.tap { |credential| credential.instance_variable_set(:@expires_at, @now + 3601) }
      end
    end.new(now: @now)
    broker = build_broker(
      issuer: long_lived_issuer,
      handlers: { "test.noop" => ->(*) { flunk "handler must not run" } }
    )

    result = broker.execute(envelope(request: request_hash("test.noop")))

    assert_equal "deny", result["decision"]
    assert_equal "credential_lifetime_exceeded", result["code"]
    assert long_lived_issuer.credential.destroyed?
  end

  def test_unverified_revocation_denies
    revocation_failure_issuer = Class.new(TestIssuer) do
      def revoked_or_expired?(_credential, now:)
        false
      end
    end.new(now: @now)
    broker = build_broker(
      issuer: revocation_failure_issuer,
      handlers: { "test.noop" => ->(*) { true } }
    )

    result = broker.execute(envelope(request: request_hash("test.noop")))

    assert_equal "deny", result["decision"]
    assert_equal "credential_lifecycle_failed", result["code"]
    assert @stop_controller.tripped
    assert_equal 1, @registry.active_count
    refute revocation_failure_issuer.credential.destroyed?
  end

  def test_unmapped_operations_cannot_be_enabled
    error = assert_raises(ArgumentError) do
      OperationPolicy.new(
        catalog: OperationCatalog.phase7a,
        enabled_operations: ["pull_request.merge"]
      )
    end

    assert_equal "operation mapping is incomplete", error.message
  end

  def test_broker_source_does_not_expose_process_execution
    sources = %w[
      ../lib/agentforge/maintainer_broker.rb
      ../lib/agentforge/phase7b_controls.rb
      ../bin/maintainer-broker
    ].map { |relative_path| File.read(File.expand_path(relative_path, __dir__)) }

    sources.each do |source|
      refute_match(/(?:\b(?:Kernel\.)?(?:system|exec|spawn|fork)\s*(?:\(|$)|\b(?:IO\.)?popen\s*\(|\bOpen3\b)/, source)
    end
  end

  def test_file_audit_rejects_symlink_targets
    File.symlink("/dev/null", @audit_path)

    assert_raises(AuditFailure) do
      @audit.append(audit_record("denied", request_hash("test.noop"), "operation_not_enabled"))
    end
  end

  private

  def build_broker(claims: @claims, handlers: {}, audit_sink: @audit, issuer: @issuer)
    Broker.new(
      catalog: @catalog,
      policy: @policy,
      credential_issuer: issuer,
      credential_revoker: issuer,
      audit_sink: audit_sink,
      approval_workflow: build_approval_workflow(claims),
      emergency_stop: @stop_controller,
      credential_registry: @registry,
      handlers: handlers,
      clock: -> { @now }
    )
  end

  def build_approval_workflow(claims, provider: TestApprovalProvider.new)
    ApprovalWorkflow.new(
      context_provider: TestContextProvider.new,
      approval_provider: provider,
      verifier: TestVerifier.new(claims),
      replay_store: TestReplayStore.new,
      clock: -> { @now }
    )
  end

  def claims_for(expires_at: @now + 300)
    {
      "operation" => "test.noop",
      "repository" => "owner/repo",
      "resource" => "test-123",
      "expected_revision" => "abc123",
      "request_id" => "request-123",
      "policy_version" => POLICY_VERSION,
      "approver_ids" => %w[maintainer-a maintainer-b],
      "requester_id" => "requester-a",
      "agent_identity" => "agent-1",
      "issued_at" => @now.iso8601,
      "expires_at" => expires_at.iso8601,
      "nonce" => "0123456789abcdef"
    }
  end

  def request_hash(operation)
    {
      "operation" => operation,
      "repository" => "owner/repo",
      "resource" => "test-123",
      "expected_revision" => "abc123",
      "request_id" => "request-123",
      "policy_version" => POLICY_VERSION
    }
  end

  def envelope(request:)
    { "request" => request }
  end

  def audit_records
    return [] unless File.exist?(@audit_path)

    File.readlines(@audit_path, chomp: true).map { |line| JSON.parse(line) }
  end

  def audit_record(event, request, code)
    {
      "timestamp" => @now.iso8601(6),
      "event" => event,
      "event_id" => "test-event-123",
      "request_id" => request.fetch("request_id"),
      "operation" => request.fetch("operation"),
      "repository" => request.fetch("repository"),
      "resource" => request.fetch("resource"),
      "expected_revision" => request.fetch("expected_revision"),
      "policy_version" => request.fetch("policy_version"),
      "code" => code,
      "approver_ids" => "none",
      "requester_id" => "none",
      "agent_identity" => "none",
      "actor_id" => "none",
      "approval_expires_at" => "none",
      "credential_permissions" => "none",
      "credential_expires_at" => "none",
      "credential_revocation" => "not_issued"
    }
  end
end
