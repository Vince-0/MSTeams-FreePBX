#!/usr/bin/env bash
################################################################################
# Build full MSTeams-patched PJSIP prebuilt module bundles for Debian 12 amd64.
#
# For each supported Asterisk major version (21, 22, 23), this script downloads
# the latest source tarball, applies the ms_signaling_address runtime patch,
# compiles Asterisk, and copies the complete PJSIP module ABI set into:
#   prebuilt/debian12-amd64/asterisk-{21,22,23}/
#
# The complete set is:
#   - every res/res_pjsip*.so file
#   - channels/chan_pjsip.so
################################################################################

set -Eeuo pipefail
IFS=$'\n\t'

SUPPORTED_VERSIONS=(21 22 23)
TARGET_DEBIAN="12"
TARGET_ARCH="amd64"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
PATCH_DIR="$REPO_ROOT/patches"
OUT_ROOT="$REPO_ROOT/prebuilt/debian12-amd64"
PATCH_BASE_URL="https://raw.githubusercontent.com/Vince-0/MSTeams-FreePBX/main/patches"

JOBS="${JOBS:-$(nproc 2>/dev/null || echo 1)}"
INSTALL_PREREQS=false
KEEP_WORK=false
WORK_BASE=""

usage() {
    cat <<HELP
Usage: sudo ./build-prebuilt-pjsip-bundles.sh [options]

Build full prebuilt PJSIP module bundles for Debian 12 amd64 and Asterisk 21/22/23.

Options:
  --install-prereqs       Run Asterisk contrib/scripts/install_prereq install for each build.
  --jobs N                Parallel make jobs. Default: nproc (${JOBS}).
  --work-dir PATH         Work directory. Default: a temporary directory under /tmp.
  --out-root PATH         Output root. Default: ${OUT_ROOT}
  --keep-work             Keep downloaded/extracted source trees after completion.
  -h, --help              Show this help.

Environment:
  JOBS=N                  Alternative way to set make parallelism.
HELP
}

log() { printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --install-prereqs) INSTALL_PREREQS=true; shift ;;
            --jobs) JOBS="${2:?--jobs requires a value}"; shift 2 ;;
            --work-dir) WORK_BASE="${2:?--work-dir requires a path}"; shift 2 ;;
            --out-root) OUT_ROOT="${2:?--out-root requires a path}"; shift 2 ;;
            --keep-work) KEEP_WORK=true; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done
}

check_platform() {
    local arch="unknown" debian_version="unknown"

    if command -v dpkg >/dev/null 2>&1; then
        arch="$(dpkg --print-architecture)"
    elif [[ "$(uname -m)" == "x86_64" ]]; then
        arch="amd64"
    fi

    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        debian_version="${VERSION_ID:-unknown}"
    fi

    [[ "$arch" == "$TARGET_ARCH" ]] || die "This script targets ${TARGET_ARCH}; detected ${arch}."
    [[ "$debian_version" == "$TARGET_DEBIAN" ]] || \
        log "WARNING: This script targets Debian ${TARGET_DEBIAN}; detected VERSION_ID=${debian_version}."
}

prepare_work_dir() {
    if [[ -z "$WORK_BASE" ]]; then
        WORK_BASE="$(mktemp -d /tmp/msteams-pjsip-prebuilt.XXXXXX)"
    else
        mkdir -p "$WORK_BASE"
    fi
    log "Work directory: $WORK_BASE"
    log "Output root:    $OUT_ROOT"
}

cleanup_all() {
    if [[ "$KEEP_WORK" == false && -n "${WORK_BASE:-}" && "$WORK_BASE" == /tmp/msteams-pjsip-prebuilt.* ]]; then
        rm -rf "$WORK_BASE"
    fi
}

patch_file_for_version() {
    local version="$1"
    local patch_file="$PATCH_DIR/asterisk-${version}-ms-teams-ms_signaling_address-8ee0332.patch"

    if [[ ! -s "$patch_file" ]]; then
        mkdir -p "$PATCH_DIR"
        log "Patch missing locally; downloading: $(basename "$patch_file")" >&2
        curl -fsSL -o "$patch_file" "$PATCH_BASE_URL/$(basename "$patch_file")" || \
            die "Failed to download patch for Asterisk ${version}."
    fi

    [[ -s "$patch_file" ]] || die "Patch file is empty or missing: $patch_file"
    printf '%s\n' "$patch_file"
}

apply_ms_teams_patch() {
    local src_dir="$1" version="$2" patch_file
    patch_file="$(patch_file_for_version "$version")"

    log "Testing patch for Asterisk ${version}: $patch_file"
    if (cd "$src_dir" && patch --dry-run -p1 < "$patch_file" >/dev/null); then
        log "Applying ms_signaling_address patch to $src_dir"
        (cd "$src_dir" && patch -p1 < "$patch_file")
    elif (cd "$src_dir" && patch -R --dry-run -p1 < "$patch_file" >/dev/null 2>&1); then
        log "Patch already applied in $src_dir; continuing."
    else
        die "Patch does not apply cleanly to $src_dir"
    fi
}

download_and_extract() {
    local version="$1" build_dir="$2" tarball="$build_dir/asterisk-${version}-current.tar.gz"
    local url="https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-${version}-current.tar.gz"

    rm -rf "$build_dir"
    mkdir -p "$build_dir"

    log "Downloading Asterisk ${version} latest source: $url" >&2
    curl -fL --retry 3 --retry-delay 5 -o "$tarball" "$url" >&2

    log "Extracting $(basename "$tarball")" >&2
    tar -xzf "$tarball" -C "$build_dir"
    find "$build_dir" -maxdepth 1 -mindepth 1 -type d -name "asterisk-${version}.*" | sort | head -n 1
}

collect_modules() {
    local src_dir="$1" out_dir="$2"
    local -a modules=()

    [[ -f "$src_dir/res/res_pjsip.so" ]] || die "Core module missing after build: res_pjsip.so"
    [[ -f "$src_dir/res/res_pjsip_nat.so" ]] || die "Core module missing after build: res_pjsip_nat.so"
    [[ -f "$src_dir/channels/chan_pjsip.so" ]] || die "Channel module missing after build: chan_pjsip.so"

    shopt -s nullglob
    modules=("$src_dir"/res/res_pjsip*.so "$src_dir"/channels/chan_pjsip.so)
    shopt -u nullglob
    [[ ${#modules[@]} -gt 0 ]] || die "No PJSIP modules found in build output."

    rm -rf "$out_dir"
    mkdir -p "$out_dir"

    log "Copying ${#modules[@]} PJSIP module(s) to $out_dir"
    for module in "${modules[@]}"; do
        cp -v "$module" "$out_dir/$(basename "$module")"
    done

    for patched_module in res_pjsip.so res_pjsip_nat.so; do
        grep -a -q "ms_signaling_address" "$out_dir/$patched_module" || \
            die "Patch marker ms_signaling_address not found in $out_dir/$patched_module"
    done

    (cd "$out_dir" && sha256sum *.so > SHA256SUMS)
    log "Bundle complete: $out_dir"
}

build_version() {
    local version="$1" build_dir="$WORK_BASE/asterisk-${version}" src_dir out_dir full_version
    out_dir="$OUT_ROOT/asterisk-${version}"

    log "=============================================================================="
    log "Building full PJSIP bundle for Asterisk ${version}"
    log "=============================================================================="

    src_dir="$(download_and_extract "$version" "$build_dir")"
    [[ -n "$src_dir" && -d "$src_dir" ]] || die "Could not locate extracted source directory for Asterisk ${version}."
    full_version="$(basename "$src_dir" | sed 's/^asterisk-//')"
    log "Extracted Asterisk source version: $full_version"

    apply_ms_teams_patch "$src_dir" "$version"

    if [[ "$INSTALL_PREREQS" == true ]]; then
        log "Installing build prerequisites for Asterisk ${version}"
        (cd "$src_dir" && contrib/scripts/install_prereq install)
    fi

    log "Configuring Asterisk ${full_version}"
    (cd "$src_dir" && ./configure)

    log "Compiling Asterisk ${full_version} with make -j${JOBS}"
    (cd "$src_dir" && make -j"$JOBS")

    collect_modules "$src_dir" "$out_dir"

    cat > "$out_dir/BUILD_INFO.txt" <<INFO
Asterisk major version: ${version}
Asterisk source version: ${full_version}
Target platform: Debian ${TARGET_DEBIAN} ${TARGET_ARCH}
Patch: $(basename "$(patch_file_for_version "$version")")
Built at: $(date -u +'%Y-%m-%dT%H:%M:%SZ')
INFO

    if [[ "$KEEP_WORK" == false ]]; then
        log "Cleaning build directory for Asterisk ${version}: $build_dir"
        rm -rf "$build_dir"
    fi
}

main() {
    parse_args "$@"
    require_cmd curl
    require_cmd tar
    require_cmd patch
    require_cmd make
    require_cmd strings
    require_cmd sha256sum
    check_platform
    prepare_work_dir
    trap cleanup_all EXIT

    mkdir -p "$OUT_ROOT"
    for version in "${SUPPORTED_VERSIONS[@]}"; do
        build_version "$version"
    done

    log "All Debian 12 amd64 Asterisk PJSIP prebuilt bundles generated successfully."
}

main "$@"
