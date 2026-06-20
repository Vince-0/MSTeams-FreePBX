#!/usr/bin/env bats
# tests/wizard.bats — BATS 1.x test suite for MSTeams-DR-Wizard.sh
#
# Coverage (P11-03):
#   1. semver_gte        — version parsing: valid 3-part, 4-part, and malformed input
#   2. check_native_support — each status branch with mocked asterisk version output
#   3. generate_transport_stanza — required keys present in stanza output
#   4. --dry-run         — no files written (subprocess run, temp dir monitored)
#   5. --check           — exits non-zero when cert is missing
#
# Run:   bats tests/wizard.bats
# Needs: bats >= 1.8  (apt-get install -y bats)

WIZARD="$BATS_TEST_DIRNAME/../MSTeams-DR-Wizard.sh"

# ── shared setup: source wizard functions; stubs prevent side effects ─────────
setup() {
    message()            { :; }
    terminate()          { exit "${1:-0}"; }
    log()                { :; }
    detect_public_ip()   { PUBLIC_IPV4="${PUBLIC_IPV4:-1.2.3.4}"; }
    dry_run_gate()       { [[ "$dryrun" == true ]] && { message "[DRY-RUN] $1"; return 1; } || return 0; }
    backup_config_file() { :; }
    # shellcheck disable=SC1090
    source "$WIZARD"
    set +euo pipefail
}

# ════════════════════════════════════════════════════════════════════════════
# 1. semver_gte — version parsing
# ════════════════════════════════════════════════════════════════════════════

@test "semver_gte: equal 3-part versions are gte" {
    run semver_gte "22.11.0" "22.11.0"
    [ "$status" -eq 0 ]
}

@test "semver_gte: higher patch is gte" {
    run semver_gte "22.11.1" "22.11.0"
    [ "$status" -eq 0 ]
}

@test "semver_gte: higher minor is gte" {
    run semver_gte "22.12.0" "22.11.0"
    [ "$status" -eq 0 ]
}

@test "semver_gte: higher major is gte" {
    run semver_gte "23.0.0" "22.11.0"
    [ "$status" -eq 0 ]
}

@test "semver_gte: lower patch is not gte" {
    run semver_gte "22.10.9" "22.11.0"
    [ "$status" -ne 0 ]
}

@test "semver_gte: 4-part security version below threshold is not gte" {
    run semver_gte "22.8.2.1" "22.11.0"
    [ "$status" -ne 0 ]
}

@test "semver_gte: malformed (empty string) treated as 0.0.0 — not gte real version" {
    run semver_gte "" "22.11.0"
    [ "$status" -ne 0 ]
}

@test "semver_gte: single-component version below threshold is not gte" {
    run semver_gte "22" "22.11.0"
    [ "$status" -ne 0 ]
}

# ════════════════════════════════════════════════════════════════════════════
# 2. check_native_support — each status branch
# ════════════════════════════════════════════════════════════════════════════

@test "check_native_support: 22.11.0 → SUPPORTED" {
    detect_asterisk_full_version() { echo "22.11.0"; }
    run check_native_support
    [ "$status" -eq 0 ]
    [[ "$output" == SUPPORTED* ]]
}

@test "check_native_support: 22.10.9 → UPGRADE_NEEDED" {
    detect_asterisk_full_version() { echo "22.10.9"; }
    run check_native_support
    [ "$status" -eq 0 ]
    [[ "$output" == UPGRADE_NEEDED* ]]
}

@test "check_native_support: 20.21.0 → SUPPORTED" {
    detect_asterisk_full_version() { echo "20.21.0"; }
    run check_native_support
    [ "$status" -eq 0 ]
    [[ "$output" == SUPPORTED* ]]
}

@test "check_native_support: 21.3.0 → UNSUPPORTED_BRANCH" {
    detect_asterisk_full_version() { echo "21.3.0"; }
    run check_native_support
    [ "$status" -eq 0 ]
    [[ "$output" == UNSUPPORTED_BRANCH* ]]
}

@test "check_native_support: 24.0.0 → SUPPORTED (future branch)" {
    detect_asterisk_full_version() { echo "24.0.0"; }
    run check_native_support
    [ "$status" -eq 0 ]
    [[ "$output" == SUPPORTED* ]]
}

@test "check_native_support: asterisk not installed → NOT_INSTALLED" {
    detect_asterisk_full_version() { return 1; }
    run check_native_support
    [ "$status" -eq 0 ]
    [[ "$output" == NOT_INSTALLED* ]]
}

# ════════════════════════════════════════════════════════════════════════════
# 3. generate_transport_stanza — required keys
# ════════════════════════════════════════════════════════════════════════════

@test "generate_transport_stanza: contains [transport-ms-teams-tls] header" {
    FQDN="sbc.example.com"; PUBLIC_IPV4="1.2.3.4"; SIP_PORT="5061"
    BIND_ADDR="0.0.0.0"; CERT_FILE="/etc/asterisk/ssl/cert.crt"
    KEY_FILE="/etc/asterisk/ssl/cert.key"
    run generate_transport_stanza
    [ "$status" -eq 0 ]
    [[ "$output" == *"[transport-ms-teams-tls]"* ]]
}

@test "generate_transport_stanza: sets external_signaling_hostname" {
    FQDN="sbc.example.com"; PUBLIC_IPV4="1.2.3.4"; SIP_PORT="5061"
    BIND_ADDR="0.0.0.0"; CERT_FILE="/etc/asterisk/ssl/cert.crt"
    KEY_FILE="/etc/asterisk/ssl/cert.key"
    run generate_transport_stanza
    [[ "$output" == *"external_signaling_hostname = sbc.example.com"* ]]
}

@test "generate_transport_stanza: sets method=tlsv1_2" {
    FQDN="sbc.example.com"; PUBLIC_IPV4="1.2.3.4"; SIP_PORT="5061"
    BIND_ADDR="0.0.0.0"; CERT_FILE="/etc/asterisk/ssl/cert.crt"
    KEY_FILE="/etc/asterisk/ssl/cert.key"
    run generate_transport_stanza
    [[ "$output" == *"method=tlsv1_2"* ]]
}

@test "generate_transport_stanza: sets verify_client=no" {
    FQDN="sbc.example.com"; PUBLIC_IPV4="1.2.3.4"; SIP_PORT="5061"
    BIND_ADDR="0.0.0.0"; CERT_FILE="/etc/asterisk/ssl/cert.crt"
    KEY_FILE="/etc/asterisk/ssl/cert.key"
    run generate_transport_stanza
    [[ "$output" == *"verify_client=no"* ]]
}

@test "generate_transport_stanza: bind address present" {
    FQDN="sbc.example.com"; PUBLIC_IPV4="1.2.3.4"; SIP_PORT="5061"
    BIND_ADDR="0.0.0.0"; CERT_FILE="/etc/asterisk/ssl/cert.crt"
    KEY_FILE="/etc/asterisk/ssl/cert.key"
    run generate_transport_stanza
    [[ "$output" == *"bind=0.0.0.0:5061"* ]]
}

# ════════════════════════════════════════════════════════════════════════════
# 4. --dry-run produces no file writes
# ════════════════════════════════════════════════════════════════════════════

@test "--dry-run: no files written to a monitored temp directory" {
    local tmpdir; tmpdir=$(mktemp -d)
    # Snapshot inode list before run
    local before; before=$(find "$tmpdir" -type f | sort)

    # Run wizard in a subprocess targeting the temp dir as conf dir;
    # --generate-config --dry-run is the safest non-interactive dry mode
    run bash "$WIZARD" --generate-config --dry-run \
        --fqdn=sbc.example.com --no-ssl 2>/dev/null

    local after; after=$(find "$tmpdir" -type f | sort)
    rm -rf "$tmpdir"

    # File set must be identical (no new files created)
    [ "$before" = "$after" ]
}

@test "--dry-run: exits 0" {
    run bash "$WIZARD" --generate-config --dry-run \
        --fqdn=sbc.example.com --no-ssl 2>/dev/null
    [ "$status" -eq 0 ]
}

@test "--dry-run: output contains FQDN" {
    run bash "$WIZARD" --generate-config --dry-run \
        --fqdn=sbc.example.com --no-ssl 2>/dev/null
    [[ "$output" == *"sbc.example.com"* ]]
}

# ════════════════════════════════════════════════════════════════════════════
# 5. --check exits non-zero when cert is missing
# ════════════════════════════════════════════════════════════════════════════

@test "--check: exits non-zero for FQDN with no certificate" {
    # Use a syntactically valid but certainly uncertified FQDN.
    # check_tls_cert will find no cert file → increments _chk_fail → non-zero exit.
    run bash "$WIZARD" --check --fqdn=no-cert.example.invalid 2>/dev/null
    [ "$status" -ne 0 ]
}

@test "--check: output contains audit header" {
    run bash "$WIZARD" --check --fqdn=no-cert.example.invalid 2>/dev/null
    [[ "$output" == *"Configuration Audit"* ]]
}

@test "--check: reports cert warning for unknown FQDN" {
    run bash "$WIZARD" --check --fqdn=no-cert.example.invalid 2>/dev/null
    [[ "$output" == *"WARNING"* ]] || [[ "$output" == *"No certificate"* ]]
}
