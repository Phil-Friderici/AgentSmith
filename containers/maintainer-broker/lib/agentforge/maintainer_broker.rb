# frozen_string_literal: true

require "json"
require "securerandom"
require "thread"
require "time"

module AgentForge
  module MaintainerBroker
    POLICY_VERSION = "phase7b-v1"
    MAX_APPROVAL_LIFETIME = 600
    MAX_CREDENTIAL_LIFETIME = 3600
    MAX_ENVELOPE_BYTES = 65_536

    class BrokerError < StandardError
      attr_reader :code

      def initialize(code)
        candidate = code.to_s
        @code = candidate.match?(/\A[a-z0-9_]{1,64}\z/) ? candidate : "internal_error"
        super(@code)
      end
    end

    class AuthorizationError < BrokerError; end
    class CredentialError < BrokerError; end
    class OperationFailure < BrokerError; end
    class AuditFailure < BrokerError; end

    class OperationSpec
      attr_reader :id, :approval_count, :provider_permissions, :api_actions

      def initialize(id:, approval_count:, provider_permissions: [], api_actions: [])
        raise ArgumentError, "invalid operation id" unless id.match?(/\A[a-z][a-z0-9_.]{1,63}\z/)
        raise ArgumentError, "invalid approval count" unless (1..2).cover?(approval_count)
        raise ArgumentError, "invalid provider permissions" unless string_list?(provider_permissions)
        raise ArgumentError, "invalid API actions" unless string_list?(api_actions)

        @id = id.dup.freeze
        @approval_count = approval_count
        @provider_permissions = provider_permissions.map { |value| value.dup.freeze }.freeze
        @api_actions = api_actions.map { |value| value.dup.freeze }.freeze
        freeze
      end

      def mapped?
        !provider_permissions.empty? && !api_actions.empty?
      end

      private

      def string_list?(values)
        values.is_a?(Array) && values.all? { |value| value.is_a?(String) && value.match?(/\A[a-zA-Z0-9_.:-]{1,128}\z/) }
      end
    end

    class OperationCatalog
      def initialize(specs)
        raise ArgumentError, "operation catalog must be an array" unless specs.is_a?(Array)
        raise ArgumentError, "duplicate operation id" unless specs.map(&:id).uniq.length == specs.length

        @specs = specs.to_h { |spec| [spec.id, spec] }.freeze
        freeze
      end

      def [](operation_id)
        @specs[operation_id]
      end

      def operation_ids
        @specs.keys.freeze
      end

      def self.phase7a
        new(
          [
            OperationSpec.new(id: "pull_request.approve", approval_count: 1),
            OperationSpec.new(id: "pull_request.merge", approval_count: 2),
            OperationSpec.new(id: "release.draft_create", approval_count: 2),
            OperationSpec.new(id: "branch.create", approval_count: 1),
            OperationSpec.new(id: "branch.delete", approval_count: 2),
            OperationSpec.new(id: "issue.moderate", approval_count: 1)
          ]
        )
      end
    end

    class Request
      FIELDS = %w[
        operation repository resource expected_revision request_id policy_version
      ].freeze

      attr_reader(*FIELDS.map(&:to_sym))

      def initialize(values)
        FIELDS.each { |field| instance_variable_set("@#{field}", values.fetch(field).dup.freeze) }
        freeze
      end

      def self.from_hash(value)
        unless value.is_a?(Hash) && value.keys.all?(String) && value.keys.sort == FIELDS.sort
          raise AuthorizationError, :invalid_request
        end

        operation = bounded_string(value["operation"], /\A[a-z][a-z0-9_.]{1,63}\z/)
        repository = bounded_string(value["repository"], /\A[a-zA-Z0-9][a-zA-Z0-9-]{0,38}\/[a-zA-Z0-9_.-]{1,100}\z/)
        resource = bounded_string(value["resource"], /\A[a-zA-Z0-9][a-zA-Z0-9._:\/#-]{0,255}\z/)
        revision = bounded_string(value["expected_revision"], /\A[a-zA-Z0-9][a-zA-Z0-9._:+-]{0,127}\z/)
        request_id = bounded_string(value["request_id"], /\A[a-zA-Z0-9][a-zA-Z0-9._:-]{0,127}\z/)
        policy_version = bounded_string(value["policy_version"], /\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}\z/)

        new(
          "operation" => operation,
          "repository" => repository,
          "resource" => resource,
          "expected_revision" => revision,
          "request_id" => request_id,
          "policy_version" => policy_version
        )
      end

      def self.bounded_string(value, pattern)
        unless value.is_a?(String) && value.bytesize <= 256 && value.match?(pattern) && !value.include?("*")
          raise AuthorizationError, :invalid_request
        end

        value
      end
      private_class_method :bounded_string
    end

    class OperationPolicy
      attr_reader :version

      def initialize(catalog:, enabled_operations: [], version: POLICY_VERSION)
        unless enabled_operations.is_a?(Array) && enabled_operations.uniq == enabled_operations
          raise ArgumentError, "enabled operations must be a unique array"
        end
        raise ArgumentError, "invalid policy version" unless version.is_a?(String) && version.match?(/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}\z/)

        enabled_operations.each do |operation_id|
          spec = catalog[operation_id]
          raise ArgumentError, "unknown enabled operation" unless spec
          raise ArgumentError, "operation mapping is incomplete" unless spec.mapped?
        end

        @enabled_operations = enabled_operations.map { |operation_id| operation_id.dup.freeze }.freeze
        @version = version.dup.freeze
        freeze
      end

      def enabled_operations
        @enabled_operations
      end

      def authorize!(request, spec)
        raise AuthorizationError, :policy_version_mismatch unless request.policy_version == version
        raise AuthorizationError, :operation_not_enabled unless @enabled_operations.include?(spec.id)
        raise AuthorizationError, :operation_mapping_incomplete unless spec.mapped?
      end
    end

    class ApprovalVerifier
      def verify(_evidence, now:)
        raise AuthorizationError, :approval_verifier_unconfigured
      end
    end

    class ApprovalReplayStore
      def consume!(nonce:, expires_at:)
        raise AuthorizationError, :approval_replay_store_unconfigured
      end
    end

    class ApprovalClaims
      FIELDS = %w[
        operation repository resource expected_revision request_id policy_version
        approver_ids requester_id agent_identity issued_at expires_at nonce
      ].freeze

      attr_reader :operation, :repository, :resource, :expected_revision,
                  :request_id, :policy_version, :approver_ids, :requester_id,
                  :agent_identity, :issued_at, :expires_at, :nonce

      def self.from_hash(value)
        unless value.is_a?(Hash) && value.keys.all?(String) && value.keys.sort == FIELDS.sort
          raise AuthorizationError, :invalid_approval_evidence
        end

        string_fields = FIELDS - %w[approver_ids issued_at expires_at]
        strings = string_fields.to_h do |field|
          item = value[field]
          unless item.is_a?(String) && item.bytesize <= 256 && item.match?(/\A[a-zA-Z0-9][a-zA-Z0-9._:\/#-]{0,255}\z/)
            raise AuthorizationError, :invalid_approval_evidence
          end
          [field, item]
        end

        approvers = value["approver_ids"]
        unless approvers.is_a?(Array) && approvers.length <= 2 &&
               approvers.all? { |item| item.is_a?(String) && item.match?(/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,126}\z/) }
          raise AuthorizationError, :invalid_approval_evidence
        end

        issued_at = parse_time(value["issued_at"])
        expires_at = parse_time(value["expires_at"])
        new(**strings.transform_keys(&:to_sym), approver_ids: approvers, issued_at: issued_at, expires_at: expires_at)
      end

      def self.parse_time(value)
        raise AuthorizationError, :invalid_approval_evidence unless value.is_a?(String) && value.bytesize <= 64

        Time.iso8601(value)
      rescue ArgumentError
        raise AuthorizationError, :invalid_approval_evidence
      end
      private_class_method :parse_time

      def initialize(operation:, repository:, resource:, expected_revision:, request_id:,
                     policy_version:, nonce:, approver_ids:, requester_id:,
                     agent_identity:, issued_at:, expires_at:)
        @operation = operation.dup.freeze
        @repository = repository.dup.freeze
        @resource = resource.dup.freeze
        @expected_revision = expected_revision.dup.freeze
        @request_id = request_id.dup.freeze
        @policy_version = policy_version.dup.freeze
        @nonce = nonce.dup.freeze
        @approver_ids = approver_ids.map { |approver_id| approver_id.dup.freeze }.freeze
        @requester_id = requester_id.dup.freeze
        @agent_identity = agent_identity.dup.freeze
        @issued_at = issued_at
        @expires_at = expires_at
        freeze
      end

      def validate!(request, spec, identities:, now:)
        bindings = [
          operation == request.operation,
          repository == request.repository,
          resource == request.resource,
          expected_revision == request.expected_revision,
          request_id == request.request_id,
          policy_version == request.policy_version,
          requester_id == identities.fetch("requester_id"),
          agent_identity == identities.fetch("agent_identity")
        ]
        raise AuthorizationError, :approval_binding_mismatch unless bindings.all?
        raise AuthorizationError, :invalid_approval_evidence unless approver_ids.length == spec.approval_count
        raise AuthorizationError, :invalid_approval_evidence unless approver_ids.uniq.length == approver_ids.length
        raise AuthorizationError, :agent_self_approval if approver_ids.include?(agent_identity)
        if spec.approval_count == 2 && approver_ids.last == requester_id
          raise AuthorizationError, :second_approver_is_requester
        end
        raise AuthorizationError, :approval_expired unless expires_at > now
        raise AuthorizationError, :approval_not_yet_valid if issued_at > now
        raise AuthorizationError, :invalid_approval_lifetime unless expires_at > issued_at && expires_at - issued_at <= MAX_APPROVAL_LIFETIME
        raise AuthorizationError, :invalid_approval_evidence unless nonce.match?(/\A[a-zA-Z0-9_-]{16,128}\z/)
      end
    end

    class Credential
      attr_reader :repository, :expires_at

      attr_reader :permissions

      def initialize(secret:, repository:, permissions:, expires_at:)
        raise CredentialError, :invalid_credential unless secret.is_a?(String) && !secret.empty?
        raise CredentialError, :invalid_credential unless repository.is_a?(String) && expires_at.is_a?(Time)
        unless permissions.is_a?(Array) && permissions.all? { |permission| permission.is_a?(String) && permission.match?(/\A[a-zA-Z0-9_.:-]{1,128}\z/) }
          raise CredentialError, :invalid_credential
        end

        @secret = secret.dup
        @repository = repository.dup.freeze
        @permissions = permissions.map { |permission| permission.dup.freeze }.freeze
        @expires_at = expires_at
        @destroyed = false
      end

      def validate_for!(request, operation:, now:)
        raise CredentialError, :credential_scope_mismatch unless repository == request.repository
        raise CredentialError, :credential_permission_mismatch unless permissions == operation.provider_permissions
        raise CredentialError, :credential_expired unless expires_at > now
        raise CredentialError, :credential_lifetime_exceeded if expires_at - now > MAX_CREDENTIAL_LIFETIME
      end

      def with_secret
        raise CredentialError, :credential_destroyed if @destroyed

        yield @secret
      end

      def destroy!
        @secret&.replace("\0" * @secret.bytesize)
        @secret = nil
        @destroyed = true
      end

      def destroyed?
        @destroyed
      end

      def inspect
        "#<#{self.class} [REDACTED]>"
      end

      def to_s
        "[REDACTED]"
      end
    end

    class CredentialIssuer
      def issue(request:, operation:)
        raise CredentialError, :credential_issuer_unconfigured
      end
    end

    class CredentialRevoker
      def revoke(_credential)
        raise CredentialError, :credential_revoker_unconfigured
      end

      def revoked_or_expired?(_credential, now:)
        raise CredentialError, :credential_revoker_unconfigured
      end
    end

    class FileAuditSink
      FIELDS = %w[
        timestamp event event_id request_id operation repository resource expected_revision
        policy_version code approver_ids requester_id agent_identity actor_id
        approval_expires_at credential_permissions credential_expires_at credential_revocation
      ].freeze
      EVENTS = %w[denied intent completed failed emergency_stop].freeze

      def initialize(path)
        @path = path
        @directory = File.dirname(path)
      end

      def append(record)
        unless record.is_a?(Hash) && record.keys.sort == FIELDS.sort &&
               EVENTS.include?(record["event"]) &&
               record.values.all? { |value| value.is_a?(String) && value.bytesize <= 256 }
          raise AuditFailure, :invalid_audit_record
        end

        directory_stat = File.lstat(@directory)
        unless directory_stat.directory? && !directory_stat.symlink? &&
               directory_stat.uid == Process.euid && (directory_stat.mode & 0o077).zero?
          raise AuditFailure, :audit_directory_unsafe
        end
        raise AuditFailure, :audit_nofollow_unavailable unless File.const_defined?(:NOFOLLOW)

        flags = File::WRONLY | File::CREAT | File::APPEND | File::NOFOLLOW
        File.open(@path, flags, 0o600) do |file|
          stat = file.stat
          unless stat.file? && stat.uid == Process.euid && (stat.mode & 0o077).zero?
            raise AuditFailure, :audit_file_unsafe
          end

          file.write(JSON.generate(record))
          file.write("\n")
          file.flush
          file.fsync
        end
        true
      rescue AuditFailure
        raise
      rescue SystemCallError, IOError
        raise AuditFailure, :audit_unavailable
      end
    end

    class Broker
      def initialize(catalog:, policy:, credential_issuer:,
                     credential_revoker:, audit_sink:, approval_workflow:, emergency_stop:,
                     credential_registry: ActiveCredentialRegistry.new,
                     handlers: {},
                     clock: -> { Time.now.utc })
        @catalog = catalog
        @policy = policy
        @approval_workflow = approval_workflow
        @credential_issuer = credential_issuer
        @credential_revoker = credential_revoker
        @audit_sink = audit_sink
        @emergency_stop = emergency_stop
        @credential_registry = credential_registry
        @handlers = handlers.dup.freeze
        @clock = clock
      end

      def execute(envelope)
        request = nil
        begin
          unless envelope.is_a?(Hash) && envelope.keys.sort == ["request"]
            raise AuthorizationError, :invalid_envelope
          end

          request = Request.from_hash(envelope["request"])
          spec = @catalog[request.operation]
          raise AuthorizationError, :unknown_operation unless spec
          @policy.authorize!(request, spec)
          @emergency_stop.assert_running!
          claims = @approval_workflow.authorize!(request, spec)
        rescue AuthorizationError => error
          return deny(request, error.code)
        end

        handler = @handlers[spec.id]
        return deny(request, :handler_not_configured) unless handler

        begin
          append_audit!(audit_record("intent", request, "credential_issue_pending", claims: claims))
        rescue AuditFailure
          return response("deny", trip_emergency_stop(request, "audit_unavailable"), request)
        end

        execute_authorized(request, spec, handler, claims)
      end

      private

      def execute_authorized(request, spec, handler, claims)
        credential = nil
        registered = false
        result_code = "completed"
        revocation_status = "not_issued"

        begin
          @emergency_stop.assert_running!
          issued_credential = @credential_issuer.issue(request: request, operation: spec)
          unless issued_credential.is_a?(Credential)
            raise CredentialError, :invalid_credential
          end
          credential = issued_credential
          revocation_status = "pending"
          accepted = @credential_registry.register!(
            request_id: request.request_id,
            revoker: @credential_revoker,
            credential: credential
          )
          registered = true
          raise EmergencyStopError, :emergency_stop_active unless accepted
          credential.validate_for!(request, operation: spec, now: @clock.call)
          @emergency_stop.assert_running!
          handler.call(request, credential)
          @emergency_stop.assert_running!
        rescue AuthorizationError => error
          result_code = error.code
        rescue CredentialError => error
          result_code = error.code
        rescue OperationFailure => error
          result_code = error.code
        ensure
          if credential
            begin
              revoked = if registered
                          @credential_registry.revoke!(request.request_id)
                        else
                          revoke_unregistered(credential)
                        end
              revocation_status = revoked ? "verified" : "failed"
              result_code = "credential_lifecycle_failed" unless revocation_status == "verified"
            rescue CredentialError, EmergencyStopError
              revocation_status = "failed"
              result_code = "credential_lifecycle_failed"
            end
          end
        end

        if revocation_status == "failed"
          stop_result = trip_emergency_stop(request, "credential_lifecycle_failed")
          result_code = stop_result if stop_result == "emergency_stop_incomplete"
        end

        event = result_code == "completed" ? "completed" : "failed"
        begin
          append_audit!(
            audit_record(
              event,
              request,
              result_code,
              claims: claims,
              credential: credential,
              revocation_status: revocation_status
            )
          )
        rescue AuditFailure
          result_code = trip_emergency_stop(request, "audit_unavailable")
        end

        response(result_code == "completed" ? "allow" : "deny", result_code, request)
      end

      def deny(request, code)
        begin
          append_audit!(audit_record("denied", request, code))
        rescue AuditFailure
          return response("deny", trip_emergency_stop(request, "audit_unavailable"), request)
        end

        response("deny", code, request)
      end

      def append_audit!(record)
        raise AuditFailure, :audit_unavailable unless @audit_sink.append(record) == true
      end

      def audit_record(event, request, code, claims: nil, credential: nil, revocation_status: "not_issued")
        {
          "timestamp" => @clock.call.utc.iso8601(6),
          "event" => event,
          "event_id" => SecureRandom.uuid,
          "request_id" => request&.request_id || SecureRandom.uuid,
          "operation" => request&.operation || "invalid",
          "repository" => request&.repository || "unknown",
          "resource" => request&.resource || "unknown",
          "expected_revision" => request&.expected_revision || "unknown",
          "policy_version" => request&.policy_version || @policy.version,
          "code" => code.to_s,
          "approver_ids" => claims ? claims.approver_ids.join(",") : "none",
          "requester_id" => claims&.requester_id || "none",
          "agent_identity" => claims&.agent_identity || "none",
          "actor_id" => "none",
          "approval_expires_at" => claims ? claims.expires_at.utc.iso8601(6) : "none",
          "credential_permissions" => credential ? JSON.generate(credential.permissions) : "none",
          "credential_expires_at" => credential ? credential.expires_at.utc.iso8601(6) : "none",
          "credential_revocation" => revocation_status
        }
      end

      def revoke_unregistered(credential)
        revoked = @credential_revoker.revoke(credential)
        verified = @credential_revoker.revoked_or_expired?(credential, now: @clock.call)
        credential.destroy!
        revoked && verified
      ensure
        credential.destroy!
      end

      def trip_emergency_stop(request, reason_code)
        @emergency_stop.trip!(
          request_id: request&.request_id || SecureRandom.uuid,
          actor_id: "agentforge-broker",
          reason_code: reason_code
        )
        reason_code
      rescue EmergencyStopError
        "emergency_stop_incomplete"
      end

      def response(decision, code, request)
        {
          "decision" => decision,
          "code" => code.to_s,
          "request_id" => request&.request_id || "unavailable"
        }
      end
    end

    def self.disabled_broker(audit_sink:)
      catalog = OperationCatalog.phase7a
      registry = ActiveCredentialRegistry.new
      policy = OperationPolicy.new(catalog: catalog, enabled_operations: [])
      Broker.new(
        catalog: catalog,
        policy: policy,
        approval_workflow: ApprovalWorkflow.new(
          context_provider: ApprovalContextProvider.new,
          approval_provider: ApprovalProvider.new,
          verifier: ApprovalVerifier.new
        ),
        credential_issuer: CredentialIssuer.new,
        credential_revoker: CredentialRevoker.new,
        audit_sink: audit_sink,
        emergency_stop: EmergencyStopController.new(
          state_store: EmergencyStopStateStore.new,
          audit_pipeline: audit_sink,
          credential_registry: registry
        ),
        credential_registry: registry
      )
    end
  end
end

require_relative "phase7b_controls"
