#!/bin/bash
#####################################################################################
# @author https://github.com/Vince-0
#
# Use at your own risk.
#
# MS Teams Direct Routing Wizard
# Configures Asterisk for MS Teams Direct Routing using the native
# external_signaling_hostname PJSIP transport option introduced in Asterisk PR #1960.
#
# No source patching. No module replacement.
#
# Requires:
#   Debian 12 (Bookworm)
#   Asterisk 20.21.0+, 22.11.0+, 23.5.0+, or 24+
#
# Supported Modes:
#   (default)          Interactive wizard: detect environment, configure transport
#   --greenfield       Build and install vanilla Asterisk from source, then configure
#   --check            Read-only audit: version, cert, DNS, firewall, transport config
#   --ssl-only         Certificate management only (issue/renew RSA cert via certbot)
#   --generate-config  Print PJSIP config snippets to stdout without writing files
#   --dry-run          Show all actions that would be taken without making any changes
#
# Design decisions:
#   - FreePBX config: _custom.conf file injection only (no fwconsole DB/GUI changes)
#   - Greenfield: vanilla Asterisk only (no FreePBX installation)
#   - Asterisk 21: not supported by this script (future separate patch plan)
#
#####################################################################################

set -euo pipefail

## ── GLOBALS ──────────────────────────────────────────────────────────────────────

WIZARD_VERSION="1.0.0"
SCRIPT_NAME="MSTeams-DR-Wizard"
LOG_FILE="/var/log/msteams-dr-wizard/wizard.log"

# Native external_signaling_hostname minimum versions per major branch
# Branches not listed here are unsupported (21) or fully supported without a floor (24+)
declare -A MIN_NATIVE_VERSION
MIN_NATIVE_VERSION=([20]="20.21.0" [22]="22.11.0" [23]="23.5.0")

# Branches with native support (21 is deliberately absent)
NATIVE_SUPPORTED_MAJORS="20 22 23 24"

# Runtime state
ASTVERSION=""          # Detected or user-specified major version
AST_FULL_VERSION=""    # Detected full semver (e.g. 22.11.0)
CPU_ARCH=""            # Kernel arch name (uname -m)
DEBIAN_ARCH=""         # Debian arch name (amd64, arm64, ...)
SSL_EMAIL=""
SKIP_SSL=false
SSL_STATUS="Not requested"
USE_EXISTING_CERT=false
FREEPBX_MODE=false     # Set true when fwconsole is found on PATH
CLI_FQDN=""            # FQDN override from --fqdn flag
FQDN=""                # Resolved FQDN used throughout the script
PUBLIC_IPV4=""         # Detected public IP

# Mode flags
MODE_GREENFIELD=false
MODE_CHECK=false
MODE_SSL_ONLY=false
MODE_GENERATE_CONFIG=false
dryrun=false
ASTVERSION_FROM_CLI=false

# Config target paths (resolved after FreePBX detection)
PJSIP_TRANSPORT_CONF=""   # Path where transport stanza is written
PJSIP_ENDPOINT_CONF=""    # Path where endpoint/identify stanza is written
ASTERISK_CONF_DIR="/etc/asterisk"

# Build paths (greenfield only)
SRCDIR="/usr/src"
ASTERISK_SRC_DIR=""    # Resolved extracted source directory (set by extract_asterisk_source)
ASTERISK_PREFIX=""
ASTERISK_SYSCONFDIR=""
ASTERISK_LOCALSTATEDIR=""
TARBALL=""             # Resolved tarball filename (set by select_asterisk_tarball)
TARBALL_URL=""         # Resolved download URL (set by select_asterisk_tarball)
LAST_BACKUP_PATH=""    # Set by backup_etc_asterisk to the path of the most recent backup
ASTERISK_SERVICE_CREATED=false
ASTERISK_SERVICE_ENABLED=false
ASTERISK_SAMPLES_INSTALLED=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Null-reference all future-phase globals so ShellCheck SC2034 stays clean
# during incremental development. The : builtin is a no-op; this has no runtime cost.
: "${MIN_NATIVE_VERSION[*]:-}" "${NATIVE_SUPPORTED_MAJORS:-}" "${AST_FULL_VERSION:-}" \
  "${SSL_STATUS:-}" "${PUBLIC_IPV4:-}" "${SRCDIR:-}" "${ASTERISK_SRC_DIR:-}" \
  "${ASTERISK_PREFIX:-}" "${ASTERISK_SYSCONFDIR:-}" "${ASTERISK_LOCALSTATEDIR:-}" \
  "${TARBALL:-}" "${TARBALL_URL:-}" "${LAST_BACKUP_PATH:-}" \
  "${ASTERISK_SERVICE_CREATED:-}" "${ASTERISK_SERVICE_ENABLED:-}" \
  "${ASTERISK_SAMPLES_INSTALLED:-}" "${SCRIPT_DIR:-}" \
  "${ASTVERSION_FROM_CLI:-}" "${PJSIP_ENDPOINT_CONF:-}"

## ── BOOTSTRAP ────────────────────────────────────────────────────────────────────

mkdir -p "$(dirname "$LOG_FILE")"
: > "$LOG_FILE"    # truncate/create on each run

# Root check (deferred until after --help so help works without root)
_require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: This script must be run as root." >&2
        exit 1
    fi
}

# Ensure wget is available (needed for Asterisk tarball downloads)
_ensure_wget() {
    if ! command -v wget >/dev/null 2>&1; then
        echo "wget not found; installing..."
        apt-get update -q && apt-get install -y wget
    fi
}

## ── HELPER FUNCTIONS ─────────────────────────────────────────────────────────────

log() {
    echo "$(date +"%Y-%m-%d %T") - $*" >> "$LOG_FILE"
}

message() {
    echo "$(date +"%Y-%m-%d %T") - $*"
    echo "$(date +"%Y-%m-%d %T") - $*" >> "$LOG_FILE"
}

cleanup() {
    if [[ -n "${pidfile:-}" && -f "$pidfile" ]]; then
        rm -f "$pidfile"
    fi
}

terminate() {
    local exit_code="${1:-0}"
    cleanup
    exit "$exit_code"
}

## ── ARCHITECTURE DETECTION ───────────────────────────────────────────────────────

detect_cpu_arch() {
    local arch
    arch=$(uname -m)
    if [[ -n "$arch" ]]; then echo "$arch"; return 0; fi
    return 1
}

detect_debian_arch() {
    local debian_arch
    if command -v dpkg >/dev/null 2>&1; then
        debian_arch=$(dpkg --print-architecture 2>/dev/null)
        if [[ -n "$debian_arch" ]]; then echo "$debian_arch"; return 0; fi
    fi
    return 1
}

map_to_debian_arch() {
    local cpu_arch="$1"
    case "$cpu_arch" in
        x86_64)   echo "amd64"   ;;
        aarch64)  echo "arm64"   ;;
        armv7l)   echo "armhf"   ;;
        i686|i386) echo "i386"   ;;
        ppc64le)  echo "ppc64el" ;;
        amd64|arm64|armhf|armel|ppc64el|s390x|mips64el|riscv64) echo "$cpu_arch" ;;
        *)        echo "$cpu_arch" ;;
    esac
}

map_to_kernel_arch() {
    local debian_arch="$1"
    case "$debian_arch" in
        amd64)   echo "x86_64"  ;;
        arm64)   echo "aarch64" ;;
        armhf)   echo "armv7l"  ;;
        i386)    echo "i686"    ;;
        ppc64el) echo "ppc64le" ;;
        *)       echo "$debian_arch" ;;
    esac
}

## ── OS VALIDATION ────────────────────────────────────────────────────────────────

validate_os() {
    if [[ ! -f /etc/os-release ]]; then
        message "WARNING: Cannot determine OS — /etc/os-release not found. Proceeding anyway."
        return 0
    fi
    local os_id os_version_id
    # shellcheck source=/dev/null
    os_id=$(. /etc/os-release && echo "${ID:-unknown}")
    os_version_id=$(. /etc/os-release && echo "${VERSION_ID:-unknown}")
    if [[ "$os_id" != "debian" ]]; then
        message "WARNING: Script targets Debian 12. Detected OS: $os_id $os_version_id — proceeding."
        return 0
    fi
    if [[ "$os_version_id" != "12" ]]; then
        message "WARNING: Debian $os_version_id detected; targets Debian 12 (Bookworm) — proceeding."
    else
        message "OS: Debian 12 (Bookworm) [OK]"
    fi
}

## ── FREEPBX DETECTION ────────────────────────────────────────────────────────────

detect_freepbx() {
    if command -v fwconsole >/dev/null 2>&1; then
        FREEPBX_MODE=true
        message "FreePBX detected (fwconsole on PATH)."
        PJSIP_TRANSPORT_CONF="${ASTERISK_CONF_DIR}/pjsip.transports_custom_post.conf"
        PJSIP_ENDPOINT_CONF="${ASTERISK_CONF_DIR}/pjsip.endpoint_custom_post.conf"
    else
        FREEPBX_MODE=false
        message "FreePBX not detected — standalone Asterisk mode."
        PJSIP_TRANSPORT_CONF="${ASTERISK_CONF_DIR}/pjsip.conf"
        PJSIP_ENDPOINT_CONF="${ASTERISK_CONF_DIR}/pjsip_msteams_endpoint.conf"
    fi
}

## ── FQDN & DNS VALIDATION (Phase 3) ─────────────────────────────────────────────

# Resolve and validate the FQDN.
# Priority: --fqdn flag → system hostname.
# Rejects bare names without a dot (e.g. "localhost").
# Sets the global FQDN variable.
resolve_fqdn() {
    if [[ -n "$CLI_FQDN" ]]; then
        FQDN="$CLI_FQDN"
        message "Using FQDN from --fqdn: '${FQDN}'"
    else
        FQDN=$(hostname -f 2>/dev/null || hostname)
        message "Using system hostname as FQDN: '${FQDN}'"
    fi
    if [[ "$FQDN" != *.* ]]; then
        message "ERROR: FQDN '${FQDN}' does not contain a dot — not a valid FQDN."
        message "  Use --fqdn=sbc.example.com to specify a valid FQDN."
        terminate 1
    fi
    message "FQDN '${FQDN}' appears valid."
}

# Detect this host's public IPv4 address.
# Tries multiple providers; falls back to a placeholder on failure.
# Sets the global PUBLIC_IPV4 variable.
detect_public_ip() {
    if [[ -n "$PUBLIC_IPV4" ]]; then
        message "Public IPv4 (already set): ${PUBLIC_IPV4}"
        return 0
    fi
    message "Detecting public IPv4 address..."
    local ip=""
    # Try curl providers in order; stop at first success
    local providers=(
        "https://api4.ipify.org"
        "https://ifconfig.me"
        "https://ipv4.icanhazip.com"
    )
    local p
    for p in "${providers[@]}"; do
        ip=$(curl -4 -s --max-time 5 "$p" 2>/dev/null | tr -d '[:space:]' || true)
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            break
        fi
        ip=""
    done
    # Fallback: parse default route
    if [[ -z "$ip" ]]; then
        ip=$(ip route get 1.1.1.1 2>/dev/null \
             | grep -oP 'src \K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    fi
    if [[ -z "$ip" ]]; then
        message "WARNING: Could not detect public IPv4 address; using placeholder."
        PUBLIC_IPV4="YOUR.PUBLIC.IP"
    else
        PUBLIC_IPV4="$ip"
        message "Detected public IPv4: ${PUBLIC_IPV4}"
    fi
}

# Resolve the FQDN via DNS and compare against the detected public IP.
# Returns 0 if the FQDN resolves to the public IP, 1 otherwise (with a warning).
# Never aborts the script — DNS mismatches are a warning, not a hard error.
verify_dns_resolution() {
    local fqdn="${1:-${FQDN:-}}"
    if [[ -z "$fqdn" ]]; then
        message "WARNING: verify_dns_resolution: FQDN not set."
        return 1
    fi

    # Ensure we have a public IP to compare against
    detect_public_ip

    message ""
    message "── DNS Resolution Check ──"
    message "  FQDN:       ${fqdn}"
    message "  Public IP:  ${PUBLIC_IPV4}"

    # Resolve using dig (preferred) or host
    local resolved=""
    if command -v dig >/dev/null 2>&1; then
        resolved=$(dig +short A "$fqdn" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)
    elif command -v host >/dev/null 2>&1; then
        resolved=$(host "$fqdn" 2>/dev/null \
                   | grep "has address" | awk '{print $NF}' | head -1 || true)
    else
        message "  WARNING: Neither 'dig' nor 'host' is available; skipping DNS check."
        message "  Install dnsutils:  apt-get install -y dnsutils"
        return 1
    fi

    if [[ -z "$resolved" ]]; then
        message "  WARNING: ${fqdn} does not resolve to any IPv4 address."
        message "  MS Teams Direct Routing requires your SBC FQDN to be publicly resolvable."
        message "  Add an A record:  ${fqdn}  →  ${PUBLIC_IPV4}"
        return 1
    fi

    message "  DNS resolves to: ${resolved}"

    if [[ "$resolved" == "$PUBLIC_IPV4" ]]; then
        message "  DNS → Public IP match [OK]"
        return 0
    else
        message "  WARNING: ${fqdn} resolves to ${resolved}, but this host's public IP is ${PUBLIC_IPV4}."
        message "  If this SBC is behind NAT, this may be expected (hairpin / split-horizon DNS)."
        message "  MS Teams will connect to ${resolved} — ensure it routes to this machine on port 5061."
        return 1
    fi
}

# Interactive DNS check: warn on mismatch and require confirmation to continue.
# Exits cleanly on 'N'; returns 0 (continue) on 'Y' or when non-interactive.
dns_check_with_confirm() {
    local fqdn="${1:-${FQDN:-}}"
    local dns_ok=true
    verify_dns_resolution "$fqdn" || dns_ok=false

    if [[ "$dns_ok" == false && "$dryrun" == false ]]; then
        echo ""
        echo "  DNS check FAILED for ${fqdn}."
        echo "  MS Teams Direct Routing requires the FQDN to resolve to this host."
        echo -n "  Continue anyway? (y/N) [N]: "
        local ans
        read -r ans
        ans="${ans:-N}"
        message "User DNS-mismatch confirmation: '${ans}'"
        case "${ans^^}" in
            Y) message "User chose to continue despite DNS mismatch." ;;
            *) message "Aborted — DNS check failed and user chose not to continue."
               terminate 0 ;;
        esac
    fi
}

## ── SHOW HELP ────────────────────────────────────────────────────────────────────

show_help() {
    cat <<EOF
${SCRIPT_NAME} v${WIZARD_VERSION}

Usage: $0 [MODE] [OPTIONS]

Modes (mutually exclusive):
  (default)           Interactive wizard — detect environment, configure PJSIP transport
                      using native external_signaling_hostname (Asterisk PR #1960).
  --greenfield        Build vanilla Asterisk from source on bare Debian 12, then configure.
                      No FreePBX installation.
  --check             Read-only audit: version vs threshold, cert (RSA/chain/expiry),
                      DNS, active external_signaling_hostname, port 5061.
                      Exit 0 = all pass; non-zero = at least one check failed.
  --ssl-only          RSA certificate management only (issue/renew via certbot RSA 2048-bit).
  --generate-config   Print PJSIP transport + endpoint snippets to stdout; no files written.

Options:
  --version=<20|22|23|24>   Target Asterisk major version. Auto-detected if omitted.
  --fqdn=<name>             Override FQDN (must contain a dot). Defaults to system hostname.
  --email=<addr>            Email for Let's Encrypt. Required when obtaining a new cert.
  --use-existing-cert       Non-interactive: use existing cert; skip certbot.
  --no-ssl / --skip-ssl     Skip SSL step entirely.
  --dry-run / --debug       Print all actions without making any changes.
  -h, --help                Show this help and exit.

Supported Asterisk versions (native external_signaling_hostname):
  20.21.0+   22.11.0+   23.5.0+   24+
  Asterisk 21: NOT supported — use MSTeams-FreePBX-Install.sh (legacy patch script).

Examples:
  $0                                            # wizard, auto-detect
  $0 --check                                    # audit only
  $0 --generate-config --fqdn=sbc.example.com
  $0 --ssl-only --fqdn=sbc.example.com --email=admin@example.com
  $0 --greenfield --version=22 --fqdn=sbc.example.com --email=admin@example.com
  $0 --dry-run --fqdn=sbc.example.com
EOF
}

## ── MUTUAL EXCLUSION GUARD ───────────────────────────────────────────────────────

_count_active_modes() {
    local count=0
    [[ "$MODE_GREENFIELD"      == true ]] && (( count++ )) || true
    [[ "$MODE_CHECK"           == true ]] && (( count++ )) || true
    [[ "$MODE_SSL_ONLY"        == true ]] && (( count++ )) || true
    [[ "$MODE_GENERATE_CONFIG" == true ]] && (( count++ )) || true
    echo "$count"
}

## ── MODE STRING ──────────────────────────────────────────────────────────────────

_mode_description() {
    if   [[ "$MODE_GREENFIELD"      == true ]]; then echo "Greenfield vanilla Asterisk install + configure"
    elif [[ "$MODE_CHECK"           == true ]]; then echo "Read-only audit (--check)"
    elif [[ "$MODE_SSL_ONLY"        == true ]]; then echo "SSL certificate management only (--ssl-only)"
    elif [[ "$MODE_GENERATE_CONFIG" == true ]]; then echo "Generate PJSIP config snippets (--generate-config)"
    elif [[ "$dryrun"               == true ]]; then echo "Dry-run wizard (no changes)"
    else                                             echo "Interactive wizard (brownfield configure)"
    fi
}

## ── CONFIRM RUN OPTIONS ──────────────────────────────────────────────────────────

confirm_run_options() {
    local mode_desc ssl_desc fqdn_display confirm

    mode_desc=$(_mode_description)
    fqdn_display="${CLI_FQDN:-<auto-detect from hostname>}"

    if [[ "$SKIP_SSL" == true ]]; then
        ssl_desc="Skipped (--no-ssl)"
    elif [[ "$USE_EXISTING_CERT" == true ]]; then
        ssl_desc="Use existing certificate (--use-existing-cert)"
    elif [[ -n "$SSL_EMAIL" ]]; then
        ssl_desc="Let's Encrypt RSA 2048-bit via certbot (email: $SSL_EMAIL)"
    else
        ssl_desc="Interactive (will prompt for email or existing cert)"
    fi

    message "==================================================================="
    message "${SCRIPT_NAME} v${WIZARD_VERSION} — Run configuration:"
    message "  Mode:         $mode_desc"
    if [[ -n "$AST_FULL_VERSION" ]]; then
        message "  Asterisk:     ${AST_FULL_VERSION} (branch ${ASTVERSION})"
    else
        message "  Asterisk:     branch ${ASTVERSION:-<auto-detect>}"
    fi
    message "  Architecture: ${DEBIAN_ARCH:-<auto-detect>} (CPU: ${CPU_ARCH:-<auto-detect>})"
    message "  FQDN:         $fqdn_display"
    message "  FreePBX mode: ${FREEPBX_MODE}"
    message "  SSL:          $ssl_desc"
    [[ "$dryrun" == true ]] && message "  DRY-RUN:      YES — no changes will be made"
    message "==================================================================="

    # Skip confirmation prompt in non-interactive modes
    if [[ "$dryrun" == true || "$MODE_CHECK" == true || "$MODE_GENERATE_CONFIG" == true ]]; then
        return 0
    fi

    echo ""
    echo -n "Proceed with these settings? (y/n) [y]: "
    read -r confirm
    if [[ -n "$confirm" && ! "$confirm" =~ ^[Yy]$ ]]; then
        message "Aborted by user."; terminate 0
    fi
}

## ── DRY-RUN GATE ─────────────────────────────────────────────────────────────────

# dry_run_gate "Description" [command args...]
# In dry-run: prints what would happen and returns 1 (so callers can use
#   `if dry_run_gate ...; then <real cmd>; fi`  or  `dry_run_gate ... || return 0`).
# In live mode with no extra args: returns 0 (no-op gate — caller runs the real cmd).
# In live mode with extra args: executes them and returns their exit code.
dry_run_gate() {
    local description="$1"; shift
    if [[ "$dryrun" == true ]]; then
        message "[DRY-RUN] Would execute: $description"
        [[ $# -gt 0 ]] && message "[DRY-RUN]   Command: $*"
        return 1
    fi
    if [[ $# -gt 0 ]]; then
        "$@"
    fi
}

# dry_run_write_file <path> <content>
# In dry-run: prints what would be written.
dry_run_write_file() {
    local dest="$1"
    local content="$2"
    if [[ "$dryrun" == true ]]; then
        message "[DRY-RUN] Would write to: $dest"
        echo "$content" | sed 's/^/  [DRY-RUN]   /'
        return 0
    fi
    echo "$content" >> "$dest"
    message "Wrote to: $dest"
}

## ── VERSION DETECTION (Phase 1) ─────────────────────────────────────────────────

# Returns the full semver string of the installed Asterisk (e.g. "22.11.0", "22.8.2.1").
# Handles standard 3-part and 4-part security-release versions.
# Returns 1 if Asterisk is not installed or version cannot be parsed.
detect_asterisk_full_version() {
    if ! command -v asterisk >/dev/null 2>&1; then
        return 1
    fi
    local ver
    # asterisk -V outputs e.g. "Asterisk 22.11.0" or "Asterisk 22.8.2.1"
    ver=$(asterisk -V 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)
    if [[ -n "$ver" ]]; then
        echo "$ver"
        return 0
    fi
    return 1
}

# Compares two semver strings. Returns 0 if $1 >= $2, 1 otherwise.
# Handles 3-part (22.11.0) and 4-part (22.8.2.1) versions.
semver_gte() {
    local ver="$1" min="$2"
    local -a v m
    IFS='.' read -r -a v <<< "$ver"
    IFS='.' read -r -a m <<< "$min"
    local i
    for i in 0 1 2 3; do
        local vi="${v[$i]:-0}" mi="${m[$i]:-0}"
        (( vi > mi )) && return 0
        (( vi < mi )) && return 1
    done
    return 0  # equal counts as >=
}

# Check whether the installed Asterisk has native external_signaling_hostname support.
# Outputs a single line:  STATUS full_ver
#   STATUS is one of: SUPPORTED | UPGRADE_NEEDED | UNSUPPORTED_BRANCH | NOT_INSTALLED | UNKNOWN_BRANCH
#   full_ver is the detected semver string (empty for NOT_INSTALLED).
# All diagnostic log output goes to stderr so stdout is clean for parsing by the caller.
#
# Usage (parent shell):
#   read -r _status _full_ver <<< "$(check_native_support)"
#   AST_FULL_VERSION="$_full_ver"; ASTVERSION="${_full_ver%%.*}"
check_native_support() {
    local full_ver
    if ! full_ver=$(detect_asterisk_full_version); then
        echo "NOT_INSTALLED"
        return 0
    fi

    local major="${full_ver%%.*}"

    message "Detected Asterisk: ${full_ver} (major branch: ${major})" >&2

    local status
    case "$major" in
        21)
            status="UNSUPPORTED_BRANCH" ;;
        20|22|23)
            local min_ver="${MIN_NATIVE_VERSION[$major]:-}"
            if [[ -z "$min_ver" ]]; then
                status="UNKNOWN_BRANCH"
            elif semver_gte "$full_ver" "$min_ver"; then
                status="SUPPORTED"
            else
                status="UPGRADE_NEEDED"
            fi ;;
        *)
            # Branch 24 or later: native support present in all releases
            if (( major >= 24 )); then
                status="SUPPORTED"
            else
                # Branch < 20: too old
                status="UNKNOWN_BRANCH"
            fi ;;
    esac
    echo "$status $full_ver"
}

# Handle the result of check_native_support() interactively.
# Terminates the script if the situation is unrecoverable.
handle_version_check() {
    local status="$1"

    case "$status" in
        SUPPORTED)
            message "Asterisk ${AST_FULL_VERSION}: native external_signaling_hostname is available. [OK]"
            ;;

        UPGRADE_NEEDED)
            local min_ver="${MIN_NATIVE_VERSION[$ASTVERSION]:-unknown}"
            message "WARNING: Asterisk ${AST_FULL_VERSION} does not have native external_signaling_hostname support."
            message "  Branch ${ASTVERSION} minimum required version: ${min_ver}"
            message "  Upgrade to ${min_ver}+ then re-run, or use --version=<major> to target a supported branch."
            # In read-only / non-interactive modes: warn and continue (do not prompt).
            if [[ "$MODE_CHECK" == true || "$MODE_GENERATE_CONFIG" == true || "$dryrun" == true ]]; then
                message "  Continuing in read-only/dry-run mode despite version mismatch."
                return 0
            fi
            echo ""
            echo "  Options:"
            echo "    [U] Upgrade Asterisk ${ASTVERSION} in-place to latest ${ASTVERSION}.x"
            echo "        (Phase 8 — will be implemented in the next wizard release)"
            echo "    [C] Continue anyway (only if this build includes the feature separately)"
            echo "    [Q] Quit — upgrade Asterisk manually then re-run"
            echo -n "  Choice [Q]: "
            local choice
            read -r choice
            choice="${choice:-Q}"
            message "User version-upgrade choice: '${choice}'"
            case "${choice^^}" in
                U)
                    message "In-place upgrade selected — building Asterisk ${ASTVERSION}-current from source."
                    offer_asterisk_upgrade
                    # Re-check support after upgrade; if still failing, abort.
                    local _check_out _new_status _new_ver
                    _check_out=$(check_native_support 2>/dev/null)
                    read -r _new_status _new_ver <<< "$_check_out"
                    if [[ "$_new_status" == "SUPPORTED" ]]; then
                        message "Post-upgrade check: Asterisk ${_new_ver} — native support confirmed [OK]"
                        AST_FULL_VERSION="$_new_ver"
                        ASTVERSION="${_new_ver%%.*}"
                    else
                        message "ERROR: Post-upgrade version check returned: ${_new_status} ${_new_ver}"
                        message "  The installed Asterisk may still be below the minimum threshold."
                        message "  Verify manually: asterisk -V"
                        terminate 1
                    fi
                    ;;
                C)
                    message "User chose to continue despite version being below the threshold."
                    message "WARNING: external_signaling_hostname may not be available — config will be written but may have no effect."
                    ;;
                *)
                    message "Aborted — Asterisk version below minimum threshold for native support."
                    terminate 0
                    ;;
            esac
            ;;

        UNSUPPORTED_BRANCH)
            message "ERROR: Asterisk ${ASTVERSION} (branch 21) has no native external_signaling_hostname support."
            message "  Asterisk 21 reached end-of-life before this feature was backported."
            message "  For Asterisk 21, use the legacy patch-based installer:"
            message "    MSTeams-FreePBX-Install.sh"
            message "  A dedicated Asterisk 21 patch plan is planned as a follow-on release."
            terminate 1
            ;;

        NOT_INSTALLED)
            if [[ "$MODE_GREENFIELD" == true ]]; then
                message "Asterisk not installed — greenfield mode will install from source."
                if [[ -z "$ASTVERSION" ]]; then
                    message "No --version specified; defaulting to Asterisk 22 (LTS)."
                    ASTVERSION="22"
                fi
            else
                message "ERROR: Asterisk is not installed on this system."
                message "  Run with --greenfield to build and install Asterisk from source."
                message "  Or install Asterisk manually and re-run this wizard."
                terminate 1
            fi
            ;;

        UNKNOWN_BRANCH)
            message "WARNING: Asterisk ${ASTVERSION} is not a recognised supported branch."
            message "  This wizard targets: 20.21.0+  22.11.0+  23.5.0+  24+"
            message "  Proceeding with caution — external_signaling_hostname availability is unknown."
            ;;
    esac
}

## ── SSL / CERTIFICATE MANAGEMENT (Phase 2) ──────────────────────────────────────

# Print expiry date for a certificate file (for interactive display).
_show_cert_expiry() {
    local cert_file="$1"
    if [[ -f "$cert_file" ]] && command -v openssl >/dev/null 2>&1; then
        local expiry
        expiry=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null \
                 | sed 's/notAfter=//')
        if [[ -n "$expiry" ]]; then
            echo "  Certificate expires: $expiry"
            message "Certificate at $cert_file expires: $expiry"
        fi
    fi
}

# Copy cert files from a Let's Encrypt directory into /etc/asterisk/ssl/.
# Uses fullchain.pem (required for MS Teams chain validation).
# Dry-run-aware: no files written when dryrun=true.
_install_certs_from_dir() {
    local src="$1"
    local fullchain key

    if [[ -f "${src}/fullchain.pem" ]]; then
        fullchain="${src}/fullchain.pem"
    elif [[ -f "${src}/cert.pem" ]]; then
        message "WARNING: fullchain.pem not found; falling back to cert.pem (chain validation may fail)."
        fullchain="${src}/cert.pem"
    else
        message "ERROR: No cert/fullchain.pem found in $src"
        return 1
    fi

    key="${src}/privkey.pem"
    if [[ ! -f "$key" ]]; then
        message "ERROR: No privkey.pem found in $src"
        return 1
    fi

    if [[ "$dryrun" == true ]]; then
        message "[DRY-RUN] Would copy ${fullchain} → /etc/asterisk/ssl/cert.crt"
        message "[DRY-RUN] Would copy ${key}       → /etc/asterisk/ssl/privkey.crt"
        message "[DRY-RUN] Would copy ${fullchain} → /etc/asterisk/ssl/ca.crt"
        return 0
    fi

    mkdir -p /etc/asterisk/ssl
    cp "$fullchain" /etc/asterisk/ssl/cert.crt
    cp "$key"       /etc/asterisk/ssl/privkey.crt
    # ca.crt = same as fullchain for Asterisk TLS verification
    cp "$fullchain" /etc/asterisk/ssl/ca.crt
    message "Certificates copied from $src to /etc/asterisk/ssl/"
}

# Stop apache2 to free port 80 for certbot standalone challenge.
# Sets apache_was_running in the caller's scope (must be called with 'local' pre-declared).
_stop_apache2() {
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet apache2 2>/dev/null; then
            apache_was_running=true
            message "Stopping apache2 for standalone certbot challenge..."
            if [[ "$dryrun" == true ]]; then
                message "[DRY-RUN] Would: systemctl stop apache2"
            else
                systemctl stop apache2 || message "WARNING: Failed to stop apache2."
            fi
        fi
    elif command -v service >/dev/null 2>&1; then
        if service apache2 status >/dev/null 2>&1; then
            apache_was_running=true
            message "Stopping apache2 (via service) for standalone certbot challenge..."
            if [[ "$dryrun" == true ]]; then
                message "[DRY-RUN] Would: service apache2 stop"
            else
                service apache2 stop || message "WARNING: Failed to stop apache2."
            fi
        fi
    fi
}

# Restart apache2 if it was running before we stopped it.
_restart_apache2() {
    if [[ "$apache_was_running" == true ]]; then
        message "Restarting apache2..."
        if [[ "$dryrun" == true ]]; then
            message "[DRY-RUN] Would: systemctl start apache2"
            return 0
        fi
        if command -v systemctl >/dev/null 2>&1; then
            systemctl start apache2 || message "WARNING: Failed to restart apache2."
        elif command -v service >/dev/null 2>&1; then
            service apache2 start  || message "WARNING: Failed to restart apache2."
        fi
    fi
}

# Verify that a certificate uses RSA (not ECDSA).
# MS Teams Direct Routing requires RSA; ECDSA causes periodic Asterisk core dumps.
# Returns 0 if RSA, 1 if not RSA or cannot determine.
verify_cert_is_rsa() {
    local cert_file="${1:-}"
    if [[ -z "$cert_file" || ! -f "$cert_file" ]]; then
        message "WARNING: verify_cert_is_rsa: file not found: '${cert_file}'"
        return 1
    fi
    if ! command -v openssl >/dev/null 2>&1; then
        message "WARNING: openssl not found; cannot verify key algorithm."
        return 1
    fi
    local key_alg
    key_alg=$(openssl x509 -in "$cert_file" -noout -text 2>/dev/null \
              | grep "Public Key Algorithm" | awk '{print $NF}')
    if [[ "$key_alg" == *"rsaEncryption"* ]]; then
        message "  Key algorithm: RSA [OK]"
        return 0
    else
        message "WARNING: Certificate key algorithm is '${key_alg}' — MS Teams requires RSA."
        message "  ECDSA certificates cause Asterisk to crash (core dump) every ~60 s when MS Teams pings."
        message "  Replace with an RSA certificate:"
        message "    certbot certonly --standalone --key-type rsa --rsa-key-size 2048 -d ${FQDN}"
        return 1
    fi
}

# Verify that the cert_file path is fullchain.pem (not bare cert.pem).
# Returns 0 if fullchain, 1 if bare cert (with instructions printed).
verify_cert_chain() {
    local cert_file="${1:-}"
    if [[ -z "$cert_file" ]]; then return 1; fi
    if [[ "$cert_file" == *"fullchain.pem" ]]; then
        message "  Certificate chain: fullchain.pem [OK]"
        return 0
    else
        local dir
        dir=$(dirname "$cert_file")
        message "WARNING: cert_file appears to be '$(basename "$cert_file")' rather than fullchain.pem."
        message "  Using cert.pem (leaf cert only) causes TLS handshake failures with MS Teams:"
        message "  Teams cannot verify the intermediate CA chain and drops the connection silently."
        message "  Change your pjsip.conf transport stanza to:"
        message "    cert_file=${dir}/fullchain.pem"
        return 1
    fi
}

# Warn if a certificate expires within the threshold (default: 30 days).
# Returns 0 if healthy, 1 if expiring soon or already expired.
cert_expiry_check() {
    local cert_file="${1:-}" threshold="${2:-30}"
    if [[ -z "$cert_file" || ! -f "$cert_file" ]]; then return 1; fi
    if ! command -v openssl >/dev/null 2>&1; then return 1; fi
    local expiry expiry_epoch now_epoch days_left
    expiry=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | cut -d= -f2)
    expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
    if (( days_left < 0 )); then
        message "ERROR: Certificate has EXPIRED (${expiry})."
        message "  Renew with: certbot renew --cert-name ${FQDN} --key-type rsa --rsa-key-size 2048"
        return 1
    elif (( days_left < threshold )); then
        message "WARNING: Certificate expires in ${days_left} day(s) (${expiry})."
        message "  Renew soon: certbot renew --cert-name ${FQDN} --key-type rsa --rsa-key-size 2048"
        return 1
    else
        message "  Expires: ${expiry}  (${days_left} days remaining) [OK]"
        return 0
    fi
}

# Verify that the certificate CN or SAN covers the target FQDN.
# Returns 0 on match, 1 on mismatch or parse failure.
verify_fqdn_matches_cert() {
    local fqdn="${1:-$FQDN}" cert_file="${2:-}"
    if [[ -z "$cert_file" || ! -f "$cert_file" ]]; then return 1; fi
    if ! command -v openssl >/dev/null 2>&1; then return 1; fi
    local cn san_line
    cn=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null \
         | sed 's/.*CN\s*=\s*//' | cut -d/ -f1 | sed 's/[[:space:]]//g')
    san_line=$(openssl x509 -in "$cert_file" -noout -text 2>/dev/null \
               | grep -A1 "Subject Alternative Name" | tail -1)
    if [[ "$cn" == "$fqdn" || "$san_line" == *"DNS:${fqdn}"* ]]; then
        message "  FQDN match: ${fqdn} ↔ cert CN/SAN [OK]"
        return 0
    elif [[ "$cn" == "*."* ]]; then
        # Wildcard — check the base domain
        local base_cn="${cn#\*.}"
        if [[ "$fqdn" == *"${base_cn}" ]]; then
            message "  FQDN match: ${fqdn} covered by wildcard ${cn} [OK]"
            return 0
        fi
    fi
    message "WARNING: Certificate CN '${cn}' does not match FQDN '${fqdn}'."
    message "  external_signaling_hostname must match the certificate CN/SAN."
    return 1
}

# Read-only TLS certificate audit.  Called by --check mode (Phase 10) and at end of ssl install.
# Locates the certificate for $FQDN, then runs all three verification checks.
check_tls_cert() {
    local fqdn="${1:-${FQDN:-}}"
    local cert_file=""

    # Prefer fullchain.pem from Let's Encrypt live directory
    if [[ -f "/etc/letsencrypt/live/${fqdn}/fullchain.pem" ]]; then
        cert_file="/etc/letsencrypt/live/${fqdn}/fullchain.pem"
    elif [[ -f "/etc/letsencrypt/live/${fqdn}/cert.pem" ]]; then
        cert_file="/etc/letsencrypt/live/${fqdn}/cert.pem"
    elif [[ -f "/etc/asterisk/ssl/cert.crt" ]]; then
        cert_file="/etc/asterisk/ssl/cert.crt"
    else
        # Fall back: search for any fullchain.pem under /etc/letsencrypt
        cert_file=$(find /etc/letsencrypt/live/ -name "fullchain.pem" 2>/dev/null | head -1)
    fi

    message ""
    message "── TLS Certificate Audit (MS Teams Direct Routing requires RSA) ──"

    if [[ -z "$cert_file" ]]; then
        message "  WARNING: No certificate found for ${fqdn}."
        message "  Obtain an RSA certificate with:"
        message "    certbot certonly --standalone --non-interactive --agree-tos \\"
        message "      --key-type rsa --rsa-key-size 2048 --email <you@example.com> -d ${fqdn}"
        return 1
    fi

    message "  Certificate file: ${cert_file}"
    local overall_ok=true
    verify_cert_is_rsa    "$cert_file" || overall_ok=false
    verify_cert_chain     "$cert_file" || overall_ok=false
    cert_expiry_check     "$cert_file" || overall_ok=false
    verify_fqdn_matches_cert "$fqdn" "$cert_file" || overall_ok=false
    message "  Recommended pjsip.conf transport options:"
    message "    cert_file=$(dirname "$cert_file")/fullchain.pem"
    message "    priv_key_file=$(dirname "$cert_file")/privkey.pem"
    message "    method=tlsv1_2"
    [[ "$overall_ok" == true ]]
}

# Main SSL installation function.
# Installs or renews an RSA Let's Encrypt certificate for $FQDN and copies it to /etc/asterisk/ssl/.
# Dry-run-aware: certbot and all file operations are gated by dry_run_gate().
install_ssl() {
    local apache_was_running=false   # used by _stop_apache2/_restart_apache2
    local cert_source=""             # "certbot-new" | "certbot-renew" | ""

    if [[ "$SKIP_SSL" == true ]]; then
        message "SSL skipped (--no-ssl / --skip-ssl)."
        SSL_STATUS="Skipped: --no-ssl specified"
        return 0
    fi

    # ------------------------------------------------------------------
    # Detect existing certificates
    # ------------------------------------------------------------------
    local certbot_dir="/etc/letsencrypt/live/${FQDN}"
    local asterisk_ssl_dir="/etc/asterisk/ssl"
    local found_certbot=false found_asterisk=false

    if [[ -f "${certbot_dir}/fullchain.pem" && -f "${certbot_dir}/privkey.pem" ]]; then
        found_certbot=true
        message "Found existing Let's Encrypt certificate: ${certbot_dir}"
        _show_cert_expiry "${certbot_dir}/fullchain.pem"
    fi

    if [[ -f "${asterisk_ssl_dir}/cert.crt" && -f "${asterisk_ssl_dir}/privkey.crt" ]]; then
        found_asterisk=true
        message "Found existing certificate in /etc/asterisk/ssl/"
        _show_cert_expiry "${asterisk_ssl_dir}/cert.crt"
    fi

    # ------------------------------------------------------------------
    # --use-existing-cert: non-interactive path
    # ------------------------------------------------------------------
    if [[ "$USE_EXISTING_CERT" == true ]]; then
        if [[ "$found_certbot" == true ]]; then
            message "--use-existing-cert: copying Let's Encrypt certificate to /etc/asterisk/ssl/"
            _install_certs_from_dir "$certbot_dir" \
                || { SSL_STATUS="FAILED: could not copy certbot cert to /etc/asterisk/ssl/"; return 1; }
            SSL_STATUS="Installed: existing certbot certificate for ${FQDN}"
        elif [[ "$found_asterisk" == true ]]; then
            message "--use-existing-cert: certificate already in /etc/asterisk/ssl/; nothing to do."
            SSL_STATUS="Installed: existing certificate in /etc/asterisk/ssl/ (no changes made)"
        else
            message "ERROR: --use-existing-cert specified but no certificate found for ${FQDN}."
            message "  Run without --use-existing-cert to obtain a new one."
            SSL_STATUS="FAILED: no existing certificate found for ${FQDN}"
            return 1
        fi
        check_tls_cert "$FQDN"
        return 0
    fi

    # ------------------------------------------------------------------
    # Interactive prompt when an existing certificate is detected
    # ------------------------------------------------------------------
    if [[ "$found_certbot" == true || "$found_asterisk" == true ]]; then
        echo ""
        echo "Existing certificate(s) detected for ${FQDN}."
        echo "What would you like to do?"
        echo "  [U] Use existing certificate (copy/keep as-is)"
        echo "  [R] Renew with certbot (--key-type rsa --rsa-key-size 2048)"
        echo "  [O] Obtain new certificate with certbot"
        echo "  [S] Skip SSL"
        echo -n "Choice [U]: "
        local choice
        read -r choice
        choice="${choice:-U}"
        message "User SSL choice: '${choice}'"

        case "${choice^^}" in
            U)
                if [[ "$found_certbot" == true ]]; then
                    _install_certs_from_dir "$certbot_dir" \
                        || { SSL_STATUS="FAILED: could not copy certbot cert"; return 1; }
                    SSL_STATUS="Installed: existing certbot certificate for ${FQDN}"
                else
                    message "Using existing certificate already in /etc/asterisk/ssl/."
                    SSL_STATUS="Installed: existing certificate in /etc/asterisk/ssl/ (no changes)"
                fi
                check_tls_cert "$FQDN"
                return 0 ;;
            R)  cert_source="certbot-renew" ;;
            O)  cert_source="certbot-new" ;;
            S)
                message "User chose to skip SSL."
                SSL_STATUS="Skipped: user chose to skip SSL"
                return 0 ;;
            *)
                message "Unrecognised choice '${choice}'; defaulting to use existing."
                if [[ "$found_certbot" == true ]]; then
                    _install_certs_from_dir "$certbot_dir" \
                        || { SSL_STATUS="FAILED: could not copy certbot cert"; return 1; }
                    SSL_STATUS="Installed: existing certbot cert for ${FQDN}"
                else
                    SSL_STATUS="Installed: existing cert in /etc/asterisk/ssl/ (no changes)"
                fi
                check_tls_cert "$FQDN"
                return 0 ;;
        esac
    else
        # No existing cert found → go straight to obtaining a new one
        cert_source="certbot-new"
    fi

    # ------------------------------------------------------------------
    # certbot requires an email address
    # ------------------------------------------------------------------
    if [[ -z "$SSL_EMAIL" ]]; then
        echo -n "Email address for Let's Encrypt: "
        read -r SSL_EMAIL
        if [[ -z "$SSL_EMAIL" ]]; then
            message "ERROR: No email address supplied; cannot run certbot."
            SSL_STATUS="FAILED: no email address for certbot"
            return 1
        fi
        message "SSL email: ${SSL_EMAIL}"
    fi

    # ------------------------------------------------------------------
    # Install certbot if absent
    # ------------------------------------------------------------------
    if ! command -v certbot >/dev/null 2>&1; then
        message "certbot not found; installing via apt..."
        dry_run_gate "apt-get install -y certbot" || return 0  # dry-run prints and returns
        local apt_out apt_rc
        apt_out=$(apt-get install -y certbot 2>&1)
        apt_rc=$?
        if [[ $apt_rc -ne 0 ]]; then
            message "ERROR: Failed to install certbot (exit ${apt_rc})."
            message "apt output: ${apt_out}"
            SSL_STATUS="FAILED: could not install certbot"
            return 1
        fi
        message "certbot installed."
    else
        message "certbot: $(command -v certbot) [OK]"
    fi

    # ------------------------------------------------------------------
    # Stop apache2 so certbot can bind port 80 for standalone challenge
    # ------------------------------------------------------------------
    _stop_apache2

    # ------------------------------------------------------------------
    # Run certbot
    # --KEY-TYPE rsa --rsa-key-size 2048 are MANDATORY.
    # Recent certbot defaults to ECDSA, which causes Asterisk core dumps
    # every ~60 s when MS Teams pings the SBC.  MS Teams requires RSA.
    # ------------------------------------------------------------------
    local cb_cmd cb_out cb_rc
    if [[ "$cert_source" == "certbot-renew" ]]; then
        message "Renewing RSA cert with certbot for ${FQDN} (rsa 2048-bit)..."
        cb_cmd="certbot renew --cert-name ${FQDN} --non-interactive --key-type rsa --rsa-key-size 2048"
    else
        message "Obtaining new RSA cert with certbot for ${FQDN} (email: ${SSL_EMAIL}, rsa 2048-bit)..."
        cb_cmd="certbot certonly --standalone --non-interactive --agree-tos \
--key-type rsa --rsa-key-size 2048 --email ${SSL_EMAIL} -d ${FQDN}"
    fi

    if [[ "$dryrun" == true ]]; then
        message "[DRY-RUN] Would run: ${cb_cmd}"
        SSL_STATUS="DRY-RUN: certbot would run for ${FQDN} (RSA 2048-bit)"
        _restart_apache2
        return 0
    fi

    cb_out=$(eval "$cb_cmd" 2>&1)
    cb_rc=$?
    echo "$cb_out"
    message "certbot output: ${cb_out}"

    _restart_apache2

    if [[ $cb_rc -ne 0 ]]; then
        message "ERROR: certbot failed (exit ${cb_rc}) for ${FQDN}."
        echo ""
        echo "ERROR: certbot failed. Full output shown above."
        echo "Common causes:"
        echo "  - Let's Encrypt rate limits  https://letsencrypt.org/docs/rate-limits/"
        echo "  - Port 80 blocked or in use"
        echo "  - ${FQDN} does not resolve to this server's public IP"
        echo "Tip: If you already have a valid certificate, re-run with --use-existing-cert"
        SSL_STATUS="FAILED: certbot certificate issuance/renewal failed for ${FQDN}"
        return 1
    fi

    # Copy freshly issued cert into /etc/asterisk/ssl/
    _install_certs_from_dir "${certbot_dir}" \
        || { SSL_STATUS="FAILED: certbot succeeded but could not copy certs to /etc/asterisk/ssl/"; return 1; }

    message "Let's Encrypt SSL installation completed for ${FQDN}."
    SSL_STATUS="Installed: Let's Encrypt RSA certificate for ${FQDN} (certs in /etc/asterisk/ssl/)"
    check_tls_cert "$FQDN"
}

## ── PJSIP TRANSPORT CONFIGURATION (Phase 4) ──────────────────────────────────────

# Collected transport parameters (set by prompt_transport_params or defaults).
TRANSPORT_FQDN=""         # FQDN for external_signaling_hostname
TRANSPORT_PUBLIC_IP=""    # Public IP for external_signaling_address
TRANSPORT_SIP_PORT="5061" # External TLS SIP port
TRANSPORT_CERT_FILE=""    # fullchain.pem path
TRANSPORT_KEY_FILE=""     # privkey.pem path
TRANSPORT_BIND_ADDR="0.0.0.0" # Local bind address

# Interactively collect PJSIP transport parameters with sensible defaults.
# All parameters fall back to auto-detected or flag-supplied values.
# Sets TRANSPORT_* globals.
prompt_transport_params() {
    # Derive defaults
    local default_fqdn="${FQDN:-}"
    local default_ip="${PUBLIC_IPV4:-}"
    local default_cert="/etc/letsencrypt/live/${default_fqdn}/fullchain.pem"
    local default_key="/etc/letsencrypt/live/${default_fqdn}/privkey.pem"

    # If a cert was already installed under /etc/asterisk/ssl use that
    if [[ -f "/etc/asterisk/ssl/cert.crt" ]]; then
        default_cert="/etc/asterisk/ssl/cert.crt"
        default_key="/etc/asterisk/ssl/privkey.crt"
    fi

    echo ""
    echo "── PJSIP Transport Parameters ──────────────────────────────────"
    echo "  Press Enter to accept the [default] shown in brackets."
    echo ""

    # FQDN
    echo -n "  SBC FQDN (external_signaling_hostname) [${default_fqdn}]: "
    local inp; read -r inp
    TRANSPORT_FQDN="${inp:-$default_fqdn}"

    # Public IP
    if [[ -z "$default_ip" ]]; then detect_public_ip; default_ip="$PUBLIC_IPV4"; fi
    echo -n "  Public IPv4 (external_signaling_address) [${default_ip}]: "
    read -r inp
    TRANSPORT_PUBLIC_IP="${inp:-$default_ip}"

    # SIP port
    echo -n "  External TLS SIP port (external_signaling_port) [${TRANSPORT_SIP_PORT}]: "
    read -r inp
    TRANSPORT_SIP_PORT="${inp:-5061}"

    # Bind address
    echo -n "  Local bind address (bind) [${TRANSPORT_BIND_ADDR}]: "
    read -r inp
    TRANSPORT_BIND_ADDR="${inp:-0.0.0.0}"

    # Update cert default if FQDN changed
    if [[ "$TRANSPORT_FQDN" != "$default_fqdn" ]]; then
        default_cert="/etc/letsencrypt/live/${TRANSPORT_FQDN}/fullchain.pem"
        default_key="/etc/letsencrypt/live/${TRANSPORT_FQDN}/privkey.pem"
    fi

    # cert_file
    echo -n "  cert_file (fullchain.pem path) [${default_cert}]: "
    read -r inp
    TRANSPORT_CERT_FILE="${inp:-$default_cert}"

    # priv_key_file
    echo -n "  priv_key_file [${default_key}]: "
    read -r inp
    TRANSPORT_KEY_FILE="${inp:-$default_key}"

    message "Transport params: FQDN=${TRANSPORT_FQDN} IP=${TRANSPORT_PUBLIC_IP} port=${TRANSPORT_SIP_PORT}"
    message "  cert=${TRANSPORT_CERT_FILE}  key=${TRANSPORT_KEY_FILE}"
}

# Set TRANSPORT_* globals to defaults (non-interactive — used by --generate-config
# when no interactive prompt is desired, or as a pre-flight for dry-run).
set_transport_defaults() {
    TRANSPORT_FQDN="${FQDN:-}"
    if [[ -z "$PUBLIC_IPV4" ]]; then detect_public_ip; fi
    TRANSPORT_PUBLIC_IP="${PUBLIC_IPV4}"
    TRANSPORT_SIP_PORT="${TRANSPORT_SIP_PORT:-5061}"
    TRANSPORT_BIND_ADDR="${TRANSPORT_BIND_ADDR:-0.0.0.0}"
    local ld="/etc/letsencrypt/live/${TRANSPORT_FQDN}"
    if [[ -f "${ld}/fullchain.pem" ]]; then
        TRANSPORT_CERT_FILE="${ld}/fullchain.pem"
        TRANSPORT_KEY_FILE="${ld}/privkey.pem"
    elif [[ -f "/etc/asterisk/ssl/cert.crt" ]]; then
        TRANSPORT_CERT_FILE="/etc/asterisk/ssl/cert.crt"
        TRANSPORT_KEY_FILE="/etc/asterisk/ssl/privkey.crt"
    else
        TRANSPORT_CERT_FILE="${ld}/fullchain.pem"
        TRANSPORT_KEY_FILE="${ld}/privkey.pem"
    fi
}

# Generate the [transport-ms-teams-tls] stanza and print it to stdout.
# Reads from TRANSPORT_* globals (set by prompt_transport_params or set_transport_defaults).
generate_transport_stanza() {
    cat <<STANZA
; ── MS Teams Direct Routing — PJSIP TLS Transport ─────────────────────────────
; Generated by ${SCRIPT_NAME} v${WIZARD_VERSION} on $(date -u '+%Y-%m-%d %H:%M UTC')
; DO NOT USE ms_signaling_address — that option requires a custom Asterisk patch.
; external_signaling_hostname is the native option (Asterisk PR #1960).
; ───────────────────────────────────────────────────────────────────────────────
[transport-ms-teams-tls]
type=transport
protocol=tls
bind=${TRANSPORT_BIND_ADDR}:${TRANSPORT_SIP_PORT}
external_signaling_address=${TRANSPORT_PUBLIC_IP}
external_signaling_port=${TRANSPORT_SIP_PORT}
external_signaling_hostname=${TRANSPORT_FQDN}
cert_file=${TRANSPORT_CERT_FILE}
priv_key_file=${TRANSPORT_KEY_FILE}
method=tlsv1_2
; verify_client=no — MS Teams presents no client cert; reject if set to yes
verify_client=no
STANZA
}

# Create a timestamped backup of a config file before modifying it.
# Never overwrites an existing backup.
# Dry-run-aware: prints the command but does not run it in dry-run mode.
backup_config_file() {
    local src="$1"
    if [[ ! -f "$src" ]]; then
        message "backup_config_file: '${src}' does not exist — nothing to back up."
        return 0
    fi
    local ts; ts=$(date +%Y%m%d_%H%M%S)
    local dest="${src}.WIZARD_BACKUP.${ts}"
    if [[ -f "$dest" ]]; then
        message "WARNING: backup already exists: ${dest} — skipping backup."
        return 0
    fi
    if dry_run_gate "cp -p '${src}' '${dest}'"; then
        cp -p "$src" "$dest"
        message "Backed up: ${src} → ${dest}"
    fi
}

# Inject (or overwrite) the [transport-ms-teams-tls] stanza into the target file.
# Idempotent: if the stanza already exists, prompt to overwrite or skip.
# Backs up the file before any modification.
# Dry-run-aware.
inject_transport_config() {
    local target="$1"
    local stanza="$2"   # pre-generated stanza text

    if [[ -z "$target" ]]; then
        message "ERROR: inject_transport_config: target path not set."
        return 1
    fi

    # Create target file if it doesn't exist yet (standalone pjsip.conf path)
    if [[ ! -f "$target" ]]; then
        message "Target file not found — will create: ${target}"
        if dry_run_gate "touch '${target}'"; then
            touch "$target" || { message "ERROR: cannot create ${target}"; return 1; }
        fi
    fi

    # Check for existing stanza
    if grep -q '^\[transport-ms-teams-tls\]' "$target" 2>/dev/null; then
        message "WARNING: [transport-ms-teams-tls] already exists in ${target}."
        echo ""
        echo "  A [transport-ms-teams-tls] stanza already exists in:"
        echo "    ${target}"
        echo ""
        echo -n "  Overwrite it? (y/N) [N]: "
        local ans; read -r ans; ans="${ans:-N}"
        message "User overwrite choice: '${ans}'"
        case "${ans^^}" in
            Y) message "User chose to overwrite existing stanza." ;;
            *) message "Skipped — existing stanza preserved."; return 0 ;;
        esac
        # Remove the old stanza block before re-injecting
        if dry_run_gate "Remove old [transport-ms-teams-tls] block from ${target}"; then
            # Delete from [transport-ms-teams-tls] through the next blank line
            # that precedes another [section] or EOF.
            local tmpfile; tmpfile=$(mktemp)
            awk '
                /^\[transport-ms-teams-tls\]/ { skip=1; next }
                skip && /^\[/ { skip=0 }
                skip { next }
                { print }
            ' "$target" > "$tmpfile" && mv "$tmpfile" "$target"
            message "Removed old stanza from ${target}."
        fi
    fi

    backup_config_file "$target"

    # Append the stanza
    if dry_run_gate "Append [transport-ms-teams-tls] stanza to ${target}"; then
        {
            echo ""
            echo "$stanza"
        } >> "$target"
        message "[transport-ms-teams-tls] stanza written to ${target}."
    fi
}

# Post-injection: reload PJSIP or print FreePBX instructions.
# Dry-run-aware.
reload_pjsip_transport() {
    if [[ "$FREEPBX_MODE" == true ]]; then
        message ""
        message "FreePBX: config written — run the following to apply:"
        echo ""
        echo "  fwconsole reload"
        echo ""
        message "  (The wizard does not run fwconsole automatically to avoid disrupting active calls.)"
    else
        message "Reloading PJSIP transport via Asterisk CLI..."
        if dry_run_gate "asterisk -rx 'pjsip reload'"; then
            local out; out=$(asterisk -rx 'pjsip reload' 2>&1 || true)
            message "pjsip reload output: ${out}"
            echo "  PJSIP reloaded.  Verify with:  asterisk -rx 'pjsip show transports'"
        fi
    fi
}

# Full Phase 4 flow: prompt → generate → inject → reload.
# Called from interactive and greenfield wizard modes.
run_transport_wizard() {
    message ""
    message "── PJSIP Transport Wizard (Phase 4) ──"
    if [[ "$dryrun" == true ]]; then
        set_transport_defaults
    else
        prompt_transport_params
    fi
    local stanza; stanza=$(generate_transport_stanza)
    message ""
    message "Generated stanza:"
    echo "$stanza" | while IFS= read -r line; do message "  ${line}"; done

    if [[ "$dryrun" == true ]]; then
        message "[DRY-RUN] Would write transport stanza to ${PJSIP_TRANSPORT_CONF}"
        return 0
    fi

    echo ""
    echo -n "  Write this stanza to ${PJSIP_TRANSPORT_CONF}? (Y/n) [Y]: "
    local ans; read -r ans; ans="${ans:-Y}"
    case "${ans^^}" in
        N) message "User skipped transport config write."; return 0 ;;
        *) ;;
    esac
    inject_transport_config "$PJSIP_TRANSPORT_CONF" "$stanza"
    reload_pjsip_transport
}

## ── MS TEAMS ENDPOINT TEMPLATES (Phase 5) ────────────────────────────────────────

# Published Microsoft Direct Routing SIP signaling IP ranges.
# Source: https://learn.microsoft.com/en-us/microsoftteams/direct-routing-plan
MSTEAMS_IP_RANGES=(
    "52.112.0.0/14"
    "52.120.0.0/14"
    "52.114.148.0/22"
    "52.114.132.0/22"
    "52.114.156.0/22"
)

# Published MS Teams SIP proxy FQDNs (used as AOR contacts).
MSTEAMS_SIP_PROXIES=(
    "sip.pstnhub.microsoft.com"
    "sip2.pstnhub.microsoft.com"
    "sip3.pstnhub.microsoft.com"
)

# Collected endpoint parameters (set by prompt_endpoint_params).
ENDPOINT_NAME="MSTeams"       # PJSIP object name shared by endpoint/aor/identify
ENDPOINT_CONTEXT=""           # Dialplan context for inbound calls
ENDPOINT_CODECS="ulaw,alaw,g722"  # allow= codec list

# Interactively collect endpoint parameters.
# Sets ENDPOINT_NAME, ENDPOINT_CONTEXT, ENDPOINT_CODECS.
prompt_endpoint_params() {
    local default_context
    if [[ "$FREEPBX_MODE" == true ]]; then
        default_context="from-trunk"
    else
        default_context="from-external"
    fi

    echo ""
    echo "── MS Teams Endpoint Parameters ─────────────────────────────────"
    echo "  Press Enter to accept the [default] shown in brackets."
    echo ""

    echo -n "  PJSIP object name (endpoint/aor/identify) [${ENDPOINT_NAME}]: "
    local inp; read -r inp
    ENDPOINT_NAME="${inp:-MSTeams}"

    echo -n "  Dialplan context for inbound calls [${default_context}]: "
    read -r inp
    ENDPOINT_CONTEXT="${inp:-$default_context}"

    echo -n "  Allowed codecs [${ENDPOINT_CODECS}]: "
    read -r inp
    ENDPOINT_CODECS="${inp:-ulaw,alaw,g722}"

    message "Endpoint params: name=${ENDPOINT_NAME} context=${ENDPOINT_CONTEXT} codecs=${ENDPOINT_CODECS}"
}

# Set ENDPOINT_* globals to defaults (non-interactive path).
set_endpoint_defaults() {
    if [[ "$FREEPBX_MODE" == true ]]; then
        ENDPOINT_CONTEXT="${ENDPOINT_CONTEXT:-from-trunk}"
    else
        ENDPOINT_CONTEXT="${ENDPOINT_CONTEXT:-from-external}"
    fi
    ENDPOINT_NAME="${ENDPOINT_NAME:-MSTeams}"
    ENDPOINT_CODECS="${ENDPOINT_CODECS:-ulaw,alaw,g722}"
}

# Generate the full endpoint+aor+identify stanza and print to stdout.
# Reads ENDPOINT_* and TRANSPORT_* globals.
generate_endpoint_stanza() {
    local name="${ENDPOINT_NAME:-MSTeams}"
    local context="${ENDPOINT_CONTEXT:-from-external}"
    local codecs="${ENDPOINT_CODECS:-ulaw,alaw,g722}"

    # Build AOR contact lines (one per MS proxy FQDN)
    local contact_lines=""
    local proxy
    for proxy in "${MSTEAMS_SIP_PROXIES[@]}"; do
        contact_lines+="contact=sip:${proxy}:5061;transport=tls"$'\n'
    done

    # Build identify match lines (one per IP range)
    local match_lines=""
    local cidr
    for cidr in "${MSTEAMS_IP_RANGES[@]}"; do
        match_lines+="match=${cidr}"$'\n'
    done

    cat <<STANZA
; ── MS Teams Direct Routing — PJSIP Endpoint/AOR/Identify ─────────────────────
; Generated by ${SCRIPT_NAME} v${WIZARD_VERSION} on $(date -u '+%Y-%m-%d %H:%M UTC')
;
; Inbound: MS Teams identifies itself by source IP → [identify-${name}] matches it
;          and maps to endpoint [${name}].
; Outbound: Asterisk sends to contacts in [${name}] AOR (MS SIP proxies).
; ───────────────────────────────────────────────────────────────────────────────

[${name}]
type=endpoint
transport=transport-ms-teams-tls
context=${context}
disallow=all
allow=${codecs}
; MS Teams Direct Routing requirements:
direct_media=no
ice_support=yes
rtp_symmetric=yes
rewrite_contact=yes
send_rpid=yes
timers=no
aors=${name}

[${name}]
type=aor
; MS Teams SIP proxy contacts — Asterisk rotates through these for outbound
${contact_lines}qualify_frequency=60
qualify_timeout=5

[identify-${name}]
type=identify
endpoint=${name}
; Microsoft published Direct Routing signaling IP ranges
; Source: https://learn.microsoft.com/en-us/microsoftteams/direct-routing-plan
${match_lines}
STANZA
}

# Inject (or overwrite) the endpoint stanza into the target file.
# Idempotent — detects existing [<name>] type=endpoint block; prompts to overwrite.
# Dry-run-aware.
inject_endpoint_config() {
    local target="$1"
    local stanza="$2"
    local name="${ENDPOINT_NAME:-MSTeams}"

    if [[ -z "$target" ]]; then
        message "ERROR: inject_endpoint_config: target path not set."
        return 1
    fi

    if [[ ! -f "$target" ]]; then
        message "Endpoint target file not found — will create: ${target}"
        if dry_run_gate "touch '${target}'"; then
            touch "$target" || { message "ERROR: cannot create ${target}"; return 1; }
        fi
    fi

    # Check for existing endpoint block (section header + type=endpoint)
    if grep -A2 "^\[${name}\]" "$target" 2>/dev/null | grep -q 'type=endpoint'; then
        message "WARNING: endpoint [${name}] already exists in ${target}."
        echo ""
        echo "  An endpoint [${name}] already exists in:"
        echo "    ${target}"
        echo ""
        echo -n "  Overwrite it? (y/N) [N]: "
        local ans; read -r ans; ans="${ans:-N}"
        message "User endpoint-overwrite choice: '${ans}'"
        case "${ans^^}" in
            Y) message "User chose to overwrite existing endpoint." ;;
            *) message "Skipped — existing endpoint config preserved."; return 0 ;;
        esac
        # Remove old endpoint, aor, and identify blocks for this name
        if dry_run_gate "Remove old [${name}] endpoint/aor/identify blocks from ${target}"; then
            local tmpfile; tmpfile=$(mktemp)
            awk -v name="$name" '
                /^\[(endpoint-)?'"${name}"'\]/ && found_name { skip=1 }
                /^\[identify-'"${name}"'\]/   { skip=1; next }
                /^\[/ && !/^\[(endpoint-)?'"${name}"'\]/ && !/^\[identify-'"${name}"'\]/ {
                    skip=0
                }
                skip { next }
                { print }
            ' "$target" > "$tmpfile" && mv "$tmpfile" "$target"
            message "Removed old endpoint blocks from ${target}."
        fi
    fi

    backup_config_file "$target"

    if dry_run_gate "Append endpoint stanza for [${name}] to ${target}"; then
        {
            echo ""
            echo "$stanza"
        } >> "$target"
        message "Endpoint stanza [${name}] written to ${target}."
    fi
}

# In standalone mode: ensure pjsip.conf contains an #include for the endpoint file.
# Appends the directive if absent. Dry-run-aware.
ensure_pjsip_include() {
    # Only relevant in standalone mode; FreePBX auto-scans endpoint_custom_post.conf
    if [[ "$FREEPBX_MODE" == true ]]; then
        return 0
    fi

    local pjsip_main="${ASTERISK_CONF_DIR}/pjsip.conf"
    local endpoint_file
    endpoint_file=$(basename "$PJSIP_ENDPOINT_CONF")   # pjsip_msteams_endpoint.conf
    local directive="#include ${endpoint_file}"

    if grep -qF "$directive" "$pjsip_main" 2>/dev/null; then
        message "  ${pjsip_main} already includes ${endpoint_file} [OK]"
        return 0
    fi

    message "  Adding '${directive}' to ${pjsip_main}..."
    backup_config_file "$pjsip_main"

    if dry_run_gate "Append '${directive}' to ${pjsip_main}"; then
        echo "" >> "$pjsip_main"
        echo "$directive" >> "$pjsip_main"
        message "  Added: ${directive}"
    fi
}

# Full Phase 5 flow: prompt → generate → inject → ensure include.
# Called from interactive and greenfield wizard modes (after run_transport_wizard).
run_endpoint_wizard() {
    message ""
    message "── MS Teams Endpoint Wizard (Phase 5) ──"

    # Inherit FQDN/IP from already-collected transport params or set defaults
    if [[ -z "$TRANSPORT_FQDN" ]]; then set_transport_defaults; fi
    set_endpoint_defaults

    if [[ "$dryrun" == true ]]; then
        : # use defaults set above; skip interactive prompt
    else
        prompt_endpoint_params
    fi

    local stanza; stanza=$(generate_endpoint_stanza)

    message ""
    message "Generated endpoint stanza:"
    echo "$stanza" | while IFS= read -r line; do message "  ${line}"; done

    if [[ "$dryrun" == true ]]; then
        message "[DRY-RUN] Would write endpoint stanza to ${PJSIP_ENDPOINT_CONF}"
        return 0
    fi

    echo ""
    echo -n "  Write this stanza to ${PJSIP_ENDPOINT_CONF}? (Y/n) [Y]: "
    local ans; read -r ans; ans="${ans:-Y}"
    case "${ans^^}" in
        N) message "User skipped endpoint config write."; return 0 ;;
        *) ;;
    esac

    inject_endpoint_config "$PJSIP_ENDPOINT_CONF" "$stanza"
    ensure_pjsip_include

    message ""
    message "MS Teams endpoint configured."
    message "  Verify with:  asterisk -rx 'pjsip show endpoint ${ENDPOINT_NAME}'"
    message "  Check identify: asterisk -rx 'pjsip show identify'"
}

## ── FIREWALL & CONNECTIVITY VALIDATION (Phase 6) ────────────────────────────────

# Print MS Teams connectivity reference information (proxy FQDNs, sngrep tips).
# Always informational — never errors.
print_msteams_connectivity_info() {
    message ""
    message "── MS Teams Direct Routing — Connectivity Reference ──"
    message "  MS Teams SIP proxy FQDNs (port 5061 TLS):"
    local proxy
    for proxy in "${MSTEAMS_SIP_PROXIES[@]}"; do
        message "    ${proxy}"
    done
    message ""
    message "  MS Teams OPTIONS-pings your SBC every ~60 s."
    message "  Inbound INVITEs arrive from the IP ranges in [identify-${ENDPOINT_NAME:-MSTeams}]."
    message ""
    message "  SIP capture commands:"
    message "    sngrep port 5061"
    message "    sngrep -d eth0 port 5061   (specify interface if needed)"
    message "    tcpdump -i any -n port 5061 -w /tmp/sip.pcap"
}

# Check whether $port is bound on TCP (TLS) locally.
# Returns 0 if bound, 1 if not.  Never requires root.
_check_port_bound() {
    local port="${1:-5061}"
    if ! command -v ss >/dev/null 2>&1; then
        message "  WARNING: 'ss' not found (install iproute2: apt-get install -y iproute2)."
        return 1
    fi
    local ss_out
    ss_out=$(ss -tlnp 2>/dev/null | grep -E ":${port}[[:space:]]" || true)
    if [[ -z "$ss_out" ]]; then
        return 1
    fi
    # Try to extract process name (available without root on many systems)
    local proc
    proc=$(echo "$ss_out" | grep -oP 'users:\(\("?\K[^",)]+' | head -1 || true)
    if [[ -n "$proc" ]]; then
        message "    Process holding port ${port}: ${proc}"
    fi
    return 0
}

# Check UFW rules non-interactively; returns 0 if ufw inactive or port allowed.
# Returns 1 with warning if ufw is active and port is not listed.
_check_ufw_port() {
    local port="${1:-5061}"
    if ! command -v ufw >/dev/null 2>&1; then
        return 0   # ufw not present — not our problem
    fi
    local ufw_status
    ufw_status=$(ufw status 2>/dev/null || true)
    if ! echo "$ufw_status" | grep -q "Status: active"; then
        message "  ufw: inactive — not blocking port ${port} [OK]"
        return 0
    fi
    if echo "$ufw_status" | grep -qE "^${port}[/[:space:]]"; then
        message "  ufw: port ${port} is allowed [OK]"
        return 0
    fi
    message "  WARNING: ufw is active and has no rule for port ${port}."
    message "    MS Teams cannot reach this SBC until the port is opened:"
    message "      ufw allow ${port}/tcp   # SIP TLS"
    return 1
}

# Check iptables INPUT chain non-interactively (best-effort; ignores permission errors).
_check_iptables_port() {
    local port="${1:-5061}"
    if ! command -v iptables >/dev/null 2>&1; then
        return 0
    fi
    local ipt_out
    ipt_out=$(iptables -L INPUT -n 2>/dev/null || true)
    if [[ -z "$ipt_out" ]]; then
        return 0   # no output (likely permission denied) — skip silently
    fi
    # If no ACCEPT rule for the port and a DROP/REJECT is present, warn
    if echo "$ipt_out" | grep -qE "ACCEPT.*dpt:${port}"; then
        message "  iptables: ACCEPT rule for port ${port} found [OK]"
        return 0
    fi
    if echo "$ipt_out" | grep -qE "(DROP|REJECT).*dpt:${port}"; then
        message "  WARNING: iptables has a DROP/REJECT for port ${port}."
        message "    Add rule:  iptables -I INPUT -p tcp --dport ${port} -j ACCEPT"
        return 1
    fi
    # Default policy check
    local default_policy
    default_policy=$(echo "$ipt_out" | grep '^Chain INPUT' | grep -oP 'policy \K\w+' || true)
    if [[ "$default_policy" == "DROP" || "$default_policy" == "REJECT" ]]; then
        message "  WARNING: iptables INPUT default policy is ${default_policy}."
        message "    Ensure port ${port}/tcp has an explicit ACCEPT rule."
        return 1
    fi
    return 0
}

# Main Phase 6 entry point.
# Checks local port binding, ufw, iptables, and prints connectivity reference.
# Informational only — never aborts the wizard.
# Returns 0 if all checks pass, 1 if any warning was raised.
check_firewall_ports() {
    local port="${TRANSPORT_SIP_PORT:-5061}"
    local overall_ok=true

    message ""
    message "── Port & Firewall Check (port ${port}/TCP) ──"

    # 1. Is the port bound?
    if _check_port_bound "$port"; then
        message "  TCP port ${port}: BOUND [OK]"
    else
        message "  WARNING: TCP port ${port} is NOT currently bound."
        message "    Possible causes:"
        message "      • Asterisk is not running"
        message "      • [transport-ms-teams-tls] stanza not yet loaded"
        message "      • bind=${TRANSPORT_BIND_ADDR:-0.0.0.0}:${port} typo in config"
        message "    Check:  asterisk -rx 'pjsip show transports'"
        overall_ok=false
    fi

    # 2. UFW
    _check_ufw_port "$port" || overall_ok=false

    # 3. iptables (best-effort; may be empty without root)
    _check_iptables_port "$port" || overall_ok=false

    # 4. Connectivity reference
    print_msteams_connectivity_info

    [[ "$overall_ok" == true ]]
}

## ── GREENFIELD VANILLA ASTERISK INSTALL (Phase 7) ───────────────────────────────

# select_asterisk_tarball(major_version)
# Sets TARBALL and TARBALL_URL for the requested major branch.
# Greenfield always uses the -current tarball (fresh install, no running binary to match).
select_asterisk_tarball() {
    local major="${1:-${ASTVERSION:-22}}"
    TARBALL="asterisk-${major}-current.tar.gz"
    TARBALL_URL="https://downloads.asterisk.org/pub/telephony/asterisk/${TARBALL}"
}

# download_asterisk_source()
# Downloads TARBALL to SRCDIR; skips if a cached copy already exists.
# Dry-run: prints the URL and target path, returns without downloading.
download_asterisk_source() {
    local dest="${SRCDIR}/${TARBALL}"
    if [[ "$dryrun" == true ]]; then
        message "[DRY-RUN] Would download: ${TARBALL_URL}"
        message "[DRY-RUN]   → ${dest}"
        return 0
    fi
    if [[ -f "$dest" ]]; then
        message "Found cached tarball: ${dest} (skipping download)"
        return 0
    fi
    message "Downloading Asterisk source tarball..."
    message "  URL: ${TARBALL_URL}"
    _ensure_wget
    wget -P "$SRCDIR" "$TARBALL_URL" \
        || { message "ERROR: Failed to download ${TARBALL_URL}"; terminate 1; }
    message "Downloaded: ${dest}"
}

# extract_asterisk_source()
# Removes old source trees for the same major version, extracts the tarball,
# and sets ASTERISK_SRC_DIR to the extracted directory.
# Dry-run: prints intent and sets a placeholder path.
extract_asterisk_source() {
    local major="${ASTVERSION:-22}"

    # Remove pre-existing source trees for idempotency
    local prev_count
    prev_count=$(find "$SRCDIR" -maxdepth 1 -mindepth 1 -type d \
        -name "asterisk-${major}.*" 2>/dev/null | wc -l)
    if (( prev_count > 0 )); then
        message "Removing existing Asterisk ${major}.x source tree(s) in ${SRCDIR}/ for clean rebuild..."
        if dry_run_gate "rm -rf ${SRCDIR}/asterisk-${major}.*"; then
            find "$SRCDIR" -maxdepth 1 -mindepth 1 -type d \
                -name "asterisk-${major}.*" -exec rm -rf {} + 2>/dev/null || true
        fi
    fi

    if [[ "$dryrun" == true ]]; then
        message "[DRY-RUN] Would extract: ${SRCDIR}/${TARBALL}"
        ASTERISK_SRC_DIR="${SRCDIR}/asterisk-${major}.x"
        return 0
    fi

    message "Extracting ${TARBALL}..."
    tar -xzf "${SRCDIR}/${TARBALL}" -C "$SRCDIR" \
        || { message "ERROR: Failed to extract ${SRCDIR}/${TARBALL}"; terminate 1; }

    ASTERISK_SRC_DIR=$(find "$SRCDIR" -maxdepth 1 -mindepth 1 -type d \
        -name "asterisk-${major}.*" | sort -V | tail -1)

    if [[ -z "$ASTERISK_SRC_DIR" || ! -d "$ASTERISK_SRC_DIR" ]]; then
        message "ERROR: Could not locate extracted source directory: ${SRCDIR}/asterisk-${major}.*"
        terminate 1
    fi
    message "Extracted source: ${ASTERISK_SRC_DIR}"
}

# install_build_prereqs()
# Runs Asterisk's bundled contrib/scripts/install_prereq from inside the source tree.
# Dry-run-aware.
install_build_prereqs() {
    message ""
    message "Installing Asterisk build dependencies via contrib/scripts/install_prereq..."
    if dry_run_gate "cd '${ASTERISK_SRC_DIR}' && contrib/scripts/install_prereq install"; then
        (
            cd "$ASTERISK_SRC_DIR" \
                || { message "ERROR: Cannot enter source directory: ${ASTERISK_SRC_DIR}"; terminate 1; }
            contrib/scripts/install_prereq install \
                || { message "ERROR: install_prereq failed"; terminate 1; }
        )
        message "Build dependencies installed."
    fi
}

# prompt_install_prefix()
# Prompts for the installation prefix interactively.
# In dry-run mode: skips prompt, prints the default that would be used.
# Sets ASTERISK_PREFIX, ASTERISK_SYSCONFDIR, ASTERISK_LOCALSTATEDIR.
prompt_install_prefix() {
    ASTERISK_PREFIX="${ASTERISK_PREFIX:-/usr}"
    ASTERISK_SYSCONFDIR="${ASTERISK_SYSCONFDIR:-/etc}"
    ASTERISK_LOCALSTATEDIR="${ASTERISK_LOCALSTATEDIR:-/var}"

    if [[ "$dryrun" == true ]]; then
        message "[DRY-RUN] Would use installation prefix: ${ASTERISK_PREFIX}"
        message "[DRY-RUN]   --sysconfdir=${ASTERISK_SYSCONFDIR} --localstatedir=${ASTERISK_LOCALSTATEDIR}"
        return 0
    fi

    local prefix_input
    echo -n "Enter installation prefix [${ASTERISK_PREFIX}]: "
    read -r prefix_input
    if [[ -n "$prefix_input" ]]; then
        ASTERISK_PREFIX="$prefix_input"
        ASTERISK_SYSCONFDIR="${ASTERISK_PREFIX}/etc"
        ASTERISK_LOCALSTATEDIR="${ASTERISK_PREFIX}/var"
    fi
    message "Installation prefix:   ${ASTERISK_PREFIX}"
    message "Config directory:      ${ASTERISK_SYSCONFDIR}/asterisk/"
    message "State directory:       ${ASTERISK_LOCALSTATEDIR}/lib/asterisk/"
}

# configure_asterisk_build()
# Runs ./configure with the resolved prefix options from inside the source tree.
# Dry-run-aware.
configure_asterisk_build() {
    message ""
    message "Configuring Asterisk build..."
    message "  ./configure --prefix=${ASTERISK_PREFIX} --sysconfdir=${ASTERISK_SYSCONFDIR} --localstatedir=${ASTERISK_LOCALSTATEDIR}"
    if dry_run_gate \
        "cd '${ASTERISK_SRC_DIR}' && ./configure --prefix=${ASTERISK_PREFIX} --sysconfdir=${ASTERISK_SYSCONFDIR} --localstatedir=${ASTERISK_LOCALSTATEDIR}"; then
        (
            cd "$ASTERISK_SRC_DIR" \
                || { message "ERROR: Cannot enter source directory: ${ASTERISK_SRC_DIR}"; terminate 1; }
            ./configure \
                --prefix="$ASTERISK_PREFIX" \
                --sysconfdir="$ASTERISK_SYSCONFDIR" \
                --localstatedir="$ASTERISK_LOCALSTATEDIR" \
                || { message "ERROR: ./configure failed; check ${ASTERISK_SRC_DIR}/config.log"; terminate 1; }
        )
        message "Configure complete."
    fi
}

# compile_and_install_asterisk()
# Runs make then make install from inside the source tree.
# Dry-run-aware.
compile_and_install_asterisk() {
    message ""
    message "Compiling Asterisk (this may take 10–20 minutes on a typical VPS)..."
    if dry_run_gate "cd '${ASTERISK_SRC_DIR}' && make"; then
        (
            cd "$ASTERISK_SRC_DIR" \
                || { message "ERROR: Cannot enter source directory: ${ASTERISK_SRC_DIR}"; terminate 1; }
            make || { message "ERROR: make failed"; terminate 1; }
        )
        message "Compilation complete."
    fi

    message ""
    message "Installing Asterisk to ${ASTERISK_PREFIX}..."
    if dry_run_gate "cd '${ASTERISK_SRC_DIR}' && make install"; then
        (
            cd "$ASTERISK_SRC_DIR" \
                || { message "ERROR: Cannot enter source directory: ${ASTERISK_SRC_DIR}"; terminate 1; }
            make install || { message "ERROR: make install failed"; terminate 1; }
        )
        message "Asterisk installed."
        message "  Binary:  ${ASTERISK_PREFIX}/sbin/asterisk"
        message "  Config:  ${ASTERISK_SYSCONFDIR}/asterisk/"
        message "  Modules: ${ASTERISK_PREFIX}/lib/asterisk/modules/"
    fi
}

# verify_installed_version()
# After 'make install', confirm the installed binary meets the native support floor. (P7-04)
# Aborts if below minimum; warns and continues for ambiguous states.
verify_installed_version() {
    if [[ "$dryrun" == true ]]; then
        message "[DRY-RUN] Would verify installed Asterisk meets native support threshold."
        return 0
    fi

    message ""
    message "Verifying installed Asterisk meets native support threshold..."
    local check_out status full_ver
    check_out=$(check_native_support 2>/dev/null)
    read -r status full_ver <<< "$check_out"

    case "$status" in
        SUPPORTED)
            message "  Installed Asterisk ${full_ver}: native external_signaling_hostname confirmed [OK]"
            AST_FULL_VERSION="$full_ver"
            ASTVERSION="${full_ver%%.*}"
            ;;
        UPGRADE_NEEDED)
            local major="${full_ver%%.*}"
            local min_ver="${MIN_NATIVE_VERSION[$major]:-unknown}"
            message "ERROR: Installed Asterisk ${full_ver} is below minimum required version (${min_ver})."
            message "  This is unexpected with a -current tarball from downloads.asterisk.org."
            message "  Check: https://downloads.asterisk.org/pub/telephony/asterisk/"
            terminate 1
            ;;
        NOT_INSTALLED)
            message "ERROR: Asterisk binary not found after make install."
            message "  Check PATH or use: ${ASTERISK_PREFIX}/sbin/asterisk -V"
            terminate 1
            ;;
        *)
            message "WARNING: Could not confirm native support (status=${status}, ver=${full_ver})."
            message "  Proceeding — verify manually: asterisk -rx 'pjsip show transports'"
            ;;
    esac
}

# create_asterisk_systemd_service()
# Writes /etc/systemd/system/asterisk.service and enables it.
# Dry-run: prints the unit file content that would be written.
create_asterisk_systemd_service() {
    local unit_file="/etc/systemd/system/asterisk.service"
    local prefix="${ASTERISK_PREFIX:-/usr}"
    local svc_content
    # Note: use printf to avoid issues with single-quotes inside heredoc in dry-run log
    svc_content="[Unit]
Description=Asterisk PBX
After=network.target

[Service]
Type=simple
ExecStart=${prefix}/sbin/asterisk -f -vvv
ExecStop=${prefix}/sbin/asterisk -rx 'core stop now'
Restart=on-failure

[Install]
WantedBy=multi-user.target"

    if [[ "$dryrun" == true ]]; then
        message "[DRY-RUN] Would write systemd unit: ${unit_file}"
        message "[DRY-RUN] Unit file content:"
        while IFS= read -r line; do
            message "  ${line}"
        done <<< "$svc_content"
        message "[DRY-RUN] Would run: systemctl daemon-reload && systemctl enable asterisk"
        return 0
    fi

    message "Writing systemd unit: ${unit_file}"
    echo "$svc_content" > "$unit_file"
    ASTERISK_SERVICE_CREATED=true

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload || true
        systemctl enable asterisk || true
        ASTERISK_SERVICE_ENABLED=true
        message "  asterisk.service created and enabled [OK]"
        message "  Start with: systemctl start asterisk"
    else
        message "  WARNING: systemctl not found; enable asterisk.service manually."
    fi
}

# prompt_systemd_service()
# Interactive prompt for systemd service creation.
# In dry-run: shows intent and calls create_asterisk_systemd_service (which also dry-runs).
prompt_systemd_service() {
    message ""
    if [[ "$dryrun" == true ]]; then
        message "[DRY-RUN] Would prompt: Create and enable systemd service for Asterisk? (y/n) [y]"
        create_asterisk_systemd_service
        return 0
    fi

    local reply
    echo -n "Create and enable systemd service for Asterisk? (y/n) [y]: "
    read -r reply
    if [[ -z "$reply" || "$reply" =~ ^[Yy] ]]; then
        create_asterisk_systemd_service
    else
        message "Skipping systemd service creation."
        ASTERISK_SERVICE_CREATED=false
    fi
}

# prompt_make_samples()
# Interactive prompt for 'make samples'.
# In dry-run: prints intent; default answer is N so samples are not installed.
prompt_make_samples() {
    message ""
    if [[ "$dryrun" == true ]]; then
        message "[DRY-RUN] Would prompt: Install sample Asterisk configuration files? (y/n) [n]"
        message "[DRY-RUN] Would run: make samples (from ${ASTERISK_SRC_DIR:-<source-dir>})"
        ASTERISK_SAMPLES_INSTALLED=false
        return 0
    fi

    local reply
    echo -n "Install sample Asterisk configuration files? (y/n) [n]: "
    read -r reply
    if [[ "$reply" =~ ^[Yy] ]]; then
        message "Installing sample configuration files..."
        (
            cd "$ASTERISK_SRC_DIR" \
                || { message "ERROR: Cannot enter source directory: ${ASTERISK_SRC_DIR}"; terminate 1; }
            make samples || { message "WARNING: make samples returned an error; continuing."; true; }
        )
        ASTERISK_SAMPLES_INSTALLED=true
        message "Sample configs installed to ${ASTERISK_SYSCONFDIR}/asterisk/."
    else
        message "Skipping sample configuration files."
        ASTERISK_SAMPLES_INSTALLED=false
    fi
}

# print_greenfield_summary()
# Prints a completion summary for the greenfield build.
print_greenfield_summary() {
    message ""
    message "── Greenfield Build Summary ──"
    message "  Asterisk version:   ${AST_FULL_VERSION:-${ASTVERSION:-unknown}}"
    message "  Install prefix:     ${ASTERISK_PREFIX:-/usr}"
    message "  Binary:             ${ASTERISK_PREFIX:-/usr}/sbin/asterisk"
    message "  Config directory:   ${ASTERISK_SYSCONFDIR:-/etc}/asterisk/"
    message "  systemd service:    created=${ASTERISK_SERVICE_CREATED}  enabled=${ASTERISK_SERVICE_ENABLED}"
    message "  Sample configs:     ${ASTERISK_SAMPLES_INSTALLED}"
    message ""
    message "Next steps:"
    message "  1. Start Asterisk:   systemctl start asterisk"
    message "  2. Check status:     systemctl status asterisk"
    message "  3. Verify transport: asterisk -rx 'pjsip show transports'"
    message "  4. Verify endpoint:  asterisk -rx 'pjsip show endpoint ${ENDPOINT_NAME:-MSTeams}'"
    message "  5. Verify identify:  asterisk -rx 'pjsip show identify'"
}

# build_asterisk_from_source()
# Phase 7 orchestrator: select tarball → download → extract → prereqs →
#   configure → compile → install → verify → systemd → samples.
# After this, the GREENFIELD MODE dispatch calls install_ssl + run_transport_wizard
# + run_endpoint_wizard.
build_asterisk_from_source() {
    local major="${ASTVERSION:-22}"
    message ""
    message "── Greenfield Asterisk Build (Phase 7) ──"
    message "  Target branch: Asterisk ${major} (native external_signaling_hostname)"
    message "  Source directory: ${SRCDIR}"
    message "  Build type: vanilla — no source patch required"

    mkdir -p "$SRCDIR" 2>/dev/null || true

    select_asterisk_tarball "$major"
    message ""
    message "  Tarball: ${TARBALL}"
    message "  URL:     ${TARBALL_URL}"

    download_asterisk_source
    extract_asterisk_source
    install_build_prereqs
    prompt_install_prefix
    configure_asterisk_build
    compile_and_install_asterisk
    verify_installed_version
    prompt_systemd_service
    prompt_make_samples
    print_greenfield_summary
}

## ── CHECK MODE HELPERS (Phase 10) ───────────────────────────────────────────────

# check_external_signaling_hostname()
# Searches active PJSIP config files for any existing external_signaling_hostname
# setting and reports its value.  Used exclusively by --check mode (P10-05).
# Returns 0 if found, 1 if not found.
check_external_signaling_hostname() {
    local conf_dir="${ASTERISK_CONF_DIR:-/etc/asterisk}"
    # Candidate files: pjsip.conf and all .conf files (covers FreePBX custom files)
    local -a candidates=()
    local f
    while IFS= read -r f; do
        candidates+=("$f")
    done < <(find "$conf_dir" -maxdepth 1 -name "*.conf" 2>/dev/null | sort)

    message ""
    message "── external_signaling_hostname Check ──"

    if [[ "${#candidates[@]}" -eq 0 ]]; then
        message "  WARNING: No .conf files found under ${conf_dir}."
        return 1
    fi

    local found_file="" found_value=""
    for f in "${candidates[@]}"; do
        local val
        val=$(grep -m1 '^\s*external_signaling_hostname\s*=' "$f" 2>/dev/null \
              | sed 's/.*=\s*//' | tr -d '[:space:]') || true
        if [[ -n "$val" ]]; then
            found_file="$f"
            found_value="$val"
            break
        fi
    done

    if [[ -n "$found_value" ]]; then
        message "  external_signaling_hostname = ${found_value}  [found in $(basename "$found_file")]"
        if [[ -n "${FQDN:-}" && "$found_value" != "$FQDN" ]]; then
            message "  WARNING: value '${found_value}' does not match current FQDN '${FQDN}'."
            message "  Update ${found_file} or re-run the wizard with --fqdn=${found_value}."
            return 1
        fi
        message "  Matches FQDN [OK]"
        return 0
    else
        message "  WARNING: external_signaling_hostname not set in any file under ${conf_dir}."
        message "  Run the wizard to configure it, or add it manually to ${PJSIP_TRANSPORT_CONF:-pjsip.conf}:"
        message "    external_signaling_hostname = ${FQDN:-<your-sbc-fqdn>}"
        return 1
    fi
}

## ── BROWNFIELD UPGRADE (Phase 8) ────────────────────────────────────────────────

# backup_etc_asterisk()
# Copies /etc/asterisk to a timestamped backup directory before any upgrade or
# config change.  Never overwrites an existing backup (the timestamp is unique to
# the second).  Dry-run-aware.
# Sets the global LAST_BACKUP_PATH to the backup destination path (real or would-be).
backup_etc_asterisk() {
    local src="${ASTERISK_CONF_DIR:-/etc/asterisk}"
    local ts; ts=$(date +%Y%m%d_%H%M%S)
    local dest="${src}.WIZARD_BACKUP.${ts}"
    LAST_BACKUP_PATH="$dest"

    if [[ ! -d "$src" ]]; then
        message "WARNING: ${src} does not exist — skipping backup."
        return 0
    fi

    if [[ "$dryrun" == true ]]; then
        message "[DRY-RUN] Would back up: ${src} → ${dest}"
        return 0
    fi

    message "Backing up ${src} → ${dest} ..."
    cp -a "$src" "$dest" \
        || { message "ERROR: Failed to back up ${src}"; terminate 1; }
    message "  Backup complete: ${dest}"
}

# restore_etc_asterisk()
# Lists all WIZARD_BACKUP snapshots of ASTERISK_CONF_DIR and prompts the user
# to select one to restore.  Before overwriting live config, backs up the
# current state so the restore is always reversible.  Dry-run-aware.
restore_etc_asterisk() {
    local conf_dir="${ASTERISK_CONF_DIR:-/etc/asterisk}"
    local parent_dir; parent_dir=$(dirname "$conf_dir")

    # Collect backups: directories named <conf_dir>.WIZARD_BACKUP.<ts>
    local -a backups=()
    local entry
    while IFS= read -r entry; do
        backups+=("$entry")
    done < <(find "$parent_dir" -maxdepth 1 -type d \
                  -name "$(basename "$conf_dir").WIZARD_BACKUP.*" 2>/dev/null \
             | sort -r)

    if [[ "${#backups[@]}" -eq 0 ]]; then
        message "No WIZARD_BACKUP snapshots found under ${parent_dir}."
        message "  Run the wizard at least once to create a backup before using --restore."
        return 1
    fi

    message ""
    message "── Available /etc/asterisk Backups ──"
    local i=1
    for b in "${backups[@]}"; do
        message "  [${i}] $(basename "$b")"
        (( i++ )) || true
    done
    message "  [0] Cancel"
    message ""

    if [[ "$dryrun" == true ]]; then
        message "[DRY-RUN] Would prompt for backup selection and restore chosen snapshot to ${conf_dir}."
        return 0
    fi

    local choice
    echo -n "Select backup to restore (0 to cancel) [0]: "
    read -r choice
    choice="${choice:-0}"

    if [[ "$choice" == "0" ]]; then
        message "Restore cancelled."
        return 0
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#backups[@]} )); then
        message "ERROR: Invalid selection '${choice}'."
        return 1
    fi

    local selected="${backups[$(( choice - 1 ))]}"
    message ""
    message "Selected: $(basename "$selected")"

    local confirm
    echo -n "Restore this backup to ${conf_dir}? This will overwrite live config! (yes/N) [N]: "
    read -r confirm
    if [[ "${confirm,,}" != "yes" ]]; then
        message "Restore cancelled."
        return 0
    fi

    # Back up current live config before overwriting
    message "Backing up current ${conf_dir} before restore..."
    backup_etc_asterisk
    message "  Current config saved to: ${LAST_BACKUP_PATH}"

    message "Restoring ${selected} → ${conf_dir} ..."
    rm -rf "$conf_dir" \
        || { message "ERROR: Cannot remove ${conf_dir}"; terminate 1; }
    cp -a "$selected" "$conf_dir" \
        || { message "ERROR: Restore failed — original was backed up at ${LAST_BACKUP_PATH}"; terminate 1; }
    message "  Restore complete."
    message "  Reload Asterisk config:  asterisk -rx 'core reload'"
}

# detect_asterisk_prefix()
# Derives ASTERISK_PREFIX, ASTERISK_SYSCONFDIR, ASTERISK_LOCALSTATEDIR
# from the path of the running asterisk binary.
# Falls back to Debian-standard /usr layout if the binary is not found.
detect_asterisk_prefix() {
    local bin
    bin=$(command -v asterisk 2>/dev/null || true)

    if [[ -z "$bin" ]]; then
        message "WARNING: asterisk binary not found in PATH — assuming prefix /usr."
        ASTERISK_PREFIX="/usr"
        ASTERISK_SYSCONFDIR="/etc"
        ASTERISK_LOCALSTATEDIR="/var"
        return 0
    fi

    # /usr/sbin/asterisk → prefix /usr
    # /usr/local/sbin/asterisk → prefix /usr/local
    local sbin_dir; sbin_dir=$(dirname "$bin")
    ASTERISK_PREFIX=$(dirname "$sbin_dir")

    # Standard Debian: sysconfdir and localstatedir are /etc and /var even when
    # prefix is /usr.  For any non-/usr prefix we derive them from the prefix.
    if [[ "$ASTERISK_PREFIX" == "/usr" ]]; then
        ASTERISK_SYSCONFDIR="/etc"
        ASTERISK_LOCALSTATEDIR="/var"
    else
        ASTERISK_SYSCONFDIR="${ASTERISK_PREFIX}/etc"
        ASTERISK_LOCALSTATEDIR="${ASTERISK_PREFIX}/var"
    fi

    message "Detected Asterisk install prefix: ${ASTERISK_PREFIX}"
    message "  Config directory: ${ASTERISK_SYSCONFDIR}/asterisk/"
    message "  State directory:  ${ASTERISK_LOCALSTATEDIR}/lib/asterisk/"
}

# restart_asterisk_service()
# Restarts the running Asterisk process via systemctl (or service, or asterisk CLI
# as a last resort).  Dry-run-aware.
restart_asterisk_service() {
    message ""
    message "Restarting Asterisk to pick up the new binary..."

    if dry_run_gate "systemctl restart asterisk (or equivalent)"; then
        if command -v systemctl >/dev/null 2>&1 \
           && systemctl is-active --quiet asterisk 2>/dev/null; then
            systemctl restart asterisk \
                || { message "WARNING: systemctl restart failed — restart Asterisk manually."; return 0; }
            message "  Asterisk restarted via systemctl [OK]"
        elif command -v service >/dev/null 2>&1; then
            service asterisk restart \
                || { message "WARNING: service restart failed — restart Asterisk manually."; return 0; }
            message "  Asterisk restarted via service [OK]"
        else
            # Last resort: soft restart via the CLI
            local out
            out=$(asterisk -rx 'core restart gracefully' 2>&1 || true)
            message "  Sent 'core restart gracefully' via Asterisk CLI."
            message "  CLI output: ${out}"
            message "  Wait 10–30 s then verify: asterisk -rx 'pjsip show transports'"
        fi
    fi
}

# offer_asterisk_upgrade()
# In-place source-build upgrade for UPGRADE_NEEDED systems.
# Downloads the latest -current tarball for $ASTVERSION, builds it, and runs
# make install — without 'make samples' so /etc/asterisk is never overwritten.
# Backs up /etc/asterisk before touching anything.
# After install, verifies the new version meets the native support threshold.
# Dry-run-aware throughout.
offer_asterisk_upgrade() {
    local major="${ASTVERSION:-22}"

    message ""
    message "── In-Place Asterisk Upgrade (Phase 8) ──"
    message "  Upgrading Asterisk branch ${major} to the latest ${major}-current release."
    message "  /etc/asterisk will NOT be overwritten — existing config is preserved."

    # Step 1 — back up /etc/asterisk before any change
    backup_etc_asterisk
    if [[ "$dryrun" == false && -n "$LAST_BACKUP_PATH" ]]; then
        message "  Config backup: ${LAST_BACKUP_PATH}"
    fi

    # Step 2 — detect existing install prefix so ./configure matches
    detect_asterisk_prefix

    # Step 3 — download + extract the new source
    mkdir -p "$SRCDIR" 2>/dev/null || true
    select_asterisk_tarball "$major"
    message ""
    message "  Tarball: ${TARBALL}"
    message "  URL:     ${TARBALL_URL}"

    download_asterisk_source
    extract_asterisk_source

    # Step 4 — build dependencies (idempotent on a system with a prior build)
    install_build_prereqs

    # Step 5 — configure to match the existing install layout
    configure_asterisk_build

    # Step 6 — compile
    message ""
    message "Compiling Asterisk (this may take 10–20 minutes)..."
    if dry_run_gate "cd '${ASTERISK_SRC_DIR}' && make"; then
        (
            cd "$ASTERISK_SRC_DIR" \
                || { message "ERROR: Cannot enter source directory: ${ASTERISK_SRC_DIR}"; terminate 1; }
            make || { message "ERROR: make failed during upgrade"; terminate 1; }
        )
        message "Compilation complete."
    fi

    # Step 7 — install (deliberately no 'make samples' — preserve existing config)
    message ""
    message "Installing upgraded Asterisk (make install — config files are NOT touched)..."
    if dry_run_gate "cd '${ASTERISK_SRC_DIR}' && make install"; then
        (
            cd "$ASTERISK_SRC_DIR" \
                || { message "ERROR: Cannot enter source directory: ${ASTERISK_SRC_DIR}"; terminate 1; }
            make install || { message "ERROR: make install failed during upgrade"; terminate 1; }
        )
        message "Asterisk installed."
    fi

    # Step 8 — verify the new version meets the support threshold (P8-04)
    verify_installed_version

    # Step 9 — restart
    restart_asterisk_service

    message ""
    message "In-place upgrade complete."
    message "  Verify: asterisk -V"
    message "  Verify transport: asterisk -rx 'pjsip show transports'"
}

## ── MAIN ─────────────────────────────────────────────────────────────────────────

main() {
    local host
    host=$(hostname)
    pidfile="/var/run/${SCRIPT_NAME}.pid"

    # --check and --generate-config are read-only; all other modes require root
    if [[ "$MODE_CHECK" == false && "$MODE_GENERATE_CONFIG" == false ]]; then
        _require_root
    fi

    if [[ -f "$pidfile" ]]; then
        message "ERROR: Another instance appears to be running (pidfile: $pidfile)."
        message "Delete $pidfile if stale, then re-run."
        exit 1
    fi

    local start
    start=$(date +%s.%N)
    touch "$pidfile"

    # Redirect stderr to log file from this point forward.
    # Placed here (inside main, after pidfile creation) so that argument parse errors
    # and mutual exclusion errors above in global scope still reach the terminal.
    exec 2>>"$LOG_FILE"

    message "── ${SCRIPT_NAME} v${WIZARD_VERSION} starting on ${host} ──"
    message "Log: $LOG_FILE"

    trap 'cleanup' EXIT
    trap 'terminate 130' INT
    trap 'terminate 143' TERM

    # Detect architecture
    if [[ -z "$CPU_ARCH" ]]; then
        CPU_ARCH=$(detect_cpu_arch || true)
        DEBIAN_ARCH=$(detect_debian_arch 2>/dev/null || map_to_debian_arch "$CPU_ARCH")
    else
        DEBIAN_ARCH=$(map_to_debian_arch "$CPU_ARCH")
    fi
    message "Architecture: CPU=$CPU_ARCH  Debian=$DEBIAN_ARCH"

    # OS validation
    validate_os

    # Detect FreePBX
    detect_freepbx

    # ── Asterisk version detection & native support check ───────────────
    if [[ "$MODE_GREENFIELD" == true ]]; then
        # Greenfield: no running Asterisk to detect — version comes from --version flag
        if [[ -z "$ASTVERSION" ]]; then
            message "No --version specified for greenfield install; defaulting to 22 (LTS)."
            ASTVERSION="22"
        else
            message "Greenfield target Asterisk version: ${ASTVERSION} (from --version)"
        fi
        # Validate greenfield target branch
        case "$ASTVERSION" in
            21)
                message "ERROR: Asterisk 21 is not supported by this wizard."
                message "  Use MSTeams-FreePBX-Install.sh (legacy patch script) for Asterisk 21."
                terminate 1 ;;
            20|22|23|24) : ;;  # valid
            *)
                if (( ASTVERSION >= 24 )) 2>/dev/null; then
                    message "Greenfield target Asterisk ${ASTVERSION}: future branch — native support assumed."
                else
                    message "WARNING: Asterisk ${ASTVERSION} is not a recognised supported branch for greenfield."
                fi ;;
        esac
    else
        # Brownfield: detect and validate the running Asterisk installation
        if [[ "$ASTVERSION_FROM_CLI" == true ]]; then
            message "Note: --version=${ASTVERSION} specified; full version will be detected from running instance."
        fi
        local _cns_out _support_status _detected_ver
        _cns_out=$(check_native_support)
        read -r _support_status _detected_ver <<< "$_cns_out"
        # Propagate detected version into parent-shell globals
        if [[ -n "$_detected_ver" ]]; then
            AST_FULL_VERSION="$_detected_ver"
            if [[ "$ASTVERSION_FROM_CLI" != true ]]; then
                ASTVERSION="${_detected_ver%%.*}"
            fi
        fi
        # Warn if --version flag doesn't match the detected major branch
        if [[ "$ASTVERSION_FROM_CLI" == true && -n "$AST_FULL_VERSION" ]]; then
            local detected_major="${AST_FULL_VERSION%%.*}"
            if [[ "$detected_major" != "$ASTVERSION" ]]; then
                message "WARNING: --version=${ASTVERSION} does not match running Asterisk ${AST_FULL_VERSION}."
                message "  Using detected version ${AST_FULL_VERSION} for compatibility check."
                ASTVERSION="$detected_major"
            fi
        fi
        handle_version_check "$_support_status"
    fi

    # ── FQDN resolution & DNS validation ──────────────────────────────────
    # Always resolve the FQDN; --check and --generate-config use it read-only.
    resolve_fqdn

    # For non-read-only modes: also detect public IP and run DNS check.
    # --check runs its own DNS check in its own section (Phase 10).
    if [[ "$MODE_CHECK" == false && "$MODE_GENERATE_CONFIG" == false ]]; then
        detect_public_ip
        dns_check_with_confirm "$FQDN"
    fi

    # Prompt for SSL email when interactive and not skipping SSL
    if [[ "$SKIP_SSL" == false && "$USE_EXISTING_CERT" == false && -z "$SSL_EMAIL" \
          && "$MODE_CHECK" == false && "$MODE_GENERATE_CONFIG" == false && "$dryrun" == false ]]; then
        echo -n "Email for Let's Encrypt SSL (blank = use existing cert / skip): "
        read -r _email_input
        if [[ -n "$_email_input" ]]; then
            SSL_EMAIL="$_email_input"
            message "SSL email: $SSL_EMAIL"
        else
            USE_EXISTING_CERT=true
            message "No email — will use existing certificate if available."
        fi
    fi

    # Confirm before any action (skip for read-only modes)
    if [[ "$MODE_CHECK" == false && "$MODE_GENERATE_CONFIG" == false ]]; then
        confirm_run_options
    fi

    # ── Mode dispatch ─────────────────────────────────────────────────────
    message ""
    if [[ "$MODE_CHECK" == true ]]; then
        message "═══════════════════════════════════════════════════════════════════"
        message " MS Teams Direct Routing — Configuration Audit"
        message "═══════════════════════════════════════════════════════════════════"

        local _chk_fail=0   # incremented for each failing check; drives exit code

        # P10-01 — Asterisk version vs. minimum threshold
        message ""
        message "── Asterisk Version ──"
        local ast_display="${AST_FULL_VERSION:-${ASTVERSION:-unknown}}"
        local _ver_status=""
        if [[ -n "${AST_FULL_VERSION:-}" ]]; then
            local _vs; _vs=$(check_native_support)
            read -r _ver_status _ <<< "$_vs"
        fi
        if [[ "$_ver_status" == "SUPPORTED" ]]; then
            message "  ${ast_display} — native external_signaling_hostname support [OK]"
        elif [[ "$_ver_status" == "UPGRADE_NEEDED" ]]; then
            message "  ${ast_display} — BELOW minimum for native support [FAIL]"
            message "  Upgrade to: 20.21.0+, 22.11.0+, 23.5.0+, or 24.0.0+"
            (( _chk_fail++ )) || true
        elif [[ "$_ver_status" == "UNSUPPORTED_BRANCH" ]]; then
            message "  ${ast_display} — unsupported branch (21.x) [FAIL]"
            (( _chk_fail++ )) || true
        else
            message "  ${ast_display} — version could not be verified [WARN]"
        fi

        # P10-02 — FreePBX
        message ""
        message "── Environment ──"
        message "  FreePBX: ${FREEPBX_MODE}"
        message "  FQDN:    ${FQDN}"

        # P10-03 — DNS resolution
        detect_public_ip
        verify_dns_resolution "$FQDN" || (( _chk_fail++ )) || true

        # P10-04 — TLS certificate
        check_tls_cert "$FQDN" || (( _chk_fail++ )) || true

        # P10-05 — external_signaling_hostname in active config
        check_external_signaling_hostname || (( _chk_fail++ )) || true

        # P10-06 — Port 5061 binding
        check_firewall_ports || (( _chk_fail++ )) || true

        # P10-07 — Structured summary + exit code
        message ""
        message "═══════════════════════════════════════════════════════════════════"
        if (( _chk_fail == 0 )); then
            message " Audit result: ALL CHECKS PASSED [OK]"
        else
            message " Audit result: ${_chk_fail} check(s) FAILED — review warnings above."
        fi
        message "═══════════════════════════════════════════════════════════════════"

        terminate "$_chk_fail"

    elif [[ "$MODE_GENERATE_CONFIG" == true ]]; then
        message "── GENERATE CONFIG MODE ──"
        message "  FQDN: ${FQDN}"
        detect_public_ip
        set_transport_defaults
        set_endpoint_defaults
        # Allow interactive override of defaults even in generate-config mode
        if [[ "$dryrun" == false ]]; then
            prompt_transport_params
            prompt_endpoint_params
        fi
        local stanza; stanza=$(generate_transport_stanza)
        local ep_stanza; ep_stanza=$(generate_endpoint_stanza)
        echo ""
        echo "# ══ Transport stanza → ${PJSIP_TRANSPORT_CONF} ══"
        echo "$stanza"
        echo ""
        echo "# ══ Endpoint/AOR/Identify stanza → ${PJSIP_ENDPOINT_CONF} ══"
        echo "$ep_stanza"
        echo "# ── End of generated stanza ──"
        echo ""
        message "Config printed to stdout — no files modified."

    elif [[ "$MODE_SSL_ONLY" == true ]]; then
        message "── SSL-ONLY MODE ──"
        install_ssl

    elif [[ "$MODE_GREENFIELD" == true ]]; then
        message "── GREENFIELD MODE ──"
        message "  Building Asterisk ${ASTVERSION:-22} from source on bare Debian 12."
        build_asterisk_from_source
        install_ssl
        run_transport_wizard
        run_endpoint_wizard
        check_firewall_ports || true   # informational

    else
        message "── INTERACTIVE WIZARD MODE ──"
        message "  Configuring external_signaling_hostname on Asterisk ${ASTVERSION:-unknown}."
        message "  Config target: $PJSIP_TRANSPORT_CONF"
        install_ssl
        run_transport_wizard
        run_endpoint_wizard
        check_firewall_ports || true   # informational
    fi

    local end elapsed
    end=$(date +%s.%N)
    elapsed=$(awk "BEGIN {printf \"%.1f\", $end - $start}")
    message ""
    message "── ${SCRIPT_NAME} completed in ${elapsed}s ──"
    message "Log: $LOG_FILE"
}

## ── ENTRY POINT (skipped when script is sourced for unit testing) ───────────────

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then

    ## ── ARGUMENT PARSER ──────────────────────────────────────────────────────

    POSITIONAL_ARGS=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --greenfield)          MODE_GREENFIELD=true; shift ;;
            --check)               MODE_CHECK=true; shift ;;
            --ssl-only)            MODE_SSL_ONLY=true; shift ;;
            --generate-config)     MODE_GENERATE_CONFIG=true; shift ;;
            --dry-run|--debug)     dryrun=true; shift ;;
            --version=*)           ASTVERSION="${1#*=}"; ASTVERSION_FROM_CLI=true; shift ;;
            --version)
                if [[ -n "${2:-}" && "${2:-}" != -* ]]; then
                    ASTVERSION="$2"; ASTVERSION_FROM_CLI=true; shift 2
                else echo "ERROR: --version requires a value" >&2; exit 1; fi ;;
            --fqdn=*)              CLI_FQDN="${1#*=}"; shift ;;
            --fqdn)
                if [[ -n "${2:-}" && "${2:-}" != -* ]]; then
                    CLI_FQDN="$2"; shift 2
                else echo "ERROR: --fqdn requires a value" >&2; exit 1; fi ;;
            --email=*)             SSL_EMAIL="${1#*=}"; shift ;;
            --email)
                if [[ -n "${2:-}" && "${2:-}" != -* ]]; then
                    SSL_EMAIL="$2"; shift 2
                else echo "ERROR: --email requires a value" >&2; exit 1; fi ;;
            --use-existing-cert)   USE_EXISTING_CERT=true; shift ;;
            --no-ssl|--skip-ssl)   SKIP_SSL=true; shift ;;
            -h|--help)             show_help; exit 0 ;;
            -*)
                echo "ERROR: Unknown option: $1" >&2
                echo "Run '$0 --help' for usage." >&2
                exit 1 ;;
            *)  POSITIONAL_ARGS+=("$1"); shift ;;
        esac
    done

    ## ── MUTUAL EXCLUSION CHECK ────────────────────────────────────────────────

    _active_mode_count=$(_count_active_modes)
    if (( _active_mode_count > 1 )); then
        echo "ERROR: --greenfield, --check, --ssl-only, --generate-config are mutually exclusive." >&2
        exit 1
    fi

    main "$@"

fi  # end: [[ "${BASH_SOURCE[0]}" == "${0}" ]]
