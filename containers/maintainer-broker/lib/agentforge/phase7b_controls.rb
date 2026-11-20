# frozen_string_literal: true

module AgentForge
  module MaintainerBroker
    class GitHubTeamMembershipClient
      def membership_state(organization_id:, team_id:, user_id:)
        raise AuthorizationError, :team_membership_unconfigured
      end
    end

    class MembershipDecision
      attr_reader :github_user_id, :organization_id, :team_id, :checked_at

      def initialize(github_user_id:, organization_id:, team_id:, eligible:, checked_at:)
        unless eligible == true || eligible == false
          raise AuthorizationError, :team_membership_indeterminate
        end
        raise AuthorizationError, :team_membership_indeterminate unless checked_at.is_a?(Time)

        @github_user_id = github_user_id.dup.freeze
        @organization_id = organization_id.dup.freeze
        @team_id = team_id.dup.freeze
        @eligible = eligible
        @checked_at = checked_at.getutc.freeze
        freeze
      end

      def eligible?
        @eligible
      end
    end

    class GitHubTeamMembershipAdapter
      def initialize(organization_id:, team_id:, client: GitHubTeamMembershipClient.new,
                     clock: -> { Time.now.utc })
        @organization_id = validate_id(organization_id)
        @team_id = validate_id(team_id)
        @client = client
        @clock = clock
      end

      def check(github_user_id:)
        user_id = validate_id(github_user_id)
        eligible = case @client.membership_state(
          organization_id: @organization_id,
          team_id: @team_id,
          user_id: user_id
        )
        when :active then true
        when :inactive then false
        else
          raise AuthorizationError, :team_membership_indeterminate
        end
        MembershipDecision.new(
          github_user_id: user_id,
          organization_id: @organization_id,
          team_id: @team_id,
          eligible: eligible,
          checked_at: @clock.call
        )
      end

      def eligible?(github_user_id:)
        check(github_user_id: github_user_id).eligible?
      end

      private

      def validate_id(value)
        unless value.is_a?(String) && value.match?(/\A[1-9][0-9]{0,19}\z/)
          raise AuthorizationError, :invalid_github_identity
        end

        value.dup.freeze
      end
    end

    class ApprovalEvidenceVerificationClient
      def verify(_evidence)
        raise AuthorizationError, :approval_verifier_unconfigured
      end
    end

    class ApprovalEvidenceVerifier < ApprovalVerifier
      RESPONSE_FIELDS = %w[audience claims issuer signature_valid].freeze

      def initialize(issuer:, audience:, client: ApprovalEvidenceVerificationClient.new)
        unless issuer.is_a?(String) && !issuer.empty? && audience.is_a?(String) && !audience.empty?
          raise ArgumentError, "approval issuer and audience must be configured"
        end

        @issuer = issuer.dup.freeze
        @audience = audience.dup.freeze
        @client = client
      end

      def verify(evidence, now:)
        unless evidence.is_a?(String) && evidence.bytesize.between?(1, 16_384)
          raise AuthorizationError, :invalid_approval_evidence
        end

        response = @client.verify(evidence)
        unless response.is_a?(Hash) && response.keys.all?(String) &&
               response.keys.sort == RESPONSE_FIELDS &&
               response["signature_valid"] == true &&
               response["issuer"] == @issuer &&
               response["audience"] == @audience
          raise AuthorizationError, :approval_signature_invalid
        end

        claims = ApprovalClaims.from_hash(response["claims"])
        raise AuthorizationError, :approval_expired unless claims.expires_at > now
        raise AuthorizationError, :approval_not_yet_valid if claims.issued_at > now

        response.fetch("claims")
      end
    end

    class ApprovalContextProvider
      def identities_for(_request)
        raise AuthorizationError, :approval_identity_unconfigured
      end
    end

    class ApprovalProvider
      def collect(_challenge)
        raise AuthorizationError, :approval_provider_unconfigured
      end
    end

    class ApprovalWorkflow
      def initialize(context_provider:, approval_provider:, verifier:,
                     replay_store: ApprovalReplayStore.new, replay_guard: nil,
                     clock: -> { Time.now.utc })
        @context_provider = context_provider
        @approval_provider = approval_provider
        @verifier = verifier
        @replay_store = replay_store
        @replay_guard = replay_guard
        @clock = clock
      end

      def authorize!(request, spec)
        identities = validated_identities(@context_provider.identities_for(request))
        created_at = @clock.call.utc
        challenge = {
          "operation" => request.operation,
          "repository" => request.repository,
          "resource" => request.resource,
          "expected_revision" => request.expected_revision,
          "request_id" => request.request_id,
          "policy_version" => request.policy_version,
          "requester_id" => identities.fetch("requester_id"),
          "approvals_required" => spec.approval_count,
          "created_at" => created_at.iso8601(6),
          "expires_at" => (created_at + MAX_APPROVAL_LIFETIME).iso8601(6)
        }.transform_values { |value| value.is_a?(String) ? value.dup.freeze : value }.freeze
        evidence = @approval_provider.collect(challenge)
        unless evidence.is_a?(String) && evidence.bytesize.between?(1, 16_384)
          raise AuthorizationError, :invalid_approval_evidence
        end

        claims = ApprovalClaims.from_hash(@verifier.verify(evidence, now: created_at))
        claims.validate!(request, spec, identities: identities, now: @clock.call.utc)
        unless @replay_store.consume!(nonce: claims.nonce, expires_at: claims.expires_at) == true
          raise AuthorizationError, :approval_replayed
        end
        @replay_guard&.consume!(claims.nonce)
        claims
      end

      private

      def validated_identities(value)
        expected_fields = %w[agent_identity requester_id]
        unless value.is_a?(Hash) && value.keys.sort == expected_fields.sort &&
               expected_fields.all? do |field|
                 value[field].is_a?(String) &&
                   value[field].match?(/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,126}\z/)
               end
          raise AuthorizationError, :approval_identity_unverified
        end

        expected_fields.to_h { |field| [field, value.fetch(field).dup.freeze] }.freeze
      end
    end

    class DurableAuditSink
      def failure_domain_id
        raise AuditFailure, :audit_sink_unconfigured
      end

      def append(_record)
        raise AuditFailure, :audit_sink_unconfigured
      end

      def verify_integrity!
        raise AuditFailure, :audit_sink_unconfigured
      end
    end

    class AuditPipeline
      def initialize(primary:, emergency:)
        raise ArgumentError, "audit sinks must be separate adapters" if primary.equal?(emergency)

        domains = [primary.failure_domain_id, emergency.failure_domain_id]
        unless domains.all? { |domain| domain.is_a?(String) && !domain.empty? } && domains.uniq.length == 2
          raise ArgumentError, "audit sinks must declare independent failure domains"
        end

        @sinks = [primary, emergency].freeze
      end

      def append(record)
        unless record.is_a?(Hash) &&
               record.all? do |key, value|
                 key.is_a?(String) && key.bytesize <= 128 &&
                   value.is_a?(String) && value.bytesize <= 256
               end
          raise AuditFailure, :invalid_audit_record
        end

        immutable_record = record.to_h do |key, value|
          [key.dup.freeze, value.dup.freeze]
        end.freeze
        failures = @sinks.map do |sink|
          begin
            raise AuditFailure, :audit_append_failed unless sink.append(immutable_record) == true

            raise AuditFailure, :audit_integrity_failure unless sink.verify_integrity! == true

            true
          rescue AuditFailure
            false
          end
        end
        raise AuditFailure, :audit_unavailable unless failures.all?

        true
      end
    end

    class EmergencyStopStateStore
      def active?
        raise EmergencyStopError, :emergency_stop_unconfigured
      end

      def trip!
        raise EmergencyStopError, :emergency_stop_unconfigured
      end
    end

    class EmergencyStopSupervisor
      def admission_allowed?
        raise EmergencyStopError, :emergency_stop_supervisor_unconfigured
      end

      def terminate_active!(request_id:)
        raise EmergencyStopError, :emergency_stop_supervisor_unconfigured
      end
    end

    class ActiveCredentialRegistry
      Entry = Struct.new(:request_id, :revoker, :credential, :mutex, :revoked, keyword_init: true)

      def initialize(clock: -> { Time.now.utc })
        @clock = clock
        @entries = {}
        @mutex = Mutex.new
        @stopped = false
      end

      def register!(request_id:, revoker:, credential:)
        raise CredentialError, :invalid_credential unless credential.is_a?(Credential)
        unless revoker.respond_to?(:revoke) && revoker.respond_to?(:revoked_or_expired?)
          raise CredentialError, :invalid_credential_revoker
        end

        @mutex.synchronize do
          raise CredentialError, :credential_already_registered if @entries.key?(request_id)

          @entries[request_id] = Entry.new(
            request_id: request_id,
            revoker: revoker,
            credential: credential,
            mutex: Mutex.new,
            revoked: false
          )
          !@stopped
        end
      end

      def revoke!(request_id)
        entry = @mutex.synchronize { @entries[request_id] }
        return true unless entry

        success = revoke_entry(entry)
        @mutex.synchronize { @entries.delete(request_id) if success }
        success
      end

      def revoke_all
        entries = @mutex.synchronize do
          @stopped = true
          @entries.values.dup
        end
        results = entries.map do |entry|
          success = revoke_entry(entry)
          @mutex.synchronize { @entries.delete(entry.request_id) if success }
          success
        end
        results.all?
      end

      def active_count
        @mutex.synchronize { @entries.length }
      end

      private

      def revoke_entry(entry)
        entry.mutex.synchronize do
          return true if entry.revoked

          revoked = entry.revoker.revoke(entry.credential)
          verified = entry.revoker.revoked_or_expired?(entry.credential, now: @clock.call)
          success = revoked == true && verified == true
          if success
            entry.credential.destroy!
            entry.revoked = true
          end
          success
        rescue CredentialError
          false
        end
      end
    end

    class EmergencyStopError < AuthorizationError; end

    class EmergencyStopController
      def initialize(state_store:, audit_pipeline:, credential_registry:,
                     supervisor: EmergencyStopSupervisor.new,
                     clock: -> { Time.now.utc })
        @state_store = state_store
        @audit_pipeline = audit_pipeline
        @credential_registry = credential_registry
        @supervisor = supervisor
        @clock = clock
        @mutex = Mutex.new
        @tripped = false
      end

      def assert_running!
        raise EmergencyStopError, :emergency_stop_active if @mutex.synchronize { @tripped }
        active = @state_store.active?
        unless active == true || active == false
          raise EmergencyStopError, :invalid_emergency_stop_state
        end
        raise EmergencyStopError, :emergency_stop_active if active
        admission_allowed = @supervisor.admission_allowed?
        unless admission_allowed == true || admission_allowed == false
          raise EmergencyStopError, :invalid_emergency_stop_state
        end
        raise EmergencyStopError, :emergency_stop_active unless admission_allowed

        true
      end

      def trip!(request_id:, actor_id:, reason_code:)
        unless request_id.is_a?(String) && request_id.match?(/\A[a-zA-Z0-9][a-zA-Z0-9._:-]{0,127}\z/) &&
               actor_id.is_a?(String) && actor_id.match?(/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,126}\z/) &&
               reason_code.to_s.match?(/\A[a-z0-9_]{1,64}\z/)
          raise EmergencyStopError, :invalid_emergency_stop_request
        end

        @mutex.synchronize { @tripped = true }
        state_ok = begin
          raise EmergencyStopError, :emergency_stop_persistence_failed unless @state_store.trip! == true

          true
        rescue EmergencyStopError
          false
        end
        supervisor_ok = begin
          raise EmergencyStopError, :emergency_stop_supervisor_failed unless
            @supervisor.terminate_active!(request_id: request_id) == true

          true
        rescue EmergencyStopError
          false
        end

        audit_ok = append_stop_record(request_id, actor_id, reason_code.to_s, "pending")
        revoked = @credential_registry.revoke_all
        completion_audit_ok = append_stop_record(
          request_id,
          actor_id,
          revoked ? "revocation_verified" : "revocation_failed",
          revoked ? "verified" : "failed"
        )
        audit_ok = audit_ok && completion_audit_ok

        unless state_ok && supervisor_ok && audit_ok && revoked
          raise EmergencyStopError, :emergency_stop_incomplete
        end

        true
      end

      private

      def append_stop_record(request_id, actor_id, code, revocation_status)
        unless @audit_pipeline.append(
          {
            "timestamp" => @clock.call.utc.iso8601(6),
            "event" => "emergency_stop",
            "event_id" => SecureRandom.uuid,
            "request_id" => request_id,
            "operation" => "system.emergency_stop",
            "repository" => "none",
            "resource" => "maintainer-broker",
            "expected_revision" => "none",
            "policy_version" => POLICY_VERSION,
            "code" => code,
            "approver_ids" => "none",
            "requester_id" => "none",
            "agent_identity" => "none",
            "actor_id" => actor_id,
            "approval_expires_at" => "none",
            "credential_permissions" => "none",
            "credential_expires_at" => "none",
            "credential_revocation" => revocation_status
          }
        ) == true
          raise AuditFailure, :audit_unavailable
        end
        true
      rescue AuditFailure
        false
      end
    end
  end
end
