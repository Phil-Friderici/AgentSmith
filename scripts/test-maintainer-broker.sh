#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
compose_file="$repo_root/compose/phase7a-broker.yaml"
test_file="$repo_root/containers/maintainer-broker/test/maintainer_broker_test.rb"

ruby3.2 "$test_file"
ruby3.2 "$repo_root/containers/maintainer-broker/test/phase7b_controls_test.rb"

compose_config="$(docker compose -f "$compose_file" --profile phase7a-broker config --format json)"
ruby3.2 -rjson -e '
  service = JSON.parse(STDIN.read).fetch("services").fetch("maintainer-broker")
  raise "broker network must be disabled" unless service.fetch("network_mode") == "none"
  raise "broker root filesystem must be read-only" unless service.fetch("read_only") == true
  raise "broker must use the dedicated non-root identity" unless service.fetch("user") == "65532:65532"
  raise "all Linux capabilities must be dropped" unless service.fetch("cap_drop").include?("ALL")
  raise "broker must not add Linux capabilities" unless service.fetch("cap_add", []).empty?
  raise "broker must use no-new-privileges" unless service.fetch("security_opt").include?("no-new-privileges:true")
  raise "no host volumes may be mounted" unless service.fetch("volumes", []).empty?
  raise "no Compose secrets may be mounted" unless service.fetch("secrets", []).empty?
  tmpfs = service.fetch("tmpfs")
  raise "audit must be the only writable mount" unless tmpfs.length == 1 && tmpfs.first.start_with?("/run/agentforge-broker-audit:")
  raise "broker must not publish ports or attach devices" unless service.fetch("ports", []).empty? && service.fetch("devices", []).empty?
  raise "broker must not use the host PID namespace" if service.key?("pid")
  raise "broker must not receive environment overrides" unless service.fetch("environment", {}).empty?
' <<< "$compose_config"

docker compose -f "$compose_file" --profile phase7a-broker build --quiet maintainer-broker
self_check="$(docker compose -f "$compose_file" --profile phase7a-broker run --rm --no-deps -T maintainer-broker --self-check)"
ruby3.2 -rjson -e '
  result = JSON.parse(STDIN.read)
  raise "Level 3 must remain disabled" unless result.fetch("level3_enabled") == false
  raise "runtime allowlist must remain empty" unless result.fetch("enabled_operations") == []
  raise "GitHub Team membership must remain unconfigured" unless result.fetch("team_membership_configured") == false
  raise "approval provider must remain unconfigured" unless result.fetch("approval_provider_configured") == false
  raise "approval evidence verifier must remain unconfigured" unless result.fetch("approval_evidence_verifier_configured") == false
  raise "credential issuer must remain unconfigured" unless result.fetch("credential_issuer_configured") == false
  raise "credential revoker must remain unconfigured" unless result.fetch("credential_revoker_configured") == false
  raise "durable audit must remain unconfigured" unless result.fetch("durable_audit_configured") == false
  raise "external emergency stop must remain unconfigured" unless result.fetch("external_emergency_stop_configured") == false
  raise "emergency-stop supervisor must remain unconfigured" unless result.fetch("emergency_stop_supervisor_configured") == false
  raise "broker must run as UID 65532" unless result.fetch("effective_uid") == 65532
  raise "container root filesystem must be read-only" unless result.fetch("root_writable") == false
  raise "Git must not be installed in the broker image" unless result.fetch("git_available") == false
  raise "GitHub CLI must not be installed in the broker image" unless result.fetch("github_cli_available") == false
  raise "curl must not be installed in the broker image" unless result.fetch("curl_available") == false
' <<< "$self_check"

request='{"request":{"operation":"pull_request.merge","repository":"owner/repo","resource":"pr-1","expected_revision":"abc123","request_id":"container-test","policy_version":"phase7b-v1"}}'
response="$(printf '%s\n' "$request" | docker compose -f "$compose_file" --profile phase7a-broker run --rm --no-deps -T maintainer-broker --request-stdin)"
ruby3.2 -rjson -e '
  result = JSON.parse(STDIN.read)
  raise "container must deny maintainer operations" unless result.fetch("decision") == "deny"
  raise "container must deny by empty policy" unless result.fetch("code") == "operation_not_enabled"
' <<< "$response"

printf '%s\n' "Maintainer broker Phase 7a/7b foundation checks passed."
