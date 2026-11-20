# frozen_string_literal: true

require "digest"
require "json"
require "minitest/autorun"
require_relative "../lib/agentforge/maintainer_broker"

class Phase7bControlsTest < Minitest::Test
  include AgentForge::MaintainerBroker

  TEST_SECRET = "phase7b-test-placeholder-not-a-credential"

  class ChainedAuditSink < DurableAuditSink
    attr_reader :records

    def initialize(domain:, failures: [], append_result: true, integrity_result: true)
      @domain = domain
      @failures = failures
      @append_result = append_result
      @integrity_result = integrity_result
      @records = []
      @digests = []
      @event_ids = []
    end

    def failure_domain_id
      @domain
    end

    def append(record)
      raise AgentForge::MaintainerBroker::AuditFailure, :injected_sink_failure if @failures.include?(record.fetch("event"))
      raise AgentForge::MaintainerBroker::AuditFailure, :duplicate_event if @event_ids.include?(record.fetch("event_id"))

      snapshot = JSON.parse(JSON.generate(record))
      @records << snapshot
      @event_ids << snapshot.fetch("event_id")
      previous = @digests.last || "agentforge-audit-genesis"
      @digests << Digest::SHA256.hexdigest(previous + JSON.generate(snapshot))
      @append_result
    end

    def verify_integrity!
      unless @records.length == @digests.length &&
             @records.length == @event_ids.length &&
             @records.map { |record| record.fetch("event_id") }.uniq.length == @records.length
        raise AgentForge::MaintainerBroker::AuditFailure, :audit_integrity_failure
      end

      previous = "agentforge-audit-genesis"
      @records.each_with_index do |record, index|
        expected = Digest::SHA256.hexdigest(previous + JSON.generate(record))
        raise AgentForge::MaintainerBroker::AuditFailure, :audit_integrity_failure unless expected == @digests[index]

        previous = expected
      end
      @integrity_result
    end

    def tamper!(index)
      @records.fetch(index)["code"] = "tampered"
    end

    def delete!(index)
      @records.delete_at(index)
    end
  end

  class ContextProvider < ApprovalContextProvider
    def identities_for(_request)
      { "requester_id" => "requester-a", "agent_identity" => "agent-1" }
    end
  end

  class MembershipClientFake < GitHubTeamMembershipClient
    attr_reader :calls

    def initialize(result: :active)
      @result = result
      @calls = []
    end

    def membership_state(organization_id:, team_id:, user_id:)
      @calls << [organization_id, team_id, user_id]
      @result
    end
  end

  class EvidenceClientFake < ApprovalEvidenceVerificationClient
    def initialize(response)
      @response = response
    end

    def verify(_evidence)
      @response
    end
  end

  class ReplayStoreFake < ApprovalReplayStore
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

  class ApprovalProviderFake < ApprovalProvider
    attr_reader :challenge, :calls

    def initialize(error: nil)
      @error = error
      @calls = 0
    end

    def collect(challenge)
      @calls += 1
      @challenge = challenge
      raise @error if @error

      "test-evidence"
    end
  end

  class VerifierFake < ApprovalVerifier
    def initialize(claims)
      @claims = claims
    end

    def verify(evidence, now:)
      raise AuthorizationError, :invalid_approval_evidence unless evidence == "test-evidence"

      @claims
    end
  end

  class StopStoreFake < EmergencyStopStateStore
    attr_reader :tripped

    def initialize(active_result: false, trip_result: true)
      @tripped = false
      @active_result = active_result
      @trip_result = trip_result
    end

    def active?
      @tripped || @active_result
    end

    def trip!
      return false unless @trip_result

      @tripped = true
      true
    end
  end

  class StopSupervisorFake < EmergencyStopSupervisor
    attr_reader :terminated_requests

    def initialize(admission_result: true, termination_result: true)
      @admission_result = admission_result
      @termination_result = termination_result
      @terminated_requests = []
    end

    def admission_allowed?
      @admission_result
    end

    def terminate_active!(request_id:)
      @terminated_requests << request_id
      @termination_result
    end
  end

  class IssuerFake < CredentialIssuer
    attr_reader :events, :credential

    def initialize(now:, revoke_result: true, verification_result: true)
      @now = now
      @revoke_result = revoke_result
      @verification_result = verification_result
      @events = []
    end

    def issue(request:, operation:)
      @events << :issue
      @credential = AgentForge::MaintainerBroker::Credential.new(
        secret: Phase7bControlsTest::TEST_SECRET,
        repository: request.repository,
        permissions: operation.provider_permissions,
        expires_at: @now + 300
      )
    end

    def revoke(_credential)
      @events << :revoke
      @revoke_result
    end

    def revoked_or_expired?(_credential, now:)
      @events << :verify_revocation
      @verification_result
    end
  end

  def setup
    @now = Time.utc(2026, 11, 23, 16, 0, 0)
    @primary = ChainedAuditSink.new(domain: "primary-service")
    @emergency = ChainedAuditSink.new(domain: "emergency-service")
    @audit = AuditPipeline.new(primary: @primary, emergency: @emergency)
    @registry = ActiveCredentialRegistry.new(clock: -> { @now })
    @state_store = StopStoreFake.new
    @stop = EmergencyStopController.new(
      state_store: @state_store,
      audit_pipeline: @audit,
      credential_registry: @registry,
      supervisor: StopSupervisorFake.new,
      clock: -> { @now }
    )
    @spec = OperationSpec.new(
      id: "test.noop",
      approval_count: 2,
      provider_permissions: ["test.permission"],
      api_actions: ["test.noop"]
    )
    @catalog = OperationCatalog.new([@spec])
    @policy = OperationPolicy.new(catalog: @catalog, enabled_operations: ["test.noop"])
    @issuer = IssuerFake.new(now: @now)
    @provider = ApprovalProviderFake.new
    @workflow = approval_workflow
    @broker = broker_for
  end

  def test_approval_challenge_displays_the_exact_action_and_ten_minute_deadline
    provider = ApprovalProviderFake.new
    claims = approval_claims
    workflow = approval_workflow(claims: claims, provider: provider)

    result = workflow.authorize!(request, @spec)

    assert_equal claims.fetch("request_id"), result.request_id
    assert_equal "test.noop", provider.challenge.fetch("operation")
    assert_equal "owner/repo", provider.challenge.fetch("repository")
    assert_equal "pr-42", provider.challenge.fetch("resource")
    assert_equal "headsha123", provider.challenge.fetch("expected_revision")
    assert_equal 2, provider.challenge.fetch("approvals_required")
    assert_equal (@now + 600).iso8601(6), provider.challenge.fetch("expires_at")
    assert provider.challenge.frozen?
  end

  def test_team_membership_adapter_uses_fixed_scope_and_immutable_user_ids
    client = MembershipClientFake.new
    adapter = GitHubTeamMembershipAdapter.new(
      organization_id: "101",
      team_id: "202",
      client: client,
      clock: -> { @now }
    )

    decision = adapter.check(github_user_id: "303")
    assert decision.eligible?
    assert_equal "303", decision.github_user_id
    assert_equal "101", decision.organization_id
    assert_equal "202", decision.team_id
    assert_equal @now, decision.checked_at
    assert decision.frozen?
    assert_equal [["101", "202", "303"]], client.calls
    assert_raises(ArgumentError) do
      adapter.eligible?(github_user_id: "303", organization_id: "999")
    end
    assert_raises(AuthorizationError) { adapter.eligible?(github_user_id: "maintainer-a") }
    assert_equal 1, client.calls.length
  end

  def test_team_membership_adapter_denies_inactive_or_unconfigured_membership
    inactive = GitHubTeamMembershipAdapter.new(
      organization_id: "101",
      team_id: "202",
      client: MembershipClientFake.new(result: :inactive)
    )
    unconfigured = GitHubTeamMembershipAdapter.new(
      organization_id: "101",
      team_id: "202"
    )

    refute inactive.eligible?(github_user_id: "303")
    error = assert_raises(AuthorizationError) do
      unconfigured.eligible?(github_user_id: "303")
    end

    assert_equal "team_membership_unconfigured", error.code
  end

  def test_approval_evidence_verifier_checks_issuer_audience_signature_and_claims
    response = {
      "issuer" => "https://approvals.example.invalid",
      "audience" => "agentforge-maintainer-broker",
      "signature_valid" => true,
      "claims" => approval_claims
    }
    verifier = ApprovalEvidenceVerifier.new(
      issuer: "https://approvals.example.invalid",
      audience: "agentforge-maintainer-broker",
      client: EvidenceClientFake.new(response)
    )

    claims = ApprovalClaims.from_hash(verifier.verify("signed-evidence", now: @now))

    assert_equal "request-42", claims.request_id
    invalid_responses = [
      response.merge("issuer" => "https://untrusted.example.invalid"),
      response.merge("audience" => "other-service"),
      response.merge("signature_valid" => false),
      response.merge("claims" => approval_claims.merge("unexpected" => "value")),
      response.merge("claims" => approval_claims(expires_at: @now - 1))
    ]
    invalid_responses.each do |invalid_response|
      invalid_verifier = ApprovalEvidenceVerifier.new(
        issuer: "https://approvals.example.invalid",
        audience: "agentforge-maintainer-broker",
        client: EvidenceClientFake.new(invalid_response)
      )
      assert_raises(AuthorizationError) do
        invalid_verifier.verify("signed-evidence", now: @now)
      end
    end
  end

  def test_external_replay_store_prevents_reuse_across_workflows
    replay_store = ReplayStoreFake.new
    first = approval_workflow(replay_store: replay_store)
    second = approval_workflow(replay_store: replay_store)

    assert_equal "request-42", first.authorize!(request, @spec).request_id
    error = assert_raises(AuthorizationError) do
      second.authorize!(request, @spec)
    end

    assert_equal "approval_replayed", error.code
  end

  def test_unconfigured_replay_store_and_credential_providers_fail_closed
    replay_error = assert_raises(AuthorizationError) do
      ApprovalReplayStore.new.consume!(nonce: "0123456789abcdef", expires_at: @now + 60)
    end
    issuer_error = assert_raises(CredentialError) do
      CredentialIssuer.new.issue(request: request, operation: @spec)
    end
    revoker_error = assert_raises(CredentialError) do
      CredentialRevoker.new.revoke(nil)
    end

    assert_equal "approval_replay_store_unconfigured", replay_error.code
    assert_equal "credential_issuer_unconfigured", issuer_error.code
    assert_equal "credential_revoker_unconfigured", revoker_error.code
  end

  def test_expired_and_denied_approvals_do_not_issue_credentials
    expired = broker_for(claims: approval_claims(expires_at: @now - 1))
    denied_provider = ApprovalProviderFake.new(
      error: AuthorizationError.new(:human_approval_denied)
    )
    denied = broker_for(
      provider: denied_provider,
      claims: approval_claims
    )

    expired_result = expired.execute(envelope)
    denied_result = denied.execute(envelope)

    assert_equal "approval_expired", expired_result.fetch("code")
    assert_equal "human_approval_denied", denied_result.fetch("code")
    assert_empty @issuer.events
  end

  def test_approver_identity_and_requester_rules_are_enforced
    self_approval = broker_for(
      claims: approval_claims(approver_ids: %w[agent-1 maintainer-b])
    ).execute(envelope)
    requester_second = broker_for(
      claims: approval_claims(approver_ids: %w[maintainer-a requester-a])
    ).execute(envelope)

    assert_equal "agent_self_approval", self_approval.fetch("code")
    assert_equal "second_approver_is_requester", requester_second.fetch("code")
    assert_empty @issuer.events
  end

  def test_missing_identity_or_emergency_stop_providers_fail_closed
    unconfigured_workflow = ApprovalWorkflow.new(
      context_provider: ApprovalContextProvider.new,
      approval_provider: @provider,
      verifier: VerifierFake.new(approval_claims),
      clock: -> { @now }
    )
    identity_error = assert_raises(AuthorizationError) do
      unconfigured_workflow.authorize!(request, @spec)
    end
    unconfigured_stop = EmergencyStopController.new(
      state_store: EmergencyStopStateStore.new,
      audit_pipeline: @audit,
      credential_registry: @registry,
      clock: -> { @now }
    )
    broker = broker_for(stop: unconfigured_stop)
    stop_result = broker.execute(envelope)

    assert_equal "approval_identity_unconfigured", identity_error.code
    assert_equal "emergency_stop_unconfigured", stop_result.fetch("code")
    assert_empty @issuer.events
  end

  def test_audit_pipeline_rejects_shared_failure_domains
    first = ChainedAuditSink.new(domain: "same-service")
    second = ChainedAuditSink.new(domain: "same-service")

    error = assert_raises(ArgumentError) do
      AuditPipeline.new(primary: first, emergency: second)
    end

    assert_equal "audit sinks must declare independent failure domains", error.message
  end

  def test_audit_pipeline_rejects_failed_integrity_verification
    primary = ChainedAuditSink.new(domain: "primary-service", integrity_result: false)
    emergency = ChainedAuditSink.new(domain: "emergency-service", integrity_result: false)
    pipeline = AuditPipeline.new(primary: primary, emergency: emergency)

    error = assert_raises(AuditFailure) do
      pipeline.append(audit_record("request", "event-integrity-check"))
    end

    assert_equal "audit_unavailable", error.code
    assert_equal 1, primary.records.length
    assert_equal 1, emergency.records.length
  end

  def test_audit_pipeline_rejects_false_append_result
    primary = ChainedAuditSink.new(domain: "primary-service", append_result: false)
    emergency = ChainedAuditSink.new(domain: "emergency-service")
    pipeline = AuditPipeline.new(primary: primary, emergency: emergency)

    error = assert_raises(AuditFailure) do
      pipeline.append(audit_record("request", "event-false-append"))
    end

    assert_equal "audit_unavailable", error.code
    assert_equal 1, emergency.records.length
  end

  def test_emergency_stop_rejects_unconfirmed_state
    stop = EmergencyStopController.new(
      state_store: StopStoreFake.new(active_result: nil),
      audit_pipeline: @audit,
      credential_registry: @registry,
      supervisor: StopSupervisorFake.new,
      clock: -> { @now }
    )

    error = assert_raises(EmergencyStopError) { stop.assert_running! }

    assert_equal "invalid_emergency_stop_state", error.code
  end

  def test_emergency_stop_fails_closed_when_supervisor_is_unavailable
    stop = EmergencyStopController.new(
      state_store: StopStoreFake.new,
      audit_pipeline: @audit,
      credential_registry: @registry
    )

    error = assert_raises(EmergencyStopError) { stop.assert_running! }

    assert_equal "emergency_stop_supervisor_unconfigured", error.code
  end

  def test_emergency_stop_rejects_unconfirmed_persistence
    stop = EmergencyStopController.new(
      state_store: StopStoreFake.new(trip_result: false),
      audit_pipeline: @audit,
      credential_registry: @registry,
      supervisor: StopSupervisorFake.new,
      clock: -> { @now }
    )

    error = assert_raises(EmergencyStopError) do
      stop.trip!(request_id: "stop-1", actor_id: "operator-a", reason_code: "incident")
    end

    def test_emergency_stop_requires_supervisor_confirmation_and_still_revokes
      supervisor = StopSupervisorFake.new(termination_result: false)
      registry = ActiveCredentialRegistry.new(clock: -> { @now })
      issuer = IssuerFake.new(now: @now)
      credential = AgentForge::MaintainerBroker::Credential.new(
        secret: TEST_SECRET,
        repository: "owner/repo",
        permissions: ["test.permission"],
        expires_at: @now + 300
      )
      registry.register!(request_id: "active-1", revoker: issuer, credential: credential)
      stop = EmergencyStopController.new(
        state_store: StopStoreFake.new,
        audit_pipeline: @audit,
        credential_registry: registry,
        supervisor: supervisor,
        clock: -> { @now }
      )

      error = assert_raises(EmergencyStopError) do
        stop.trip!(request_id: "stop-3", actor_id: "operator-a", reason_code: "incident")
      end

      assert_equal "emergency_stop_incomplete", error.code
      assert_equal ["stop-3"], supervisor.terminated_requests
      assert_equal %i[revoke verify_revocation], issuer.events
      assert_equal 0, registry.active_count
      assert credential.destroyed?
    end

    assert_equal "emergency_stop_incomplete", error.code
    assert_equal 2, @primary.records.count { |record| record.fetch("event") == "emergency_stop" }
  end

  def test_audit_pipeline_writes_both_integrity_checked_sinks
    result = @broker.execute(envelope)

    assert_equal "allow", result.fetch("decision")
    assert_equal %w[intent completed], @primary.records.map { |record| record.fetch("event") }
    assert_equal @primary.records.map { |record| record.fetch("event_id") },
                 @emergency.records.map { |record| record.fetch("event_id") }
    assert_equal "maintainer-a,maintainer-b", @primary.records.last.fetch("approver_ids")
    assert_equal "requester-a", @primary.records.last.fetch("requester_id")
    assert_equal "none", @primary.records.last.fetch("actor_id")
    refute_includes JSON.generate(@primary.records), TEST_SECRET
    @primary.verify_integrity!
    @emergency.verify_integrity!
  end

  def test_audit_integrity_detects_alteration_deletion_and_duplicate_events
    record = audit_record("intent", "event-1")
    @audit.append(record)
    @primary.tamper!(0)
    assert_raises(AuditFailure) { @primary.verify_integrity! }

    @primary = ChainedAuditSink.new(domain: "primary-replacement")
    @emergency = ChainedAuditSink.new(domain: "emergency-replacement")
    @audit = AuditPipeline.new(primary: @primary, emergency: @emergency)
    @audit.append(record)
    @emergency.delete!(0)
    assert_raises(AuditFailure) { @emergency.verify_integrity! }
    assert_raises(AuditFailure) { @audit.append(record) }
  end

  def test_audit_sink_failure_before_issue_denies_and_uses_emergency_path
    failing_primary = ChainedAuditSink.new(
      domain: "failing-primary",
      failures: ["intent"]
    )
    emergency = ChainedAuditSink.new(domain: "separate-emergency")
    pipeline = AuditPipeline.new(primary: failing_primary, emergency: emergency)
    stop, store, registry = stop_controller(pipeline: pipeline)
    broker = broker_for(audit: pipeline, stop: stop, registry: registry)

    result = broker.execute(envelope)

    assert_equal "deny", result.fetch("decision")
    assert_equal "audit_unavailable", result.fetch("code")
    assert_empty @issuer.events
    assert store.tripped
    assert_includes emergency.records.map { |record| record.fetch("event") }, "intent"
    assert_includes emergency.records.map { |record| record.fetch("event") }, "emergency_stop"
  end

  def test_audit_failure_after_handler_denies_stops_and_revokes
    failing_primary = ChainedAuditSink.new(
      domain: "failing-primary",
      failures: ["completed"]
    )
    emergency = ChainedAuditSink.new(domain: "separate-emergency")
    pipeline = AuditPipeline.new(primary: failing_primary, emergency: emergency)
    stop, store, registry = stop_controller(pipeline: pipeline)
    handler_called = false
    broker = broker_for(
      audit: pipeline,
      stop: stop,
      registry: registry,
      handler: ->(_request, _credential) { handler_called = true }
    )

    result = broker.execute(envelope)

    assert handler_called
    assert_equal "deny", result.fetch("decision")
    assert_equal "audit_unavailable", result.fetch("code")
    assert_equal %i[issue revoke verify_revocation], @issuer.events
    assert store.tripped
    assert_equal 0, registry.active_count
  end

  def test_idle_emergency_stop_blocks_requests_and_cannot_be_reset
    assert @stop.trip!(request_id: "stop-1", actor_id: "operator-1", reason_code: "manual_stop")

    result = @broker.execute(envelope)

    assert_equal "emergency_stop_active", result.fetch("code")
    assert_empty @issuer.events
    assert @state_store.tripped
    assert_raises(EmergencyStopError) { @stop.assert_running! }
  end

  def test_in_flight_emergency_stop_revokes_and_denies
    handler = lambda do |_request, _credential|
      @stop.trip!(request_id: "request-42", actor_id: "operator-1", reason_code: "manual_stop")
    end
    broker = broker_for(handler: handler)

    result = broker.execute(envelope)

    assert_equal "deny", result.fetch("decision")
    assert_equal "emergency_stop_active", result.fetch("code")
    assert_equal %i[issue revoke verify_revocation], @issuer.events
    assert_equal 0, @registry.active_count
    assert @state_store.tripped
  end

  def test_failed_revocation_keeps_the_stop_latched_and_fails_closed
    failed_issuer = IssuerFake.new(
      now: @now,
      revoke_result: false,
      verification_result: false
    )
    broker = broker_for(issuer: failed_issuer, handler: ->(*) { true })

    result = broker.execute(envelope)

    assert_equal "deny", result.fetch("decision")
    assert_equal "emergency_stop_incomplete", result.fetch("code")
    assert @state_store.tripped
    assert_equal 1, @registry.active_count
    refute failed_issuer.credential.destroyed?
    assert_operator failed_issuer.events.count(:revoke), :>=, 2
  end

  def test_emergency_stop_attempts_revocation_even_when_emergency_audit_fails
    primary = ChainedAuditSink.new(domain: "stop-failing-primary", failures: ["emergency_stop"])
    emergency = ChainedAuditSink.new(domain: "stop-failing-emergency", failures: ["emergency_stop"])
    pipeline = AuditPipeline.new(primary: primary, emergency: emergency)
    registry = ActiveCredentialRegistry.new(clock: -> { @now })
    issuer = IssuerFake.new(now: @now)
    credential = AgentForge::MaintainerBroker::Credential.new(
      secret: TEST_SECRET,
      repository: "owner/repo",
      permissions: ["test.permission"],
      expires_at: @now + 300
    )
    registry.register!(request_id: "active-1", revoker: issuer, credential: credential)
    stop, store, = stop_controller(pipeline: pipeline, registry: registry)

    error = assert_raises(EmergencyStopError) do
      stop.trip!(request_id: "stop-2", actor_id: "operator-1", reason_code: "manual_stop")
    end

    assert_equal "emergency_stop_incomplete", error.code
    assert store.tripped
    assert_equal %i[revoke verify_revocation], issuer.events
    assert_equal 0, registry.active_count
    assert credential.destroyed?
  end

  private

  def approval_workflow(claims: approval_claims, provider: ApprovalProviderFake.new,
                        replay_store: ReplayStoreFake.new)
    ApprovalWorkflow.new(
      context_provider: ContextProvider.new,
      approval_provider: provider,
      verifier: VerifierFake.new(claims),
      replay_store: replay_store,
      clock: -> { @now }
    )
  end

  def broker_for(claims: approval_claims, provider: @provider, issuer: @issuer,
                 audit: @audit, stop: @stop, registry: @registry,
                 handler: ->(_request, _credential) { true })
    Broker.new(
      catalog: @catalog,
      policy: @policy,
      approval_workflow: approval_workflow(claims: claims, provider: provider),
      credential_issuer: issuer,
      credential_revoker: issuer,
      audit_sink: audit,
      emergency_stop: stop,
      credential_registry: registry,
      handlers: { "test.noop" => handler },
      clock: -> { @now }
    )
  end

  def stop_controller(pipeline: @audit, registry: @registry)
    store = StopStoreFake.new
    supervisor = StopSupervisorFake.new
    controller = EmergencyStopController.new(
      state_store: store,
      audit_pipeline: pipeline,
      credential_registry: registry,
      supervisor: supervisor,
      clock: -> { @now }
    )
    [controller, store, registry, supervisor]
  end

  def request
    Request.from_hash(
      {
        "operation" => "test.noop",
        "repository" => "owner/repo",
        "resource" => "pr-42",
        "expected_revision" => "headsha123",
        "request_id" => "request-42",
        "policy_version" => POLICY_VERSION
      }
    )
  end

  def envelope
    {
      "request" => {
        "operation" => "test.noop",
        "repository" => "owner/repo",
        "resource" => "pr-42",
        "expected_revision" => "headsha123",
        "request_id" => "request-42",
        "policy_version" => POLICY_VERSION
      }
    }
  end

  def approval_claims(approver_ids: %w[maintainer-a maintainer-b],
                      expires_at: @now + 300)
    {
      "operation" => "test.noop",
      "repository" => "owner/repo",
      "resource" => "pr-42",
      "expected_revision" => "headsha123",
      "request_id" => "request-42",
      "policy_version" => POLICY_VERSION,
      "approver_ids" => approver_ids,
      "requester_id" => "requester-a",
      "agent_identity" => "agent-1",
      "issued_at" => @now.iso8601,
      "expires_at" => expires_at.iso8601,
      "nonce" => "0123456789abcdef"
    }
  end

  def audit_record(event, event_id)
    {
      "timestamp" => @now.iso8601(6),
      "event" => event,
      "event_id" => event_id,
      "request_id" => "request-42",
      "operation" => "test.noop",
      "repository" => "owner/repo",
      "resource" => "pr-42",
      "expected_revision" => "headsha123",
      "policy_version" => POLICY_VERSION,
      "code" => "test",
      "approver_ids" => "maintainer-a,maintainer-b",
      "requester_id" => "requester-a",
      "agent_identity" => "agent-1",
      "actor_id" => "none",
      "approval_expires_at" => (@now + 300).iso8601(6),
      "credential_permissions" => "none",
      "credential_expires_at" => "none",
      "credential_revocation" => "not_issued"
    }
  end
end
