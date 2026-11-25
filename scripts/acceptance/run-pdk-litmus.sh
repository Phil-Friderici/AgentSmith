#!/usr/bin/env bash
set -Eeuo pipefail

readonly acceptance_user="agentforge-acceptance"
readonly acceptance_uid="999"
readonly acceptance_gid="987"
readonly acceptance_home="/var/lib/agentforge-acceptance"
readonly fixture_source="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../acceptance/fixture" && pwd -P)"
readonly staged_fixture="${acceptance_home}/phase5a-fixture"
readonly metadata_dir="${acceptance_home}/.agentforge-phase5a"
readonly source_hash_file="${metadata_dir}/fixture.sha256"
readonly lock_hash_file="${metadata_dir}/lockfiles.sha256"
readonly runtime_dir="/run/agentforge-acceptance/999/phase5a"
readonly socket_path="${runtime_dir}/podman.sock"
readonly service_unit="agentforge-acceptance-phase5a-podman.service"
readonly storage_root="${acceptance_home}/podman-storage-phase5a-reconcile"
readonly podman="/usr/bin/podman"
readonly podman_service_helper="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/podman-api-service.sh"

fail() {
    printf 'ERROR: %s\n' "$1" >&2
    exit 1
}

require_root() {
    (( EUID == 0 )) || fail "Run this wrapper with sudo."
}

verify_identity() {
    local uid gid groups path
    uid="$(id -u "$acceptance_user")"
    gid="$(id -g "$acceptance_user")"
    groups="$(id -Gn "$acceptance_user")"
    [[ "$uid" == "$acceptance_uid" ]] || fail "Unexpected acceptance UID: $uid."
    [[ "$gid" == "$acceptance_gid" ]] || fail "Unexpected acceptance GID: $gid."
    [[ "$groups" == "$acceptance_user" ]] || fail "The acceptance identity has supplementary groups."
    [[ -d "$acceptance_home" && ! -L "$acceptance_home" ]] || fail "The acceptance home is not a real directory."
    [[ "$(stat -c '%u:%g:%a' "$acceptance_home")" == "${acceptance_uid}:${acceptance_gid}:700" ]] \
        || fail "The acceptance home has unexpected ownership or mode."
    for path in "${acceptance_home}/.gem/credentials" "${acceptance_home}/.bundle/config"; do
        [[ ! -e "$path" && ! -L "$path" ]] || fail "Remove persistent Bundler credentials/configuration from the acceptance home: $path."
    done
}

fixture_fingerprint() {
    local directory="$1"
    (
        cd -- "$directory"
        find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1
    )
}

lockfile_fingerprint() {
    local directory="$1"
    (
        cd -- "$directory"
        find . -type f -name Gemfile.lock -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1
    )
}

verify_source_fixture() {
    local entry invalid

    [[ -d "$fixture_source" && ! -L "$fixture_source" ]] || fail "The Phase 5a fixture directory is missing or unsafe."
    for entry in .fixtures.yml Gemfile Gemfile.lock Rakefile metadata.json provision.yaml; do
        [[ -f "${fixture_source}/${entry}" ]] || fail "Required fixture file is missing: ${entry}."
    done
    for entry in spec target; do
        [[ -d "${fixture_source}/${entry}" ]] || fail "Required fixture directory is missing: ${entry}."
    done
    while IFS= read -r -d '' entry; do
        case "${entry##*/}" in
            .fixtures.yml|Gemfile|Gemfile.lock|Rakefile|metadata.json|provision.yaml|spec|target) ;;
            *) fail "Unexpected top-level fixture path: ${entry##*/}." ;;
        esac
    done < <(find "$fixture_source" -mindepth 1 -maxdepth 1 -print0)

    invalid="$(find "$fixture_source" \( -type l -o \( ! -type d -a ! -type f \) \) -print -quit)"
    [[ -z "$invalid" ]] || fail "Fixture contains a symlink or special file: $invalid."
}

verify_stage() {
    local source_hash expected_lock

    [[ -d "$staged_fixture" && ! -L "$staged_fixture" ]] || fail "Fixture is not staged; run the stage action first."
    [[ "$(stat -c '%u:%g:%a' "$staged_fixture")" == "${acceptance_uid}:${acceptance_gid}:700" ]] \
        || fail "Staged fixture has unexpected ownership or mode."
    [[ -f "$source_hash_file" && -f "$lock_hash_file" ]] || fail "Staging metadata is incomplete; inspect the acceptance home."

    verify_source_fixture
    source_hash="$(fixture_fingerprint "$fixture_source")"
    [[ "$source_hash" == "$(cat "$source_hash_file")" ]] \
        || fail "Source fixture changed after staging; teardown, clean the staged copy, and stage again."
    expected_lock="$(cat "$lock_hash_file")"
    [[ "$(lockfile_fingerprint "$staged_fixture")" == "$expected_lock" ]] \
        || fail "A staged Gemfile.lock changed; do not continue with this bundle."
}

verify_pdk() {
    local pdk_version
    pdk_version="$(run_pdk --version)"
    [[ "$pdk_version" == "4.0.1" ]] || fail "Expected PDK 4.0.1, got: $pdk_version."
}

run_pdk() {
    local pdk_bin

    pdk_bin="$(command -v pdk || true)"
    [[ -n "$pdk_bin" && -x "$pdk_bin" ]] || fail "PDK is not installed in this acceptance environment."
    runuser --user "$acceptance_user" -- \
        env -i \
        HOME="$acceptance_home" \
        USER="$acceptance_user" \
        LOGNAME="$acceptance_user" \
        PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        LANG=C.UTF-8 \
        DOCKER_HOST="unix://${socket_path}" \
        /bin/bash -c 'cd -- "$1" || exit; shift; exec "$@"' \
        agentforge-pdk "$staged_fixture" "$pdk_bin" "$@"
}

run_bundle_command() {
    run_pdk "$@" || return $?
    verify_stage
}

verify_provider() {
    "$podman_service_helper" status >/dev/null
}

verify_no_containers() {
    local containers

    verify_provider
    containers="$(
        runuser --user "$acceptance_user" -- \
            env -i \
            HOME="$acceptance_home" \
            USER="$acceptance_user" \
            LOGNAME="$acceptance_user" \
            PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
            XDG_RUNTIME_DIR="$runtime_dir" \
            "$podman" --remote --url "unix://${socket_path}" ps --all --quiet
    )" || fail "Could not verify the Phase 5a Podman container inventory."
    [[ -z "$containers" ]] || fail "Podman containers remain; run the Litmus teardown before stopping or cleaning."
}

show_podman_info() {
    verify_provider
    runuser --user "$acceptance_user" -- \
        env -i \
        HOME="$acceptance_home" \
        USER="$acceptance_user" \
        LOGNAME="$acceptance_user" \
        PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        XDG_RUNTIME_DIR="$runtime_dir" \
        DOCKER_HOST="unix://${socket_path}" \
        "$podman" --remote --url "unix://${socket_path}" info --debug
}

stage_fixture() {
    local temporary_directory source_hash lock_hash stage_created=0 metadata_created=0

    cleanup_stage_attempt() {
        if [[ -n "${temporary_directory:-}" && -d "$temporary_directory" && ! -L "$temporary_directory" ]]; then
            rm -rf -- "$temporary_directory"
        fi
        if (( stage_created )) && [[ -d "$staged_fixture" && ! -L "$staged_fixture" ]]; then
            rm -rf -- "$staged_fixture"
        fi
        if (( metadata_created )) && [[ -d "$metadata_dir" && ! -L "$metadata_dir" ]]; then
            rm -rf -- "$metadata_dir"
        fi
    }

    verify_identity
    verify_source_fixture
    systemctl is-active --quiet "$service_unit" && fail "Stop the provider before staging a new fixture."
    [[ ! -e "$staged_fixture" && ! -L "$staged_fixture" ]] || fail "A staged fixture already exists; clean it after teardown before restaging."
    [[ ! -e "$metadata_dir" && ! -L "$metadata_dir" ]] || fail "Staging metadata already exists; inspect it before restaging."

    trap cleanup_stage_attempt EXIT
    temporary_directory="$(mktemp -d "${acceptance_home}/.phase5a-stage.XXXXXX")"

    cp -R -- \
        "${fixture_source}/.fixtures.yml" \
        "${fixture_source}/Gemfile" \
        "${fixture_source}/Gemfile.lock" \
        "${fixture_source}/Rakefile" \
        "${fixture_source}/metadata.json" \
        "${fixture_source}/provision.yaml" \
        "${fixture_source}/spec" \
        "${fixture_source}/target" \
        "$temporary_directory/"
    chmod -R u+rwX,go-rwx "$temporary_directory"
    chown -R "${acceptance_uid}:${acceptance_gid}" "$temporary_directory"

    source_hash="$(fixture_fingerprint "$fixture_source")"
    lock_hash="$(lockfile_fingerprint "$temporary_directory")"
    install -d -o root -g root -m 0700 "$metadata_dir"
    metadata_created=1
    printf '%s\n' "$source_hash" > "${metadata_dir}/fixture.sha256"
    printf '%s\n' "$lock_hash" > "${metadata_dir}/lockfiles.sha256"
    chmod 0600 "$source_hash_file" "$lock_hash_file"
    mv -T -- "$temporary_directory" "$staged_fixture"
    stage_created=1
    temporary_directory=""
    trap - EXIT

    printf 'staged_fixture=%s owner=%s:%s mode=0700\n' "$staged_fixture" "$acceptance_uid" "$acceptance_gid"
}

print_versions() {
    local pdk_version

    verify_stage
    pdk_version="$(run_pdk --version)"
    [[ "$pdk_version" == "4.0.1" ]] || fail "Expected PDK 4.0.1, got: $pdk_version."
    printf 'PDK version: %s\n' "$pdk_version"
    run_pdk bundle exec ruby --version
    run_pdk bundle exec bundle --version
    run_pdk bundle exec ruby -e 'puts Gem::Specification.find_by_name("puppet_litmus").version'
}

start_provider() {
    verify_stage
    "$podman_service_helper" start
    verify_no_containers
}

stop_provider() {
    verify_no_containers
    "$podman_service_helper" stop
}

run_acceptance() {
    local test_status teardown_status=0

    if run_bundle_command bundle exec rake litmus:acceptance:parallel; then
        return 0
    else
        test_status=$?
    fi

    printf 'Acceptance task failed with status %s; attempting Litmus teardown.\n' "$test_status" >&2
    if run_bundle_command bundle exec rake litmus:tear_down; then
        if verify_no_containers; then
            :
        else
            teardown_status=$?
        fi
    else
        teardown_status=$?
    fi

    if (( teardown_status != 0 )); then
        printf 'ERROR: Automatic teardown failed after the acceptance task failure.\n' >&2
    fi
    return "$test_status"
}

clean_fixture() {
    verify_no_containers
    [[ -d "$staged_fixture" && ! -L "$staged_fixture" ]] || fail "No safe staged fixture exists to clean."
    [[ "$(stat -c '%u:%g:%a' "$staged_fixture")" == "${acceptance_uid}:${acceptance_gid}:700" ]] \
        || fail "Staged fixture has unexpected ownership or mode."
    [[ -f "$source_hash_file" && ! -L "$source_hash_file" ]] || fail "Fixture source metadata is missing or unsafe."
    [[ -f "$lock_hash_file" && ! -L "$lock_hash_file" ]] || fail "Fixture lock metadata is missing or unsafe."
    rm -rf -- "$staged_fixture"
    rm -f -- "$source_hash_file" "$lock_hash_file"
    rmdir -- "$metadata_dir"
    printf 'staged_fixture_removed=yes graphroot_preserved=%s\n' "$storage_root"
}

main() {
    local action="${1:-}"

    [[ -n "$action" ]] || fail "Usage: $0 {stage|versions|install|list|start-provider|info|provision|connectivity|acceptance|teardown|clean|stop-provider}"
    shift
    (($# == 0)) || fail "This wrapper accepts no arguments after its action."
    require_root
    verify_identity
    cd /
    exec 9>/run/lock/agentforge-phase5a-pdk-wrapper.lock
    flock -n 9 || fail "Another Phase 5a PDK wrapper action is running."

    case "$action" in
        stage)
            stage_fixture
            ;;
        versions)
            print_versions
            ;;
        install)
            verify_stage
            command -v make >/dev/null 2>&1 || fail "make is required; install the approved build-essential toolchain."
            command -v gcc >/dev/null 2>&1 || fail "gcc is required; install the approved build-essential toolchain."
            verify_pdk
            run_bundle_command bundle install
            ;;
        list)
            verify_stage
            verify_pdk
            run_bundle_command bundle exec rake -T litmus
            ;;
        start-provider)
            start_provider
            ;;
        info)
            verify_stage
            show_podman_info
            ;;
        provision)
            verify_stage
            verify_pdk
            verify_provider
            [[ ! -e "${staged_fixture}/spec/fixtures/litmus_inventory.yaml" ]] \
                || fail "A Litmus inventory already exists; tear down the current target before provisioning again."
            run_bundle_command bundle exec rake 'litmus:provision_list[phase5a]'
            ;;
        connectivity)
            verify_stage
            verify_pdk
            verify_provider
            [[ -f "${staged_fixture}/spec/fixtures/litmus_inventory.yaml" && ! -L "${staged_fixture}/spec/fixtures/litmus_inventory.yaml" ]] \
                || fail "No Litmus inventory exists; provision the target first."
            run_bundle_command bundle exec rake litmus:check_connectivity
            ;;
        acceptance)
            verify_stage
            verify_pdk
            verify_provider
            [[ -f "${staged_fixture}/spec/fixtures/litmus_inventory.yaml" && ! -L "${staged_fixture}/spec/fixtures/litmus_inventory.yaml" ]] \
                || fail "No Litmus inventory exists; provision the target first."
            run_acceptance
            ;;
        teardown)
            verify_stage
            verify_pdk
            verify_provider
            [[ -f "${staged_fixture}/spec/fixtures/litmus_inventory.yaml" && ! -L "${staged_fixture}/spec/fixtures/litmus_inventory.yaml" ]] \
                || fail "No Litmus inventory exists; there is no target to tear down."
            run_bundle_command bundle exec rake litmus:tear_down
            verify_no_containers
            ;;
        clean)
            clean_fixture
            ;;
        stop-provider)
            stop_provider
            ;;
        *)
            fail "Unknown action: $action."
            ;;
    esac
}

main "$@"
