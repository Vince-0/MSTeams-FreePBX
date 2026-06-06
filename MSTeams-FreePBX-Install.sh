#!/bin/bash
#####################################################################################
# @author https://github.com/Vince-0
#
# Use at your own risk.
#
# Requires: Debian 12, FreePBX with Asterisk 21, 22 or 23 (or standalone Asterisk with --asterisk-only).
#
# This script does this:
# Compile Asterisk from source with the ms_signaling_address runtime patch applied to the PJSIP module set,
# then deploy the full PJSIP module set (res_pjsip*.so + chan_pjsip.so) into FreePBX Asterisk.
# Install Letsencrypt SSL using certbot (preferred) and/or existing certificates.
#
# The ms_signaling_address patch adds a pjsip.conf transport option allowing the SIP Contact/Via FQDN
# to be set at runtime (no recompilation needed to change the hostname).
#
# WHY the full PJSIP set must be replaced together:
# Every module that #includes res_pjsip.h (res_pjsip*.so, chan_pjsip.so) embeds the same internal
# struct layouts. When the ms_signaling_address patch changes those structs, ALL of those modules
# must come from the same build tree. Mixing a patched res_pjsip.so with unpatched res_pjsip_session.so
# (for example) causes immediate Asterisk crashes or silent memory corruption.
#
# Options:
# --downloadonly: Download and deploy a prebuilt full PJSIP module set from
#                https://github.com/Vince-0/MSTeams-PJSIPNAT (prebuilt/debian12-<arch> layout).
#                Targets the major Asterisk version (21, 22, or 23) and detected/specified architecture.
#                Requires the bundle to contain res_pjsip.so and res_pjsip_nat.so at minimum; downloads
#                all other res_pjsip*.so and chan_pjsip.so modules present in the bundle as well.
# --restore: Restore the original PJSIP module set from .ORIG backups (all res_pjsip*.so + chan_pjsip.so).
# --copyback: Copy the MSTeams-patched PJSIP module set from .MSTEAMS copies (all res_pjsip*.so + chan_pjsip.so).
#
######################################################################################

##VARIABLES
SUPPORTED_AST_VERSIONS="21 22 23"
ASTVERSION=""
ASTVERSION_DEFAULT=22
LOG_FILE='/var/log/pbx/MSTeams-FreePBX-Install.log'
log=$LOG_FILE
PREBUILT_BASE_URL=""  # Will be constructed dynamically based on architecture
CPU_ARCH=""           # Detected CPU architecture (uname -m output)
DEBIAN_ARCH=""        # Debian architecture name (amd64, arm64, etc.)
ARCH_FROM_CLI=false   # Whether architecture was specified via --arch
LIB_PATH=""           # Override library path (from --lib parameter)
LIB_FROM_CLI=false    # Whether library path was specified via --lib
SSL_EMAIL=""
SKIP_SSL=false
SSL_STATUS="Not requested"
USE_EXISTING_CERT=false
ASTERISK_ONLY=false
ASTERISK_PREFIX=""
ASTERISK_SYSCONFDIR=""
ASTERISK_LOCALSTATEDIR=""
ASTERISK_SAMPLES_INSTALLED=false
ASTERISK_SERVICE_CREATED=false
ASTERISK_SERVICE_ENABLED=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AST_PATCH_DIR="${SCRIPT_DIR}/patches"
CLI_FQDN=""

##PREPARE
mkdir -p '/var/log/pbx/'
echo "" > $log

# Check for wget prerequisite (needed for downloading patches and Asterisk tarballs)
if ! command -v wget >/dev/null 2>&1; then
	echo "wget utility not found; installing via apt-get..."
	if ! apt-get update || ! apt-get install -y wget; then
		echo "ERROR: Failed to install 'wget' package."
		exit 1
	fi
fi

# Ensure patches directory exists and clean up old patch files
GITHUB_PATCHES_BASE_URL="https://raw.githubusercontent.com/Vince-0/MSTeams-FreePBX/main/patches"

if [[ -d "$AST_PATCH_DIR" ]]; then
	echo "Cleaning up old patch files from: $AST_PATCH_DIR"
	rm -f "${AST_PATCH_DIR}"/*.patch
else
	echo "Creating patches directory at: $AST_PATCH_DIR"
	mkdir -p "$AST_PATCH_DIR"
fi

# Download patch files from GitHub (always download fresh copies)
download_patch_file() {
	local version="$1"
	local patch_file="asterisk-${version}-ms-teams-ms_signaling_address-8ee0332.patch"
	local local_path="${AST_PATCH_DIR}/${patch_file}"
	local remote_url="${GITHUB_PATCHES_BASE_URL}/${patch_file}"

	echo "Downloading patch file for Asterisk ${version} from GitHub..."
	if wget -q -O "$local_path" "$remote_url"; then
		# Verify the file has meaningful content (guard against empty/truncated downloads)
		local file_size
		file_size=$(wc -c < "$local_path" 2>/dev/null || echo 0)
		if [[ "$file_size" -lt 500 ]]; then
			echo "ERROR: Downloaded patch file is too small (${file_size} bytes) — may be corrupt or a 404 page."
			echo "Expected URL: $remote_url"
			rm -f "$local_path"
			return 1
		fi
		echo "Successfully downloaded: ${patch_file} (${file_size} bytes)"
	else
		echo "ERROR: Failed to download patch file from: $remote_url"
		echo "Please check your internet connection or download manually from:"
		echo "https://github.com/Vince-0/MSTeams-FreePBX/tree/main/patches"
		rm -f "$local_path"
		return 1
	fi
	return 0
}

# Download patches for all supported Asterisk versions
for ast_ver in 21 22 23; do
	if ! download_patch_file "$ast_ver"; then
		exit 1
	fi
done

#ROOT CHECK
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

##HELPER FUNCTIONS
exec 2>>${LOG_FILE}

show_help() {
	    echo "Usage: $0 [OPTIONS]"
	    echo "Options:"
	    echo "  --downloadonly   Download and deploy the full prebuilt PJSIP module set (res_pjsip*.so + chan_pjsip.so)"
	    echo "                   from https://github.com/Vince-0/MSTeams-PJSIPNAT (prebuilt/debian12-<arch> layout)."
	    echo "                   All ~47 modules linking against res_pjsip.h are deployed together."
	    echo "                   Checks for exact-version full bundle (SHA256SUMS) first, then major-version, then legacy 2-module."
	    echo "                   Verifies ABI compatibility of downloaded modules before deploying."
	    echo "                   Creates .ORIG backups for all replaced modules (first run only)."
	    echo "                   Aborts if no bundle exists for the version/arch (build from source instead)."
	    echo "  --restore        Restore original PJSIP module set (res_pjsip*.so + chan_pjsip.so) from .ORIG backups"
	    echo "  --copyback       Copy MSTeams-patched PJSIP module set (res_pjsip*.so + chan_pjsip.so) from .MSTEAMS copies"
	    echo "  --version=<21|22|23>  Specify Asterisk major version to target. If omitted, the script will try to auto-detect and fall back to 22 (LTS)."
	    echo "  --arch=<arch>    Override CPU architecture (e.g., amd64, arm64, armhf, i386, ppc64el). Accepts Debian arch names or kernel names (x86_64, aarch64). Auto-detected if omitted."
	    echo "  --lib=<path>     Override library path (e.g., /usr/lib/x86_64-linux-gnu). Auto-detected based on architecture if omitted."
	    echo "  --dry-run        Show what actions would be taken (including selected Asterisk version and URLs) without making any changes"
	    echo "  --debug          Alias for --dry-run"
		    echo "  --email <addr>   Email address to use for Let's Encrypt (required to obtain/renew; not required to use existing certs)"
		    echo "  --use-existing-cert  Use an existing certificate for the FQDN if found (non-interactive; no issuance/renewal)"
		    echo "  --fqdn <name>    Override detected host FQDN (used for SSL and ms_signaling_address examples)"
		    echo "  --no-ssl         Skip Let's Encrypt / SSL installation step"
	    echo "  --asterisk-only  Install Asterisk from source without FreePBX (standalone basic Asterisk-only install)"
	    echo "  -h, --help       Show this help message and exit"
	}

log() {
        echo "$(date +"%Y-%m-%d %T") - $*" >> "$LOG_FILE"
}

message() {
        echo "$(date +"%Y-%m-%d %T") - $*"
        echo "$(date +"%Y-%m-%d %T") - $*" >> "$LOG_FILE"
}

detect_asterisk_major() {
	    if ! command -v asterisk >/dev/null 2>&1; then
	        return 1
	    fi

	    local ver
	    ver=$(asterisk -rx 'core show version' 2>/dev/null | sed -n 's/^Asterisk \([0-9][0-9]*\)\..*/\1/p' | head -n1)
	    if [[ -n "$ver" ]]; then
	        echo "$ver"
	        return 0
	    fi

	    return 1
}

is_supported_version() {
	    local ver="$1"
	    for v in $SUPPORTED_AST_VERSIONS; do
	        if [[ "$ver" == "$v" ]]; then
	            return 0
	        fi
	    done
	    return 1
	}

# Detect CPU architecture using uname -m
detect_cpu_arch() {
	    local arch
	    arch=$(uname -m)
	    if [[ -n "$arch" ]]; then
	        echo "$arch"
	        return 0
	    fi
	    return 1
}

# Detect Debian architecture using dpkg (more reliable than mapping from uname -m)
detect_debian_arch() {
	    local debian_arch
	    if command -v dpkg >/dev/null 2>&1; then
	        debian_arch=$(dpkg --print-architecture 2>/dev/null)
	        if [[ -n "$debian_arch" ]]; then
	            echo "$debian_arch"
	            return 0
	        fi
	    fi
	    # Fallback to mapping if dpkg is not available
	    return 1
}

# Map CPU architecture to Debian architecture naming (fallback only)
# Also handles if user provides Debian arch name directly (passes through)
map_to_debian_arch() {
	    local cpu_arch="$1"
	    case "$cpu_arch" in
	        x86_64)
	            echo "amd64"
	            ;;
	        aarch64)
	            echo "arm64"
	            ;;
	        armv7l)
	            echo "armhf"
	            ;;
	        i686|i386)
	            echo "i386"
	            ;;
	        ppc64le)
	            echo "ppc64el"
	            ;;
	        # If user provides Debian arch names directly, pass them through
	        amd64|arm64|armhf|armel|ppc64el|s390x|mips64el|riscv64)
	            echo "$cpu_arch"
	            ;;
	        *)
	            # Return the original architecture if no mapping exists
	            echo "$cpu_arch"
	            ;;
	    esac
}

# Map Debian architecture back to kernel architecture for multiarch paths
map_to_kernel_arch() {
	    local debian_arch="$1"
	    case "$debian_arch" in
	        amd64)
	            echo "x86_64"
	            ;;
	        arm64)
	            echo "aarch64"
	            ;;
	        armhf)
	            echo "armv7l"
	            ;;
	        i386)
	            echo "i686"
	            ;;
	        ppc64el)
	            echo "ppc64le"
	            ;;
	        *)
	            # Return the original if no mapping exists
	            echo "$debian_arch"
	            ;;
	    esac
}

# Get multiarch library path based on CPU architecture
get_multiarch_path() {
	    local cpu_arch="$1"
	    case "$cpu_arch" in
	        x86_64)
	            echo "x86_64-linux-gnu"
	            ;;
	        aarch64)
	            echo "aarch64-linux-gnu"
	            ;;
	        armv7l)
	            echo "arm-linux-gnueabihf"
	            ;;
	        i686|i386)
	            echo "i386-linux-gnu"
	            ;;
	        ppc64le)
	            echo "powerpc64le-linux-gnu"
	            ;;
	        *)
	            # Fallback to x86_64 if unknown
	            echo "x86_64-linux-gnu"
	            ;;
	    esac
}

# Get library base path - respects --lib override if provided
get_lib_path() {
	    if [[ -n "$LIB_PATH" ]]; then
	        echo "$LIB_PATH"
	    else
	        local multiarch_path
	        multiarch_path=$(get_multiarch_path "$CPU_ARCH")
	        echo "/usr/lib/$multiarch_path"
	    fi
}

# Get the actual Asterisk module directory used by the running/installed Asterisk.
# Resolution order:
#   1. Ask the running Asterisk process via 'core show settings' (most reliable)
#   2. Parse astmoddir from /etc/asterisk/asterisk.conf
#   3. Fall back to guessed multiarch path (may be wrong on some systems)
get_asterisk_module_dir() {
	local detected

	# 1. Ask running Asterisk for its module directory
	if command -v asterisk >/dev/null 2>&1; then
		detected=$(asterisk -rx 'core show settings' 2>/dev/null \
			| sed -n 's/^[[:space:]]*Module directory:[[:space:]]*//p' | head -n1)
		if [[ -n "$detected" && -d "$detected" ]]; then
			echo "$detected"
			return 0
		fi
	fi

	# 2. Parse asterisk.conf for astmoddir
	local ast_conf="/etc/asterisk/asterisk.conf"
	if [[ -f "$ast_conf" ]]; then
		detected=$(sed -n 's/^[[:space:]]*astmoddir[[:space:]]*=>[[:space:]]*//p' "$ast_conf" | head -n1)
		if [[ -n "$detected" && -d "$detected" ]]; then
			echo "$detected"
			return 0
		fi
	fi

	# 3. Fall back to guessed multiarch path (least reliable)
	local lib_path
	lib_path=$(get_lib_path)
	echo "${lib_path}/asterisk/modules"
}

# Check if architecture is well-tested for this script
check_architecture_support() {
	    local cpu_arch="$1"
	    local well_tested=false

	    case "$cpu_arch" in
	        x86_64|aarch64)
	            well_tested=true
	            ;;
	        *)
	            well_tested=false
	            ;;
	    esac

	    if [[ "$well_tested" == false ]]; then
	        message "WARNING: Architecture '$cpu_arch' is not well-tested with this script."
	        message "This script has been primarily tested on x86_64 (amd64) and aarch64 (arm64)."
	        message ""
	        message "Asterisk supports the following architectures:"
	        message "  - x86-32 and x86-64 (Intel/AMD)"
	        message "  - ARM (various versions)"
	        message "  - PowerPC"
	        message "  - SPARC"
	        message "  - Blackfin/Xscale"
	        message ""
	        message "The script will attempt to proceed with build-from-source for your architecture."
	        message "Prebuilt modules are only available for x86_64 (amd64)."
	        message ""
	    fi
}

cleanup() {
	        if [[ -n "$pidfile" && -f "$pidfile" ]]; then
	                rm -f "$pidfile"
	        fi
}

terminate() {
	        local exit_code="${1:-0}"
	        cleanup
	        exit "$exit_code"
	}

# Present a summary of the selected options and ask the user to confirm
confirm_run_options() {
	    local mode_desc ssl_desc fqdn_desc lib_path confirm

	    # Use override library path if provided, otherwise auto-detect
	    lib_path=$(get_lib_path)

	    # Determine operation mode description
	    if [[ "$ASTERISK_ONLY" == true ]]; then
	        mode_desc="--asterisk-only (Standalone Asterisk install, no FreePBX)"
	    elif [[ "$downloadonly" == true ]]; then
	        mode_desc="--downloadonly (download prebuilt full PJSIP module set from GitHub for Asterisk ${ASTVERSION} ${DEBIAN_ARCH})"
	    elif [[ "$restore" == true ]]; then
	        mode_desc="--restore (Restore original full PJSIP module set: res_pjsip*.so + chan_pjsip.so from .ORIG backups)"
	    elif [[ "$copyback" == true ]]; then
	        mode_desc="--copyback (Copy back MSTeams-patched full PJSIP module set: res_pjsip*.so + chan_pjsip.so from .MSTEAMS)"
	    else
	        mode_desc="FreePBX install + build patched full PJSIP module set (res_pjsip*.so + chan_pjsip.so) for MSTeams"
	    fi

	    # Determine FQDN first (needed for cert detection below)
	    if [[ "$ASTERISK_ONLY" == true ]]; then
	        checkfqdn
	        fqdn_desc="$FQDN"
	    elif [[ "$downloadonly" == true || "$restore" == true || "$copyback" == true ]]; then
	        fqdn_desc="N/A (not needed for this operation)"
	    else
	        # Default FreePBX patch mode also patches PJSIP NAT
	        checkfqdn
	        fqdn_desc="$FQDN"
	    fi

	    # Determine SSL description, including any existing certificate detection
	    local ssl_cert_info=""
	    if [[ "$SKIP_SSL" == true ]]; then
	        ssl_desc="--no-ssl (SSL disabled - required for MSTeams Direct Routing)"
	    else
	        if [[ "$fqdn_desc" != "N/A"* && -n "$FQDN" ]]; then
	            local _cb_dir="/etc/letsencrypt/live/${FQDN}"
	            local _ast_ssl="/etc/asterisk/ssl"
	            local _expiry
	            if [[ -f "${_cb_dir}/fullchain.pem" && -f "${_cb_dir}/privkey.pem" ]]; then
	                _expiry=$(openssl x509 -enddate -noout -in "${_cb_dir}/fullchain.pem" 2>/dev/null | sed 's/notAfter=//')
	                ssl_cert_info=" | Found certbot cert: ${_cb_dir} (expires: ${_expiry:-unknown})"
	            elif [[ -f "${_ast_ssl}/cert.crt" && -f "${_ast_ssl}/privkey.crt" ]]; then
	                _expiry=$(openssl x509 -enddate -noout -in "${_ast_ssl}/cert.crt" 2>/dev/null | sed 's/notAfter=//')
	                ssl_cert_info=" | Found existing cert: /etc/asterisk/ssl/ (expires: ${_expiry:-unknown})"
	            else
	                ssl_cert_info=" | No existing cert found for ${FQDN}"
	            fi
	        fi
	        if [[ -n "$SSL_EMAIL" ]]; then
	            ssl_desc="--email=$SSL_EMAIL (SSL enabled)${ssl_cert_info}"
	        else
	            ssl_desc="Enabled (email will be requested)${ssl_cert_info}"
	        fi
	    fi

	    message "==================================================="
	    message "MSTeams-FreePBX-Install run configuration summary:"
	    message "Operation mode: $mode_desc"
	    message "Asterisk: --version=$ASTVERSION"
	    message "Architecture: --arch=$DEBIAN_ARCH (CPU: $CPU_ARCH)"
	    message "Hostname: --fqdn=$fqdn_desc"
	    message "Library path: --lib=$lib_path"
	    message "SSL: $ssl_desc"
	    message "==================================================="
		    echo ""
		    echo -n "Proceed with these settings? (y/n) [y]: "
		    read confirm
		    message "User response to proceed prompt: '${confirm:-y}'"
		    if [[ -n "$confirm" && ! "$confirm" =~ ^[Yy]$ ]]; then
		        message "User chose not to proceed; aborting before making any changes."
		        terminate 0
		    fi
}

##ARGUMENT PARSE
POSITIONAL_ARGS=()
restore=false
copyback=false
downloadonly=false
dryrun=false
ASTVERSION_FROM_CLI=false

	while [[ $# -gt 0 ]]; do
	        case $1 in
	                --restore)
	                        restore=true
	                        shift # past argument
	                        ;;
		                --copyback)
		                        copyback=true
		                        shift # past argument
		                        ;;
	                --downloadonly)
	                        downloadonly=true
	                        shift # past argument
	                        ;;
		                --dry-run|--debug)
		                        dryrun=true
		                        shift # past argument
		                        ;;
		                --version)
		                        if [[ -n "$2" && "$2" != -* ]]; then
		                            ASTVERSION="$2"
		                            ASTVERSION_FROM_CLI=true
		                            shift 2
		                        else
		                            echo "Error: --version requires a value (one of: $SUPPORTED_AST_VERSIONS)" >&2
		                            exit 1
		                        fi
		                        ;;
		                --version=*)
		                        ASTVERSION="${1#*=}"
		                        ASTVERSION_FROM_CLI=true
		                        shift # past argument
		                        ;;
		                --arch)
		                        if [[ -n "$2" && "$2" != -* ]]; then
		                            CPU_ARCH="$2"
		                            ARCH_FROM_CLI=true
		                            shift 2
		                        else
		                            echo "Error: --arch requires a value (e.g. --arch x86_64 or --arch aarch64)" >&2
		                            exit 1
		                        fi
		                        ;;
		                --arch=*)
		                        CPU_ARCH="${1#*=}"
		                        ARCH_FROM_CLI=true
		                        shift # past argument
		                        ;;
		                --lib)
		                        if [[ -n "$2" && "$2" != -* ]]; then
		                            LIB_PATH="$2"
		                            LIB_FROM_CLI=true
		                            shift 2
		                        else
		                            echo "Error: --lib requires a value (e.g. --lib /usr/lib/x86_64-linux-gnu)" >&2
		                            exit 1
		                        fi
		                        ;;
		                --lib=*)
		                        LIB_PATH="${1#*=}"
		                        LIB_FROM_CLI=true
		                        shift # past argument
		                        ;;
		                --email)
		                        if [[ -n "$2" && "$2" != -* ]]; then
		                            SSL_EMAIL="$2"
		                            shift 2
		                        else
		                            echo "Error: --email requires a value (e.g. --email admin@example.com)" >&2
		                            exit 1
		                        fi
		                        ;;
		                --email=*)
		                        SSL_EMAIL="${1#*=}"
		                        shift # past argument
		                        ;;
		                --fqdn)
		                        if [[ -n "$2" && "$2" != -* ]]; then
		                            CLI_FQDN="$2"
		                            shift 2
		                        else
		                            echo "Error: --fqdn requires a value (e.g. --fqdn sbc.example.com)" >&2
		                            exit 1
		                        fi
		                        ;;
		                --fqdn=*)
		                        CLI_FQDN="${1#*=}"
		                        shift # past argument
		                        ;;
		                --use-existing-cert)
		                        USE_EXISTING_CERT=true
		                        shift # past argument
		                        ;;
		                --no-ssl|--skip-ssl)
		                        SKIP_SSL=true
		                        shift # past argument
		                        ;;
		                --asterisk-only)
		                        ASTERISK_ONLY=true
		                        shift # past argument
		                        ;;
		                -h|--help)
		                        show_help
		                        exit 0
		                        ;;
	                -*|--*)
	                        echo "Unknown option $1"
	                        show_help
	                        exit 1
	                        ;;
	                *)
	                        POSITIONAL_ARGS+=("$1") # save positional arg
	                        shift # past argument
	                        ;;
	        esac
	done

# Ensure mutually exclusive options are not combined
if [[ "$ASTERISK_ONLY" == true ]]; then
        conflict_flags=()
        [[ "$downloadonly" == true ]] && conflict_flags+=("--downloadonly")
        [[ "$restore" == true ]] && conflict_flags+=("--restore")
        [[ "$copyback" == true ]] && conflict_flags+=("--copyback")

        if (( ${#conflict_flags[@]} > 0 )); then
                echo "Error: --asterisk-only cannot be used together with: ${conflict_flags[*]}" >&2
                exit 1
        fi
fi

# Collect SSL email early (after argument parsing) for operations that can install SSL.
# Skip in dry-run mode, when SSL is disabled, when using existing cert (no email needed),
# or for operations that do not perform SSL work (restore/copyback/downloadonly).
if [[ "$dryrun" != true && "$SKIP_SSL" != true && "$USE_EXISTING_CERT" != true && -z "$SSL_EMAIL" && "$restore" != true && "$copyback" != true && "$downloadonly" != true ]]; then
	echo ""
	echo -n "SSL certificate Email (blank to skip SSL, or press Enter to only use existing certs): "
	read ssl_email_input
	message "User SSL email input: '${ssl_email_input:-<blank>}'"
	if [[ -n "$ssl_email_input" ]]; then
		SSL_EMAIL="$ssl_email_input"
		message "SSL email set to: $SSL_EMAIL"
	else
		message "No email provided; will attempt to use existing certificate or skip SSL."
		USE_EXISTING_CERT=true
	fi
fi

##MAIN FUNCTIONS

#Check for host FQDN (used for SSL and recommended ms_signaling_address examples)
checkfqdn() {
	        if [[ -n "$CLI_FQDN" ]]; then
	                FQDN="$CLI_FQDN"
	                message "Using FQDN override from --fqdn: '${FQDN}'"
	        else
	                FQDN=$(hostname)
	                message "No --fqdn override supplied; using system hostname '${FQDN}'"
	        fi

	        if [[ "$FQDN" == *.* ]]; then
	          message "FQDN '${FQDN}' appears valid (contains a dot)."
	          message "Proceeding."
	        else
	          message "ERROR: FQDN '${FQDN}' does not look valid (no dot)."
	          message "Please configure a proper FQDN hostname or supply one with --fqdn."
	          terminate
	        fi
	}

# Restore the full original PJSIP module set from .ORIG backups.
# Discovers all res_pjsip*.so.ORIG and chan_pjsip.so.ORIG files dynamically so that
# every ABI-coupled module is restored together, regardless of how many were deployed.
restore() {
        local modules_dir
        modules_dir=$(get_asterisk_module_dir)

        message "Restoring original PJSIP module set from .ORIG backups in: $modules_dir"

        # Collect all PJSIP .ORIG backups present in the module directory
        shopt -s nullglob
        local orig_files=("$modules_dir"/res_pjsip*.so.ORIG "$modules_dir"/chan_pjsip.so.ORIG)
        shopt -u nullglob

        if [[ ${#orig_files[@]} -eq 0 ]]; then
                message "WARNING: No .ORIG backups found for PJSIP modules in $modules_dir."
                message "Nothing to restore. Run without --restore to perform a fresh install."
                return
        fi

        message "Found ${#orig_files[@]} .ORIG backup(s) to restore:"
        local restored_count=0
        for backup in "${orig_files[@]}"; do
                local mod
                mod=$(basename "${backup%.ORIG}")
                message "  Restoring ${mod} from $(basename "$backup") ..."
                cp -v "$backup" "$modules_dir/$mod"
                message "  Restored: ${mod}"
                (( restored_count++ ))
        done

        message "Restored ${restored_count} PJSIP module(s) from .ORIG backups."
        message "IMPORTANT: A full Asterisk/FreePBX restart is required to activate the restored modules."
        message "  Run: fwconsole restart   (FreePBX)  OR  systemctl restart asterisk  (standalone)"
}

# Copy back the full MSTeams-patched PJSIP module set from .MSTEAMS copies.
# Discovers all res_pjsip*.so.MSTEAMS and chan_pjsip.so.MSTEAMS files dynamically so that
# every ABI-coupled module is re-activated together.
copyback() {
        local modules_dir
        modules_dir=$(get_asterisk_module_dir)

        message "Copying MSTeams-patched PJSIP module set from .MSTEAMS copies in: $modules_dir"

        # Collect all PJSIP .MSTEAMS copies present in the module directory
        shopt -s nullglob
        local msteams_files=("$modules_dir"/res_pjsip*.so.MSTEAMS "$modules_dir"/chan_pjsip.so.MSTEAMS)
        shopt -u nullglob

        if [[ ${#msteams_files[@]} -eq 0 ]]; then
                message "WARNING: No .MSTEAMS copies found for PJSIP modules in $modules_dir."
                message "Nothing to copy back. Run without --copyback to perform a fresh install."
                return
        fi

        message "Found ${#msteams_files[@]} .MSTEAMS copy(ies) to deploy:"
        local restored_count=0
        for msteams in "${msteams_files[@]}"; do
                local mod
                mod=$(basename "${msteams%.MSTEAMS}")
                message "  Copying ${mod} from $(basename "$msteams") ..."
                cp -v "$msteams" "$modules_dir/$mod"
                message "  Deployed: ${mod}"
                (( restored_count++ ))
        done

        message "Copied back ${restored_count} MSTeams-patched PJSIP module(s) from .MSTEAMS copies."
        message "IMPORTANT: A full Asterisk/FreePBX restart is required to activate the patched modules."
        message "  Run: fwconsole restart   (FreePBX)  OR  systemctl restart asterisk  (standalone)"
}

downloadonly() {
	# Download and deploy the full prebuilt PJSIP module set from
	# https://github.com/Vince-0/MSTeams-PJSIPNAT/tree/main/prebuilt/debian12-<arch>
	#
	# Every module that #includes res_pjsip.h (res_pjsip*.so, chan_pjsip.so) encodes the
	# same internal struct layouts at compile time.  The ms_signaling_address patch changes
	# those structs, so ALL such modules must come from the same build tree.  Leaving any
	# old module in place alongside new ones will cause Asterisk crashes or silent memory
	# corruption.
	#
	# Strategy:
	#   1. Detect the exact running Asterisk version for ABI verification.
	#   2. Select bundle URL: check exact-version SHA256SUMS first, then major-version SHA256SUMS,
	#      then legacy 2-module bundles (with explicit user confirmation).
	#   3. Download all modules listed in SHA256SUMS (full bundle) or 2-module fallback (legacy).
	#   4. ABI-verify res_pjsip.so and res_pjsip_nat.so; warn+confirm rather than abort on mismatch.
	#   5. Create .ORIG backups (first run only) then deploy the full set.

	# Step 1: Determine the exact running Asterisk version (used for ABI verification)
	local ast_full_version
	ast_full_version=$(asterisk -V 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
	if [[ -z "$ast_full_version" ]]; then
		message "ERROR: Could not determine running Asterisk version."
		message "Ensure Asterisk is installed and the 'asterisk' command is on PATH."
		terminate 1
	fi
	message "Detected running Asterisk version: ${ast_full_version} (major: ${ASTVERSION})"

	# Step 2: Select bundle URL.
	# Full bundles have a SHA256SUMS manifest (built by build-prebuilt-pjsip-bundles.sh in MSTeams-PJSIPNAT).
	# Legacy 2-module bundles (pre-fix) do not. Check in order of preference:
	#   1. exact-version full bundle  (e.g. asterisk-22.8.2/)
	#   2. major-version full bundle  (e.g. asterisk-22/)  — warn about minor-version mismatch
	#   3. exact-version legacy bundle — warn it will cause crashes, require confirmation
	#   4. major-version legacy bundle — same warning
	local exact_url="${PREBUILT_BASE_URL}/asterisk-${ast_full_version}"
	local major_url="${PREBUILT_BASE_URL}/asterisk-${ASTVERSION}"
	local bundle_url=""
	local bundle_is_full=false   # true = SHA256SUMS present (full bundle), false = legacy 2-module bundle

	# Create tmpdir now so SHA256SUMS can be fetched directly during URL selection,
	# avoiding a second download of the same file in Step 3 (fix: double-fetch eliminated).
	local tmpdir
	tmpdir=$(mktemp -d)
	local sha256_file="${tmpdir}/SHA256SUMS"

	if curl -fsSL -o "$sha256_file" "${exact_url}/SHA256SUMS" 2>/dev/null && [[ -s "$sha256_file" ]]; then
		bundle_url="$exact_url"
		bundle_is_full=true
		message "Found exact-version full bundle for Asterisk ${ast_full_version}."

	elif curl -fsSL -o "$sha256_file" "${major_url}/SHA256SUMS" 2>/dev/null && [[ -s "$sha256_file" ]]; then
		bundle_url="$major_url"
		bundle_is_full=true
		message "No exact-version full bundle for ${ast_full_version}. Using major-version full bundle (asterisk-${ASTVERSION})."
		message "WARNING: Major-version bundle may not match running Asterisk ${ast_full_version} exactly."
		message "ABI verification will run after download. You will be asked to confirm if versions differ."

	elif curl -fsIL "${exact_url}/res_pjsip.so" >/dev/null 2>&1; then
		bundle_url="$exact_url"
		bundle_is_full=false
		message "WARNING: Found only a legacy (pre-fix) 2-module bundle for Asterisk ${ast_full_version}."
		message "Deploying this bundle WILL cause an Asterisk crash/bootloop on FreePBX installations."
		message "Build from source instead (run without --downloadonly) to deploy all ~47 required modules."
		echo -n "Proceed with legacy 2-module bundle anyway? (y/n) [n]: "
		local confirm_legacy
		read -r confirm_legacy
		if [[ ! "$confirm_legacy" =~ ^[Yy]$ ]]; then
			message "Aborting."; rm -rf "$tmpdir"; terminate 1
		fi

	elif curl -fsIL "${major_url}/res_pjsip.so" >/dev/null 2>&1; then
		bundle_url="$major_url"
		bundle_is_full=false
		message "WARNING: Found only a legacy (pre-fix) 2-module bundle at major-version path (asterisk-${ASTVERSION})."
		message "Deploying this bundle WILL cause an Asterisk crash/bootloop on FreePBX installations."
		message "Build from source instead (run without --downloadonly) to deploy all ~47 required modules."
		echo -n "Proceed with legacy 2-module bundle anyway? (y/n) [n]: "
		local confirm_legacy
		read -r confirm_legacy
		if [[ ! "$confirm_legacy" =~ ^[Yy]$ ]]; then
			message "Aborting."; rm -rf "$tmpdir"; terminate 1
		fi

	else
		message "ERROR: No bundle found for Asterisk ${ast_full_version} (${DEBIAN_ARCH})."
		message "Checked:"
		message "  ${exact_url}/SHA256SUMS"
		message "  ${major_url}/SHA256SUMS"
		message "  ${exact_url}/res_pjsip.so"
		message "  ${major_url}/res_pjsip.so"
		message "Run without --downloadonly to build from source."
		rm -rf "$tmpdir"; terminate 1
	fi

	# Determine the Asterisk module directory
	local modules_dir
	modules_dir=$(get_asterisk_module_dir)

	# Step 3: Build the module download list.
	# Full bundles: SHA256SUMS was already fetched during URL selection — no second download needed.
	# Legacy bundles: use the minimal 2-module set (user confirmed the risk above).
	local modules_to_fetch=()
	local skipped_modules=()

	if [[ "$bundle_is_full" == true ]]; then
		mapfile -t modules_to_fetch < <(awk '{print $2}' "$sha256_file")
		message "Bundle manifest loaded: ${#modules_to_fetch[@]} modules."
		# Fix 1: guard against empty/malformed SHA256SUMS — would otherwise deploy nothing silently.
		if [[ ${#modules_to_fetch[@]} -eq 0 ]]; then
			message "ERROR: SHA256SUMS manifest is empty or could not be parsed — no modules to download."
			rm -rf "$tmpdir"
			terminate 1
		fi
	else
		modules_to_fetch=(res_pjsip.so res_pjsip_nat.so)
	fi

	# Step 4: Download all modules in the manifest
	local downloaded_modules=()

	message "Downloading PJSIP module set from: ${bundle_url}"
	for mod in "${modules_to_fetch[@]}"; do
		local url="${bundle_url}/${mod}"
		local dest="${tmpdir}/${mod}"

		message "  Downloading ${mod} ..."
		if ! curl -fsSL -o "$dest" "$url"; then
			message "ERROR: Failed to download ${mod} from: ${url}"
			rm -rf "$tmpdir"
			terminate 1
		fi
		local file_size
		file_size=$(wc -c < "$dest" 2>/dev/null || echo 0)
		if [[ "$file_size" -lt 100000 ]]; then
			message "ERROR: Downloaded ${mod} is too small (${file_size} bytes) — likely corrupt or a 404 page."
			rm -rf "$tmpdir"
			terminate 1
		fi
		message "  Downloaded ${mod}: ${file_size} bytes — OK"
		downloaded_modules+=("$mod")
	done
	message "Downloaded ${#downloaded_modules[@]} module(s) from bundle."

	# Step 5: ABI verification — check that the two key modules embed the running Asterisk version string.
	# Only res_pjsip.so and res_pjsip_nat.so are checked here; they are representative of the build.
	# NOTE: When using a major-version bundle (e.g. asterisk-22/) against a specific patch release
	# (e.g. 22.8.2), this check may fail because the bundle was built from a newer 22.x.y release.
	# All modules still come from the same build tree so the struct ABI is consistent; the only risk
	# is Asterisk's module version check at load time. The user is given the option to proceed.
	# A future --exact-version=X.Y.Z flag could target the specific release tarball:
	#   https://downloads.asterisk.org/pub/telephony/asterisk/releases/asterisk-X.Y.Z.tar.gz
	message "Verifying ABI compatibility (looking for version string '${ast_full_version}')..."
	local ver_ok=true
	for mod in res_pjsip.so res_pjsip_nat.so; do
		if [[ -f "${tmpdir}/${mod}" ]]; then
			local embedded
			embedded=$(strings "${tmpdir}/${mod}" 2>/dev/null | grep -F "$ast_full_version" | head -1)
			if [[ -n "$embedded" ]]; then
				message "  ${mod}: version string '${ast_full_version}' found — OK"
			else
				message "  WARNING: ${mod}: version string '${ast_full_version}' NOT found."
				ver_ok=false
			fi
		elif [[ "$bundle_is_full" == true ]]; then
			# Fix 2: sentinel absent from a full-bundle download is an error, not a silent skip.
			message "  ERROR: ${mod} missing from downloaded set — bundle may be incomplete."
			ver_ok=false
		fi
	done

	if [[ "$ver_ok" == false ]]; then
		message ""
		message "WARNING: Downloaded modules do not appear to match the running Asterisk ${ast_full_version}."
		message "This is expected when only a major-version bundle (e.g. asterisk-${ASTVERSION}/) is available"
		message "and no exact-version bundle (e.g. asterisk-${ast_full_version}/) exists yet."
		message ""
		message "All downloaded modules come from the same build tree, so the struct ABI is consistent"
		message "and the ms_signaling_address crash is prevented. However, Asterisk's module version"
		message "check at load time may reject modules with a different minor version."
		message ""
		message "For an exact version match, build from source (run without --downloadonly)."
		message ""
		echo -n "Deploy anyway? (y/n) [n]: "
		local confirm_mismatch
		read -r confirm_mismatch
		if [[ ! "$confirm_mismatch" =~ ^[Yy]$ ]]; then
			message "Aborting. Run without --downloadonly to build from source for your exact version."
			rm -rf "$tmpdir"
			terminate 1
		fi
		message "User confirmed: proceeding with version-mismatched modules."
	fi
	# Fix 6: distinguish clean pass from mismatch-but-confirmed so log review is unambiguous.
	if [[ "$ver_ok" == true ]]; then
		message "ABI verification passed — all checked modules match ${ast_full_version}."
	fi

	# Step 6: Deploy — create .ORIG backups (first run only, never overwritten),
	# then install each downloaded module and save a .MSTEAMS copy for future copyback.
	message "Deploying PJSIP module set to: ${modules_dir}"
	local deployed_count=0
	local deployed_modules=()   # Fix 4: track only modules actually written to disk
	for mod in "${downloaded_modules[@]}"; do
		local dest="${modules_dir}/${mod}"
		local backup="${modules_dir}/${mod}.ORIG"
		local msteams_copy="${modules_dir}/${mod}.MSTEAMS"

		if [[ ! -f "$dest" ]]; then
			message "  WARNING: ${mod} not found in ${modules_dir} — skipping deployment."
			skipped_modules+=("$mod")
			continue
		fi

		# Create .ORIG backup only on first run (never overwrite an existing backup)
		if [[ ! -f "$backup" ]]; then
			message "  Creating .ORIG backup: ${backup}"
			cp -v "$dest" "$backup"
		else
			message "  .ORIG backup already exists: ${backup} (not overwriting)"
		fi

		cp -v "${tmpdir}/${mod}" "$dest"
		cp -v "${tmpdir}/${mod}" "$msteams_copy"
		message "  Deployed: ${mod}"
		deployed_modules+=("$mod")
		(( deployed_count++ ))
	done

	# Fix 3: a zero-deploy is always an error — it means the module directory is wrong
	# or no downloaded module matched an installed module. Never exit silently.
	if [[ $deployed_count -eq 0 ]]; then
		message "ERROR: No modules were deployed."
		message "Verify that Asterisk PJSIP modules exist in: ${modules_dir}"
		rm -rf "$tmpdir"
		terminate 1
	fi

	rm -rf "$tmpdir"
	message ""
	message "========================================================"
	message "PJSIP module set download and deployment complete."
	message "  Asterisk major version:  ${ASTVERSION}"
	message "  Full version (ABI check): ${ast_full_version}"
	message "  Architecture:            ${DEBIAN_ARCH}"
	message "  Module directory:        ${modules_dir}"
	message "  Modules deployed (${deployed_count}):"
	for mod in "${deployed_modules[@]}"; do  # Fix 4: list only what was actually deployed
		message "    ${modules_dir}/${mod}"
	done
	if [[ ${#skipped_modules[@]} -gt 0 ]]; then
		message "  Modules not found in module dir (${#skipped_modules[@]}):"
		for s in "${skipped_modules[@]}"; do
			message "    ${s}"
		done
	fi
	message "========================================================"
	message ""
	message "IMPORTANT: Every res_pjsip*.so and chan_pjsip.so module links against"
	message "res_pjsip.h and must be from the same build. All downloaded modules have"
	message "been deployed together to ensure the ms_signaling_address patch functions"
	message "correctly and prevent Asterisk crashes."
	message ""
	message "A full Asterisk/FreePBX restart is required to activate the new modules."
	message "  Run: fwconsole restart   (FreePBX)  OR  systemctl restart asterisk  (standalone)"
}

# Install/configure SSL certificates using certbot (preferred) or existing certificates
install_letsencrypt() {
	local apache_was_running=false
	local cert_source=""   # where we ultimately get the cert from
	local existing_cert="" # path to existing fullchain/cert file
	local existing_key=""  # path to existing private key

	# ---------------------------------------------------------------
	# Helper: restart apache2 if it was stopped
	# ---------------------------------------------------------------
	_restart_apache2() {
		if [[ "$apache_was_running" == true ]]; then
			message "Restarting apache2 service..."
			if command -v systemctl >/dev/null 2>&1; then
				systemctl start apache2 || message "WARNING: Failed to restart apache2."
			elif command -v service >/dev/null 2>&1; then
				service apache2 start || message "WARNING: Failed to restart apache2 (via service)."
			fi
		fi
	}

	# ---------------------------------------------------------------
	# Helper: stop apache2 for standalone challenge
	# ---------------------------------------------------------------
	_stop_apache2() {
		if command -v systemctl >/dev/null 2>&1; then
			if systemctl is-active --quiet apache2; then
				apache_was_running=true
				message "Stopping apache2 for standalone challenge..."
				systemctl stop apache2 || message "WARNING: Failed to stop apache2."
			fi
		elif command -v service >/dev/null 2>&1; then
			if service apache2 status >/dev/null 2>&1; then
				apache_was_running=true
				message "Stopping apache2 (via service) for standalone challenge..."
				service apache2 stop || message "WARNING: Failed to stop apache2 (via service)."
			fi
		fi
	}

	# ---------------------------------------------------------------
	# Helper: show certificate expiry for a given cert file
	# ---------------------------------------------------------------
	_show_cert_expiry() {
		local cert_file="$1"
		if [[ -f "$cert_file" ]] && command -v openssl >/dev/null 2>&1; then
			local expiry
			expiry=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | sed 's/notAfter=//')
			if [[ -n "$expiry" ]]; then
				echo "  Certificate expires: $expiry"
				message "Certificate at $cert_file expires: $expiry"
			fi
		fi
	}

	# ---------------------------------------------------------------
	# Helper: copy cert files from a source dir into /etc/asterisk/ssl
	# Expects: fullchain.pem / cert.pem, privkey.pem in $1
	# ---------------------------------------------------------------
	_install_certs_from_dir() {
		local src="$1"
		local fullchain key

		# Prefer fullchain, fall back to cert
		if [[ -f "${src}/fullchain.pem" ]]; then
			fullchain="${src}/fullchain.pem"
		elif [[ -f "${src}/cert.pem" ]]; then
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

		cp -v "$fullchain" /etc/asterisk/ssl/cert.crt
		cp -v "$key"       /etc/asterisk/ssl/privkey.crt
		# ca.crt = same as fullchain for Asterisk TLS
		cp -v "$fullchain" /etc/asterisk/ssl/ca.crt
		message "Certificates copied from $src to /etc/asterisk/ssl/"
	}

	# ---------------------------------------------------------------
	# Ensure SSL directory exists
	# ---------------------------------------------------------------
	if ! mkdir -p /etc/asterisk/ssl; then
		message "ERROR: Unable to create /etc/asterisk/ssl directory."
		SSL_STATUS="FAILED: unable to create /etc/asterisk/ssl directory"
		return 1
	fi

	# ---------------------------------------------------------------
	# Detect existing certificates
	# ---------------------------------------------------------------
	local certbot_dir="/etc/letsencrypt/live/${FQDN}"
	local asterisk_ssl_dir="/etc/asterisk/ssl"
	local found_certbot=false
	local found_asterisk=false

	if [[ -f "${certbot_dir}/fullchain.pem" && -f "${certbot_dir}/privkey.pem" ]]; then
		found_certbot=true
		message "Found existing certbot certificate at: $certbot_dir"
		echo ""
		echo "  Existing Let's Encrypt (certbot) certificate found: $certbot_dir"
		_show_cert_expiry "${certbot_dir}/fullchain.pem"
	fi

	if [[ -f "${asterisk_ssl_dir}/cert.crt" && -f "${asterisk_ssl_dir}/privkey.crt" ]]; then
		found_asterisk=true
		message "Found existing certificate already in /etc/asterisk/ssl/"
		echo "  Existing certificate already installed in /etc/asterisk/ssl/"
		_show_cert_expiry "${asterisk_ssl_dir}/cert.crt"
	fi

	# ---------------------------------------------------------------
	# If USE_EXISTING_CERT=true (non-interactive) — use what we have
	# ---------------------------------------------------------------
	if [[ "$USE_EXISTING_CERT" == true ]]; then
		if [[ "$found_certbot" == true ]]; then
			message "--use-existing-cert: copying certbot certificate to /etc/asterisk/ssl/"
			if ! _install_certs_from_dir "$certbot_dir"; then
				SSL_STATUS="FAILED: could not copy certbot certificate to /etc/asterisk/ssl/"
				return 1
			fi
			SSL_STATUS="Installed: existing certbot certificate for $FQDN (certs in /etc/asterisk/ssl)"
			return 0
		elif [[ "$found_asterisk" == true ]]; then
			message "--use-existing-cert: certificate already in /etc/asterisk/ssl/; nothing to do."
			SSL_STATUS="Installed: existing certificate already in /etc/asterisk/ssl/ (no changes made)"
			return 0
		else
			message "WARNING: --use-existing-cert specified but no existing certificate found for $FQDN."
			message "No certificate installed. Use --email to obtain one."
			SSL_STATUS="Skipped: --use-existing-cert set but no existing certificate found for $FQDN"
			return 0
		fi
	fi

	# ---------------------------------------------------------------
	# Interactive prompt when existing certificate is detected
	# ---------------------------------------------------------------
	if [[ "$found_certbot" == true || "$found_asterisk" == true ]]; then
		echo ""
		echo "Existing certificate(s) detected for $FQDN."
		echo "What would you like to do?"
		echo "  [U] Use existing certificate (copy/keep as-is)"
		echo "  [R] Renew with certbot"
		echo "  [O] Obtain new certificate with certbot (requires email)"
		echo "  [S] Skip SSL installation"
		echo -n "Choice [U]: "
		local choice
		read choice
		choice="${choice:-U}"
		message "User SSL choice: '$choice'"

		case "${choice^^}" in
			U)
				if [[ "$found_certbot" == true ]]; then
					message "User chose to use existing certbot certificate."
					if ! _install_certs_from_dir "$certbot_dir"; then
						SSL_STATUS="FAILED: could not copy certbot certificate to /etc/asterisk/ssl/"
						return 1
					fi
					SSL_STATUS="Installed: existing certbot certificate for $FQDN (certs in /etc/asterisk/ssl)"
				else
					message "User chose to use existing certificate already in /etc/asterisk/ssl/."
					SSL_STATUS="Installed: existing certificate in /etc/asterisk/ssl/ (no changes made)"
				fi
				return 0
				;;
			R)
				message "User chose to renew with certbot."
				cert_source="certbot-renew"
				;;
			O)
				message "User chose to obtain new certificate with certbot."
				cert_source="certbot-new"
				;;
			S)
				message "User chose to skip SSL installation."
				SSL_STATUS="Skipped: user chose to skip SSL"
				return 0
				;;
			*)
				message "Unrecognised choice '$choice'; defaulting to use existing."
				if [[ "$found_certbot" == true ]]; then
					if ! _install_certs_from_dir "$certbot_dir"; then
						SSL_STATUS="FAILED: could not copy certbot certificate to /etc/asterisk/ssl/"
						return 1
					fi
					SSL_STATUS="Installed: existing certbot certificate for $FQDN (certs in /etc/asterisk/ssl)"
				else
					SSL_STATUS="Installed: existing certificate in /etc/asterisk/ssl/ (no changes made)"
				fi
				return 0
				;;
		esac
	else
		# No existing cert found — go straight to obtaining a new one
		cert_source="certbot-new"
	fi

	# ---------------------------------------------------------------
	# At this point we need to run certbot (new or renew).
	# An email address is required.
	# ---------------------------------------------------------------
	if [[ -z "$SSL_EMAIL" ]]; then
		message "ERROR: certbot requires an email address but SSL_EMAIL is not set."
		message "Re-run with --email <addr> or provide one when prompted."
		SSL_STATUS="FAILED: no email address supplied for certbot"
		return 1
	fi

	# Install certbot if not present
	if ! command -v certbot >/dev/null 2>&1; then
		message "certbot not found; installing via apt..."
		local cb_out
		cb_out=$(apt-get install -y certbot 2>&1)
		local cb_rc=$?
		if [[ $cb_rc -ne 0 ]]; then
			message "ERROR: Failed to install certbot (exit $cb_rc)."
			message "apt output: $cb_out"
			echo "ERROR: Failed to install certbot:" >&2
			echo "$cb_out" >&2
			SSL_STATUS="FAILED: could not install certbot"
			return 1
		fi
		message "certbot installed successfully."
	else
		message "certbot already installed at $(command -v certbot)."
	fi

	# Stop apache2 for standalone challenge
	_stop_apache2

	# Run certbot
	# --key-type rsa --rsa-key-size 2048 are mandatory: recent certbot versions default to ECDSA,
	# which causes Asterisk/FreePBX to crash (core dump) every ~60 s when MS Teams pings the SBC.
	# MS Teams Direct Routing requires RSA certificates; ECDSA is not supported.
	local cb_cmd_out cb_cmd_rc
	if [[ "$cert_source" == "certbot-renew" ]]; then
		message "Renewing RSA certificate with certbot for $FQDN (key-type rsa, 2048-bit)..."
		cb_cmd_out=$(certbot renew --cert-name "$FQDN" --non-interactive \
			--key-type rsa --rsa-key-size 2048 2>&1)
		cb_cmd_rc=$?
	else
		message "Obtaining new RSA certificate with certbot for $FQDN (email: $SSL_EMAIL, key-type rsa, 2048-bit)..."
		cb_cmd_out=$(certbot certonly --standalone --non-interactive --agree-tos \
			--key-type rsa --rsa-key-size 2048 \
			--email "$SSL_EMAIL" -d "$FQDN" 2>&1)
		cb_cmd_rc=$?
	fi

	# Always show certbot output so the user can see rate-limit or other errors
	echo "$cb_cmd_out"
	message "certbot output: $cb_cmd_out"

	_restart_apache2

	if [[ $cb_cmd_rc -ne 0 ]]; then
		message "ERROR: certbot failed (exit $cb_cmd_rc) for $FQDN."
		echo ""
		echo "ERROR: certbot failed. Full output shown above."
		echo "Common causes:"
		echo "  - Let's Encrypt rate limits (too many certificates issued for this domain recently)"
		echo "    See: https://letsencrypt.org/docs/rate-limits/"
		echo "  - Port 80 is blocked or already in use"
		echo "  - FQDN ($FQDN) does not resolve to this server's public IP"
		echo ""
		echo "Tip: If you already have a valid certificate, re-run with --use-existing-cert"
		SSL_STATUS="FAILED: certbot certificate issuance/renewal failed for $FQDN"
		return 1
	fi

	# Copy the freshly issued cert into /etc/asterisk/ssl/
	if ! _install_certs_from_dir "${certbot_dir}"; then
		SSL_STATUS="FAILED: certbot succeeded but could not copy certificates to /etc/asterisk/ssl/"
		return 1
	fi

	message "Let's Encrypt SSL installation completed successfully for $FQDN."
	SSL_STATUS="Installed: Let's Encrypt (certbot) certificate for $FQDN (certs in /etc/asterisk/ssl)"
}

# Apply MS Teams ms_signaling_address runtime patch to Asterisk PJSIP NAT sources
get_ms_teams_patch_for_version() {
		local ver="$1"
		local patch_path

		patch_path="${AST_PATCH_DIR}/asterisk-${ver}-ms-teams-ms_signaling_address-8ee0332.patch"

		if [[ -f "$patch_path" ]]; then
				echo "$patch_path"
				return 0
		fi

		message "ERROR: No MS Teams ms_signaling_address patch file found for Asterisk version '$ver' at '$patch_path'"
		message "Supported Asterisk versions for this script: $SUPPORTED_AST_VERSIONS"
		return 1
}

apply_ms_teams_runtime_patch() {
		local src_dir="$1"
		local ast_version="$2"
		local patch_file

		if [[ -z "$src_dir" || ! -d "$src_dir" ]]; then
				message "ERROR: apply_ms_teams_runtime_patch called with invalid source directory '$src_dir'"
				return 1
		fi

		if [[ -z "$ast_version" ]]; then
				message "ERROR: apply_ms_teams_runtime_patch called without Asterisk version."
				return 1
		fi

		if ! patch_file="$(get_ms_teams_patch_for_version "$ast_version")"; then
				return 1
		fi

		if ! command -v patch >/dev/null 2>&1; then
				message "patch utility not found; installing via apt-get..."
				if ! apt-get update || ! apt-get install -y patch; then
						message "ERROR: Failed to install 'patch' package."
						return 1
				fi
		fi

		message "Testing application of MS Teams ms_signaling_address runtime patch for Asterisk ${ast_version} (file: ${patch_file})..."
		local patch_output
		if patch_output=$(cd "$src_dir" && patch --dry-run -p1 < "$patch_file" 2>&1); then
				message "MS Teams ms_signaling_address runtime patch applies cleanly; proceeding with application..."
				if ! ( cd "$src_dir" && patch -p1 < "$patch_file" ); then
						message "ERROR: Failed to apply ms_signaling_address runtime patch in $src_dir."
						return 1
				fi
		elif ( cd "$src_dir" && patch -R --dry-run -p1 < "$patch_file" >/dev/null 2>&1 ); then
				message "MS Teams ms_signaling_address runtime patch already applied in $src_dir; skipping."
		else
				message "ERROR: ms_signaling_address runtime patch does not apply cleanly to sources in $src_dir."
				message "Patch file: $patch_file"
				message "Asterisk version: $ast_version"
				message "Patch output:"
				echo "$patch_output" | tee -a "$log"
				message "Ensure you are building a supported Asterisk version: $SUPPORTED_AST_VERSIONS"
				return 1
		fi

		message "MS Teams ms_signaling_address runtime patch is present and up to date."
		return 0
}

#Compile custom Asterisk with PJSIP NAT module and load
build_msteams() {
        ASTVERSION=$1
        SRCDIR="/usr/src"

        checkfqdn
	
	        # Clean up any previous Asterisk source tree for this version to make the script idempotent
	        local prev_src_dirs=("$SRCDIR"/asterisk-"${ASTVERSION}".*)
	        if [[ -e "${prev_src_dirs[0]}" ]]; then
	                message "Removing existing Asterisk source tree(s) in $SRCDIR/asterisk-${ASTVERSION}.* for clean rebuild..."
	                rm -rf "$SRCDIR"/asterisk-"${ASTVERSION}".*
	        fi
	
	        # Get source
	        cd "$SRCDIR" \
	                || { message "ERROR: Source directory does not exist: $SRCDIR"; terminate 1; }
	        TARBALL="asterisk-${ASTVERSION}-current.tar.gz"
	        local tarball_url="https://downloads.asterisk.org/pub/telephony/asterisk/${TARBALL}"

	        # Prefer an exact-version source tarball so compiled modules match the running binary.
	        # Building from -current produces modules from whatever the latest minor release is
	        # (e.g. 22.9.x), which may differ from the running Asterisk binary (e.g. 22.8.2).
	        # Asterisk's module version check rejects modules reporting a different version at load
	        # time, causing a silent crash/bootloop at PJSIP transport initialisation.
	        # The regex captures four-part security release versions (e.g. 22.8.2.1) as well as
	        # the standard three-part form — previously [0-9]+\.[0-9]+\.[0-9]+ would truncate
	        # 22.8.2.1 to 22.8.2, probing a tarball that doesn't exist for that release.
	        local ast_full_version
	        ast_full_version=$(asterisk -V 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)
	        if [[ -n "$ast_full_version" ]]; then
	                local exact_tarball_url="https://downloads.asterisk.org/pub/telephony/asterisk/releases/asterisk-${ast_full_version}.tar.gz"
	                message "Checking for exact-version source tarball for Asterisk ${ast_full_version}..."

	                if [[ -f "$SRCDIR/asterisk-${ast_full_version}.tar.gz" ]]; then
	                        # Disk cache hit — use it directly without a network probe.
	                        # This also handles offline re-runs where the tarball was downloaded
	                        # previously but the network probe would now fail (fix: re-run regression).
	                        TARBALL="asterisk-${ast_full_version}.tar.gz"
	                        tarball_url="$exact_tarball_url"
	                        message "Found cached exact-version tarball: ${TARBALL}."
	                        message "Built modules will match the running Asterisk ${ast_full_version} binary exactly."
	                elif wget -q -P "$SRCDIR" "$exact_tarball_url" 2>/dev/null \
	                     && [[ -s "$SRCDIR/asterisk-${ast_full_version}.tar.gz" ]]; then
	                        # Direct download attempt — avoids a HEAD probe (some servers return
	                        # 405 Method Not Allowed for HEAD even when GET succeeds, causing the
	                        # old curl -fsI probe to produce a false negative; fix: HEAD replaced).
	                        TARBALL="asterisk-${ast_full_version}.tar.gz"
	                        tarball_url="$exact_tarball_url"
	                        message "Downloaded exact-version tarball: ${TARBALL}."
	                        message "Built modules will match the running Asterisk ${ast_full_version} binary exactly."
	                else
	                        rm -f "$SRCDIR/asterisk-${ast_full_version}.tar.gz"  # remove any partial download
	                        message "WARNING: Exact-version tarball not available for Asterisk ${ast_full_version}."
	                        message "Falling back to ${TARBALL} (current release)."
	                        message "Built modules may be from a different minor version than the running binary."
	                        message "This can cause Asterisk's module version check to reject them at load time."
	                fi
	        else
	                message "WARNING: Could not detect running Asterisk version — using ${TARBALL} (current)."
	        fi

	        if [[ -f "$SRCDIR/$TARBALL" ]]; then
	                message "Found existing Asterisk tarball: $TARBALL (skipping download)"
	        else
	                message "Downloading Asterisk source code tarball..."
	                # Guard wget: previously an unhandled failure here let the script continue
	                # to tar -xzf on a missing file, producing a confusing tar error (fix: wget guard).
	                wget -P "$SRCDIR" "$tarball_url" \
	                        || { message "ERROR: Failed to download Asterisk source tarball: $tarball_url"; terminate 1; }
	        fi

	        # Extract the tarball
	        message "Extracting Asterisk source tarball..."
		        tar -xzf "$SRCDIR/$TARBALL"
	
		        # Resolve the extracted source directory explicitly — passing $PWD after a
		        # glob-based cd is fragile: if the glob fails to match (e.g. directory name
		        # doesn't fit asterisk-${ASTVERSION}.*), cd silently stays in $SRCDIR and
		        # apply_ms_teams_runtime_patch receives /usr/src instead of the subdirectory,
		        # causing "can't find file to patch" errors.
		        local extracted_src_dir
		        extracted_src_dir=$(find "$SRCDIR" -maxdepth 1 -mindepth 1 -type d \
		                -name "asterisk-${ASTVERSION}.*" | sort -V | tail -1)
		        if [[ -z "$extracted_src_dir" || ! -d "$extracted_src_dir" ]]; then
		                message "ERROR: Could not find extracted Asterisk source directory"
		                message "  Expected: $SRCDIR/asterisk-${ASTVERSION}.*"
		                message "  Ensure the tarball extracted correctly."
		                terminate 1
		        fi
		        cd "$extracted_src_dir" \
		                || { message "ERROR: Cannot enter source directory: $extracted_src_dir"; terminate 1; }

	        # Apply MS Teams runtime FQDN patch BEFORE installing prerequisites.
	        # Fail fast: no point spending time on install_prereq if the patch is missing or broken.
	        if ! apply_ms_teams_runtime_patch "$extracted_src_dir" "$ASTVERSION"; then
	                message "ERROR: Failed to apply MS Teams runtime patch to Asterisk sources."
	                terminate 1
	        fi

        # Install dependencies
        message "Installing dependencies..."
        contrib/scripts/install_prereq install

	        # Configure Asterisk with default module set
        message "Configuring Asterisk with default menuselect options..."
        ./configure

        # Compile Asterisk (using default menuselect options)
        message "Compile Asterisk"
        make

        # Deploy the full patched PJSIP module set to the FreePBX Asterisk modules directory.
        # NOTE: 'make install' is intentionally NOT run here. FreePBX owns the running Asterisk
        # installation; running 'make install' would overwrite FreePBX-managed Asterisk binaries
        # and configuration files.
        #
        # WHY the full set must be replaced:
        # Every module that #includes res_pjsip.h (res_pjsip*.so and chan_pjsip.so) bakes in the
        # same internal struct layouts at compile time.  The ms_signaling_address patch modifies
        # those structs; leaving any old module in place alongside the new ones causes immediate
        # Asterisk crashes or silent memory corruption.
        local modules_dir
        modules_dir=$(get_asterisk_module_dir)

        # Collect all PJSIP modules produced by this build:
        #   res/res_pjsip*.so  — PJSIP core and all supplementary res_pjsip modules
        #   channels/chan_pjsip.so — SIP channel driver (also links against res_pjsip.h)
        local -a pjsip_build_sos=()
        while IFS= read -r -d '' so_file; do
                pjsip_build_sos+=("$so_file")
        done < <(find "res" -maxdepth 1 -name "res_pjsip*.so" -print0 2>/dev/null | sort -z)
        if [[ -f "channels/chan_pjsip.so" ]]; then
                pjsip_build_sos+=("channels/chan_pjsip.so")
        fi

        if [[ ${#pjsip_build_sos[@]} -eq 0 ]]; then
                message "ERROR: No PJSIP modules found in build output under res/ and channels/."
                message "Ensure the build completed successfully (make)."
                terminate 1
        fi

        # Pre-deploy ABI version check — mirrors downloadonly()'s ABI verification.
        # When the -current tarball was used as a fallback the built modules may report a
        # different version than the running Asterisk binary, causing the module loader to
        # reject them at startup.  Check before any files are overwritten so the user can
        # abort cleanly (fix: no post-build version verification).
        if [[ -n "$ast_full_version" ]]; then
                message "Verifying built modules match running Asterisk ${ast_full_version}..."
                local build_ver_ok=true
                for abi_mod in "res/res_pjsip.so" "res/res_pjsip_nat.so"; do
                        if [[ -f "$abi_mod" ]]; then
                                local embedded
                                embedded=$(strings "$abi_mod" 2>/dev/null | grep -F "$ast_full_version" | head -1)
                                if [[ -n "$embedded" ]]; then
                                        message "  $(basename "$abi_mod"): version string '${ast_full_version}' found — OK"
                                else
                                        message "  WARNING: $(basename "$abi_mod"): version string '${ast_full_version}' NOT found."
                                        build_ver_ok=false
                                fi
                        fi
                done
                if [[ "$build_ver_ok" == false ]]; then
                        message ""
                        message "WARNING: Built modules do not match the running Asterisk ${ast_full_version}."
                        message "This happens when the exact-version tarball was unavailable and -current was used."
                        message "Asterisk may reject the modules at load time, causing a crash/bootloop."
                        message ""
                        echo -n "Deploy anyway? (y/n) [n]: "
                        local confirm_build_mismatch
                        read -r confirm_build_mismatch
                        if [[ ! "$confirm_build_mismatch" =~ ^[Yy]$ ]]; then
                                message "Aborting. No modules have been deployed."
                                terminate 1
                        fi
                        message "User confirmed: deploying version-mismatched modules."
                else
                        message "Built module versions verified — match running Asterisk ${ast_full_version}."
                fi
        fi

        message "Deploying full PJSIP module set to: $modules_dir"
        message "Modules collected from build output (${#pjsip_build_sos[@]}):"
        for so_path in "${pjsip_build_sos[@]}"; do
                message "  $(basename "$so_path")"
        done
        message "All listed modules link against res_pjsip.h and are deployed as a complete set."

        local deploy_count=0
        for built_so in "${pjsip_build_sos[@]}"; do
                local mod
                mod=$(basename "$built_so")

                # Guard: ensure make produced the expected file
                if [[ ! -f "$built_so" ]]; then
                        message "ERROR: Built module not found at expected path: $built_so"
                        message "Ensure the build completed successfully (make)."
                        terminate 1
                fi

                # One-time .ORIG backup — never overwrite an existing backup so the original
                # system modules are always preserved for --restore
                if [[ -f "$modules_dir/${mod}" && ! -f "$modules_dir/${mod}.ORIG" ]]; then
                        mv "$modules_dir/${mod}" "$modules_dir/${mod}.ORIG"
                        message "  Backed up original: ${mod}.ORIG"
                elif [[ -f "$modules_dir/${mod}.ORIG" ]]; then
                        message "  .ORIG already exists for ${mod}; leaving existing backup in place."
                fi

                cp -v "$built_so" "$modules_dir/${mod}"
                cp -v "$built_so" "$modules_dir/${mod}.MSTEAMS"
                message "  Deployed: ${mod}"
                (( deploy_count++ ))
        done
        message "Deployed ${deploy_count} PJSIP module(s) to ${modules_dir}."

        # Post-deploy verification: confirm ms_signaling_address is present in the two
        # modules that contain the patch (res_pjsip.so and res_pjsip_nat.so).
        # Other PJSIP modules don't embed ms_signaling_address but are verified by count above.
        message "Verifying patched modules contain ms_signaling_address..."
        local verify_failed=false
        for mod in res_pjsip.so res_pjsip_nat.so; do
                if strings "$modules_dir/${mod}" 2>/dev/null | grep -q "ms_signaling_address"; then
                        message "  OK: ms_signaling_address found in $modules_dir/${mod}"
                else
                        message "  ERROR: ms_signaling_address NOT found in $modules_dir/${mod}"
                        message "  The patch may not have been applied correctly."
                        verify_failed=true
                fi
        done
        if [[ "$verify_failed" == true ]]; then
                message "ERROR: Module verification failed. Patched modules do not appear to be installed correctly."
                terminate 1
        fi

        message "MSTeams patched PJSIP module set (${deploy_count} modules) deployed successfully."
        message ""
        message "IMPORTANT: A full Asterisk/FreePBX restart is required to activate the patched modules."
        message "  Do NOT attempt to hot-reload res_pjsip.so — it must be restarted cleanly."
        message "  Run: fwconsole restart"

        if [[ "$SKIP_SSL" == true ]]; then
                message "Skipping Let's Encrypt SSL installation (--no-ssl specified)."
                SSL_STATUS="Skipped: --no-ssl/--skip-ssl specified; SSL not installed"
        else
                install_letsencrypt
        fi
}

create_asterisk_systemd_service() {
	        local unit_file="/etc/systemd/system/asterisk.service"

	        message "Writing systemd unit file to ${unit_file}"
	        cat > "${unit_file}" <<EOF
[Unit]
Description=Asterisk PBX
After=network.target

[Service]
Type=simple
ExecStart=${ASTERISK_PREFIX}/sbin/asterisk -f -vvv
ExecStop=${ASTERISK_PREFIX}/sbin/asterisk -rx 'core stop now'
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

	        ASTERISK_SERVICE_CREATED=true

	        if command -v systemctl >/dev/null 2>&1; then
	                systemctl daemon-reload || true
	                systemctl enable asterisk || true
	                ASTERISK_SERVICE_ENABLED=true
	        else
	                message "systemctl not found; please enable asterisk.service manually if desired."
	        fi
}

build_asterisk_only() {
	        ASTVERSION=$1
	        SRCDIR="/usr/src"

	        checkfqdn
	
	        # Clean up any previous Asterisk source tree for this version to make the script idempotent
	        local prev_src_dirs=("$SRCDIR"/asterisk-"${ASTVERSION}".*)
	        if [[ -e "${prev_src_dirs[0]}" ]]; then
	                message "Removing existing Asterisk source tree(s) in $SRCDIR/asterisk-${ASTVERSION}.* for clean rebuild..."
	                rm -rf "$SRCDIR"/asterisk-"${ASTVERSION}".*
	        fi
	
	        cd "$SRCDIR" \
	                || { message "ERROR: Source directory does not exist: $SRCDIR"; terminate 1; }
	        TARBALL="asterisk-${ASTVERSION}-current.tar.gz"

	        if [[ -f "$SRCDIR/$TARBALL" ]]; then
	                message "Found existing Asterisk tarball: $TARBALL (skipping download)"
	        else
	                message "Downloading Asterisk source code tarball for standalone install..."
	                wget -P "$SRCDIR" "https://downloads.asterisk.org/pub/telephony/asterisk/${TARBALL}"
	        fi

	        message "Extracting Asterisk source tarball..."
	        tar -xzf "$SRCDIR/$TARBALL"
	
	        # Resolve the extracted source directory explicitly — same pattern as build_msteams().
	        # A glob-based cd silently stays in $SRCDIR when the pattern fails to match,
	        # causing apply_ms_teams_runtime_patch to receive /usr/src instead of the source tree.
	        local extracted_src_dir
	        extracted_src_dir=$(find "$SRCDIR" -maxdepth 1 -mindepth 1 -type d \
	                -name "asterisk-${ASTVERSION}.*" | sort -V | tail -1)
	        if [[ -z "$extracted_src_dir" || ! -d "$extracted_src_dir" ]]; then
	                message "ERROR: Could not find extracted Asterisk source directory"
	                message "  Expected: $SRCDIR/asterisk-${ASTVERSION}.*"
	                message "  Ensure the tarball extracted correctly."
	                terminate 1
	        fi
	        cd "$extracted_src_dir" \
	                || { message "ERROR: Cannot enter source directory: $extracted_src_dir"; terminate 1; }

	        message "Installing dependencies for standalone Asterisk build..."
	        contrib/scripts/install_prereq install

	        # Prompt for installation prefix
	        local prefix_input
		echo -n "Enter installation prefix [/usr (Debian standard)]: "
		read prefix_input
	        if [[ -z "$prefix_input" ]]; then
	                ASTERISK_PREFIX="/usr"
	                ASTERISK_SYSCONFDIR="/etc"
	                ASTERISK_LOCALSTATEDIR="/var"
	        else
	                ASTERISK_PREFIX="$prefix_input"
	                ASTERISK_SYSCONFDIR="${ASTERISK_PREFIX}/etc"
	                ASTERISK_LOCALSTATEDIR="${ASTERISK_PREFIX}/var"
	        fi

	        message "Using installation prefix: $ASTERISK_PREFIX"
	        message "Configuration base directory: $ASTERISK_SYSCONFDIR"
	        message "Local state base directory: $ASTERISK_LOCALSTATEDIR"

		# Apply MS Teams runtime FQDN patch (ms_signaling_address) to PJSIP NAT
		if ! apply_ms_teams_runtime_patch "$extracted_src_dir" "$ASTVERSION"; then
		        message "ERROR: Failed to apply MS Teams runtime patch to Asterisk sources (standalone install)."
		        terminate 1
		fi

		message "Configuring Asterisk for standalone install..."
	        ./configure --prefix="$ASTERISK_PREFIX" --sysconfdir="$ASTERISK_SYSCONFDIR" --localstatedir="$ASTERISK_LOCALSTATEDIR"

	        message "Compiling Asterisk (standalone)..."
	        make

	        message "Installing Asterisk (make install)..."
	        make install

	        # Systemd service prompt
	        local svc_reply
		echo -n "Create and enable systemd service for Asterisk? (y/n) [y]: "
		read svc_reply
	        if [[ -z "$svc_reply" || "$svc_reply" =~ ^[Yy] ]]; then
	                message "Creating and enabling systemd service for Asterisk..."
	                create_asterisk_systemd_service
	        else
	                message "Skipping systemd service creation."
	        fi

	        # Sample configs prompt
	        local samples_reply
		echo -n "Install sample Asterisk configuration files? (y/n) [n]: "
		read samples_reply
	        if [[ "$samples_reply" =~ ^[Yy] ]]; then
	                message "Installing Asterisk sample configuration files (make samples)..."
	                make samples
	                ASTERISK_SAMPLES_INSTALLED=true
	        else
	                message "Skipping installation of sample configuration files."
	                ASTERISK_SAMPLES_INSTALLED=false
	        fi

	        if [[ "$SKIP_SSL" == true ]]; then
	                message "Skipping Let's Encrypt SSL installation (--no-ssl specified)."
	                SSL_STATUS="Skipped: --no-ssl/--skip-ssl specified; SSL not installed"
	        else
	                install_letsencrypt
	        fi
}

# Check TLS certificate suitability for MS Teams Direct Routing
check_tls_cert() {
	local fqdn="${1:-$FQDN}"
	local cert_path=""

	if [[ -f "/etc/letsencrypt/live/${fqdn}/cert.pem" ]]; then
		cert_path="/etc/letsencrypt/live/${fqdn}/cert.pem"
	else
		cert_path=$(find /etc/letsencrypt/live/ -name "cert.pem" 2>/dev/null | head -1)
	fi

	message ""
	message "TLS Certificate Check (MS Teams Direct Routing requires RSA):"
	if [[ -z "$cert_path" ]]; then
		message "  WARNING: No certificate found at /etc/letsencrypt/live/${fqdn}/"
		message "  Obtain an RSA certificate with:"
		message "    certbot certonly --key-type rsa --rsa-key-size 2048 -d ${fqdn}"
		return
	fi

	local cert_dir
	cert_dir=$(dirname "$cert_path")
	message "  Certificate: ${cert_path}"

	# Key algorithm — MS Teams only supports RSA
	local key_alg
	key_alg=$(openssl x509 -in "$cert_path" -noout -text 2>/dev/null | grep "Public Key Algorithm" | awk '{print $NF}')
	if [[ "$key_alg" == *"rsaEncryption"* ]]; then
		message "  Key algorithm:  RSA  [OK]"
	else
		message "  WARNING: Key algorithm is '${key_alg}' — MS Teams requires RSA, not ECDSA."
		message "  Replace with: certbot certonly --key-type rsa --rsa-key-size 2048 -d ${fqdn}"
	fi

	# Expiry
	local expiry days_left now_epoch expiry_epoch
	expiry=$(openssl x509 -in "$cert_path" -noout -enddate 2>/dev/null | cut -d= -f2)
	expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || echo 0)
	now_epoch=$(date +%s)
	days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
	if [[ "$days_left" -lt 30 ]]; then
		message "  WARNING: Certificate expires in ${days_left} days (${expiry})"
	else
		message "  Expires: ${expiry}  (${days_left} days remaining)  [OK]"
	fi

	# CN vs FQDN
	local cn
	cn=$(openssl x509 -in "$cert_path" -noout -subject 2>/dev/null | sed 's/.*CN\s*=\s*//' | cut -d/ -f1 | tr -d ' ')
	message "  Common Name:    ${cn}"
	if [[ "$cn" != "$fqdn" && "$cn" != "*."* ]]; then
		message "  WARNING: Certificate CN '${cn}' does not match FQDN '${fqdn}'."
		message "  ms_signaling_address must match the certificate CN."
	fi

	message "  Paths for pjsip.conf transport stanza:"
	message "    cert_file=${cert_dir}/fullchain.pem"
	message "    priv_key_file=${cert_dir}/privkey.pem"
	message "    method=tlsv1_2"
}

print_asterisk_only_summary() {
	        local config_dir modules_dir fqdn_display PUBLIC_IPV4
	        fqdn_display="${CLI_FQDN:-$FQDN}"
	        message "Fetching public IPv4 address..."
	        PUBLIC_IPV4=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || true)
	        if [[ -z "$PUBLIC_IPV4" ]]; then
	                message "WARNING: Could not determine public IPv4 address; using placeholder."
	                PUBLIC_IPV4="YOUR.PUBLIC.IP"
	        else
	                message "Detected public IPv4: $PUBLIC_IPV4"
	        fi

	        if [[ -n "$ASTERISK_SYSCONFDIR" ]]; then
	                config_dir="${ASTERISK_SYSCONFDIR}/asterisk"
	        else
	                config_dir="/etc/asterisk"
	        fi

	        if [[ -n "$ASTERISK_PREFIX" ]]; then
	                modules_dir="${ASTERISK_PREFIX}/lib/asterisk/modules"
	        else
	                modules_dir="/usr/lib/asterisk/modules"
	        fi

	        message "Asterisk standalone installation summary:"
	        message "  - Asterisk version installed: ${ASTVERSION}"
	        message "  - Installation prefix: ${ASTERISK_PREFIX:-/usr}"
	        message "  - Configuration directory: ${config_dir}"
	        message "  - Module directory (expected): ${modules_dir}"
	        message "  - Systemd service created: ${ASTERISK_SERVICE_CREATED}"
	        message "  - Systemd service enabled: ${ASTERISK_SERVICE_ENABLED}"
		message "  - Sample configuration files installed: ${ASTERISK_SAMPLES_INSTALLED}"
		message "  - Recommended PJSIP transport ms_signaling_address FQDN: ${fqdn_display}"
	        message "  - Let's Encrypt SSL: ${SSL_STATUS}"
	        if [[ "$SSL_STATUS" == Installed:* ]]; then
	                message "    - Full chain certificate: /etc/asterisk/ssl/cert.crt"
	                message "    - CA certificate:         /etc/asterisk/ssl/ca.crt"
	                message "    - Private key:            /etc/asterisk/ssl/privkey.crt"
	                message "    - Certificate renewed automatically by certbot"
	        fi
	        check_tls_cert "$fqdn_display"
	        message ""
	        if command -v fwconsole &>/dev/null; then
	                local pjsip_conf_note="/etc/asterisk/pjsip.transports_custom.conf (FreePBX custom file — do NOT edit pjsip.conf directly)"
	                local pjsip_conf_file="/etc/asterisk/pjsip.transports_custom.conf"
	        else
	                local pjsip_conf_note="${config_dir}/pjsip.conf"
	                local pjsip_conf_file="${config_dir}/pjsip.conf"
	        fi
	        message "PJSIP transport configuration for MS Teams Direct Routing:"
	        message "  Add the following transport block to: ${pjsip_conf_note}"
	        message ""
	        message "  [transport-ms-teams]"
	        message "  type=transport"
	        message "  protocol=tls"
	        message "  bind=0.0.0.0:5061"
	        message "  cert_file=/etc/letsencrypt/live/${fqdn_display}/fullchain.pem"
	        message "  priv_key_file=/etc/letsencrypt/live/${fqdn_display}/privkey.pem"
	        message "  method=tlsv1_2"
	        message "  external_signaling_address=${PUBLIC_IPV4}    ; Public IP address of your SBC"
	        message "  external_signaling_port=5061                 ; External SIP TLS port"
	        message "  ms_signaling_address=${fqdn_display}         ; FQDN hostname — must match cert CN"
	        message ""
	        message "  IMPORTANT: ms_signaling_address must be a FQDN (not an IP) matching your cert CN."
	        message "  cert_file MUST use fullchain.pem (leaf cert + intermediates) — NOT cert.pem."
	        message "  Using cert.pem (leaf only) causes TLS handshake failures: MS Teams cannot"
	        message "  verify the chain and drops the connection silently or with a TLS timeout."
	        message "  MS Teams requires RSA certificates — ECDSA is not supported."
	        message ""
	        message "TLS troubleshooting:"
	        message "  If Teams connections fail or time out on port 5061, capture SIP/TLS traffic:"
	        message "    apt install sngrep && sngrep port 5061"
	        message "  Incomplete TLS handshakes (TCP connects but no SIP messages appear) indicate"
	        message "  Teams dropped the connection during the TLS exchange. The two most common causes:"
	        message "  (1) cert_file points to cert.pem instead of fullchain.pem — MS Teams cannot"
	        message "      verify the intermediate CA chain and silently drops the connection."
	        message "  (2) An ECDSA certificate is presented instead of RSA."
	        message "  Correct cert_file to fullchain.pem and restart Asterisk, then recheck with sngrep."
	        message ""
	        message "Next steps:"
	        message "  1. Review and customise your Asterisk configuration in ${config_dir}"
	        message "  2. REQUIRED: Configure ms_signaling_address hostname in ${pjsip_conf_file} as shown above"
	        message "  3. Start Asterisk with: systemctl start asterisk   (if systemd service was created)"
	        message "  4. Reload PJSIP after config changes: asterisk -rx 'pjsip reload'"
}

print_freepbx_summary() {
	        local modules_dir fqdn_display PUBLIC_IPV4
	        modules_dir=$(get_asterisk_module_dir)
	        fqdn_display="${CLI_FQDN:-$FQDN}"
	        message "Fetching public IPv4 address..."
	        PUBLIC_IPV4=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || true)
	        if [[ -z "$PUBLIC_IPV4" ]]; then
	                message "WARNING: Could not determine public IPv4 address; using placeholder."
	                PUBLIC_IPV4="YOUR.PUBLIC.IP"
	        else
	                message "Detected public IPv4: $PUBLIC_IPV4"
	        fi

	        message "MSTeams-FreePBX installation summary:"
	        message "  - Host: ${host}"
	        message "  - Asterisk version targeted: ${ASTVERSION}"
	        message "  - Recommended PJSIP transport ms_signaling_address FQDN: ${fqdn_display}"
	        message "  - FreePBX Asterisk modules directory: ${modules_dir}"
	        message "  - Active PJSIP core module:  ${modules_dir}/res_pjsip.so"
	        message "  - Active PJSIP NAT module:   ${modules_dir}/res_pjsip_nat.so"
	        message "  - Original backups (if present): res_pjsip.so.ORIG, res_pjsip_nat.so.ORIG"
	        if [[ "$SKIP_SSL" == true ]]; then
	                message "  - Let's Encrypt SSL: skipped (--no-ssl/--skip-ssl specified)"
	        else
		        message "  - Let's Encrypt SSL: ${SSL_STATUS}"
		        if [[ "$SSL_STATUS" == Installed:* ]]; then
		                message "    - Full chain certificate: /etc/asterisk/ssl/cert.crt"
		                message "    - CA certificate:         /etc/asterisk/ssl/ca.crt"
		                message "    - Private key:            /etc/asterisk/ssl/privkey.crt"
		                message "    - Certificate renewed automatically by certbot"
		        fi
	        fi
	        check_tls_cert "$fqdn_display"
	        message "  - Systemd services: existing FreePBX/Asterisk services were not modified by this script"
	        message ""
	        message "PJSIP transport configuration for MS Teams Direct Routing:"
	        message "  In FreePBX, add a custom PJSIP transport configuration file:"
	        message "  /etc/asterisk/pjsip.transports_custom.conf"
	        message ""
	        message "  [transport-ms-teams]"
	        message "  type=transport"
	        message "  protocol=tls"
	        message "  bind=0.0.0.0:5061"
	        message "  cert_file=/etc/letsencrypt/live/${fqdn_display}/fullchain.pem"
	        message "  priv_key_file=/etc/letsencrypt/live/${fqdn_display}/privkey.pem"
	        message "  method=tlsv1_2"
	        message "  external_signaling_address=${PUBLIC_IPV4}    ; Public IP address of your SBC"
	        message "  external_signaling_port=5061                 ; External SIP TLS port"
	        message "  ms_signaling_address=${fqdn_display}         ; FQDN hostname — must match cert CN"
	        message ""
	        message "  IMPORTANT: ms_signaling_address must be a FQDN (not an IP) matching your cert CN."
	        message "  cert_file MUST use fullchain.pem (leaf cert + intermediates) — NOT cert.pem."
	        message "  Using cert.pem (leaf only) causes TLS handshake failures: MS Teams cannot"
	        message "  verify the chain and drops the connection silently or with a TLS timeout."
	        message "  MS Teams requires RSA certificates — ECDSA is not supported."
	        message ""
	        message "TLS troubleshooting:"
	        message "  If Teams connections fail or time out on port 5061, capture SIP/TLS traffic:"
	        message "    apt install sngrep && sngrep port 5061"
	        message "  Incomplete TLS handshakes (TCP connects but no SIP messages appear) indicate"
	        message "  Teams dropped the connection during the TLS exchange. The two most common causes:"
	        message "  (1) cert_file points to cert.pem instead of fullchain.pem — MS Teams cannot"
	        message "      verify the intermediate CA chain and silently drops the connection."
	        message "  (2) An ECDSA certificate is presented instead of RSA."
	        message "  Correct cert_file to fullchain.pem and restart Asterisk, then recheck with sngrep."
	        message ""
	        message "Next steps:"
	        message "  1. REQUIRED: Configure ms_signaling_address hostname in /etc/asterisk/pjsip.transports_custom.conf as shown above"
	        message "  2. Restart FreePBX services: fwconsole restart"
	        message "  3. Verify PJSIP transport loaded: asterisk -rx 'pjsip show transports'"
	}

##START RUN
host=$(hostname)
pidfile='/var/run/MSTEAMS-FreePBX-Install.pid'

if [[ -f "$pidfile" ]]; then
	        message "MSTeams-FreePBX-Install process is already running or a stale pidfile exists: $pidfile"
	        message "If this may be due to unclean termination then delete $pidfile and run MSTeams-FreePBX-Install.sh again."
	        exit 1
fi

start=$(date +%s.%N)
message "  Start MSTeams-FreePBX-Install process for $host"
message "  Log file here $log"
touch "$pidfile"

trap 'cleanup' EXIT
trap 'terminate 130' INT
trap 'terminate 143' TERM

		# Determine Asterisk version to target
		DETECTED_VERSION=""
		if [[ -z "$ASTVERSION" ]]; then
		       DETECTED_VERSION=$(detect_asterisk_major || true)
		       if [[ -n "$DETECTED_VERSION" ]]; then
		               ASTVERSION="$DETECTED_VERSION"
		               message "Detected installed Asterisk major version: $ASTVERSION"
		       else
		               ASTVERSION="$ASTVERSION_DEFAULT"
		               message "Could not detect installed Asterisk version; falling back to default $ASTVERSION (LTS)"
		       fi
		fi

		# If version wasn't explicitly provided on the command line, use auto-detected/default version
		if [[ "$ASTVERSION_FROM_CLI" != true ]]; then
		       message "Asterisk versions supported by this script: $SUPPORTED_AST_VERSIONS"
		       message "Auto-detected/default Asterisk version: $ASTVERSION (use --version=<21|22|23> to override)"
		fi

		if ! is_supported_version "$ASTVERSION"; then
		       message "ERROR: Asterisk version '$ASTVERSION' is not supported. Supported versions: $SUPPORTED_AST_VERSIONS"
		       terminate
		fi

		message "Using Asterisk major version: $ASTVERSION"

		# Warn if --version was explicitly specified and doesn't match the running Asterisk major version.
		# Mismatched modules (e.g. built from Asterisk 21 source but deployed into a running Asterisk 22)
		# share incompatible internal structs and will cause crashes or load failures.
		# Only check for build modes — restore/copyback/downloadonly don't compile from source.
		if [[ "$ASTVERSION_FROM_CLI" == true && "$restore" != true && "$copyback" != true && "$downloadonly" != true ]]; then
			local _running_major
			_running_major=$(asterisk -V 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 | cut -d. -f1)
			if [[ -n "$_running_major" && "$_running_major" != "$ASTVERSION" ]]; then
				message ""
				message "ERROR: Version mismatch — --version=${ASTVERSION} was specified but the running"
				message "Asterisk reports major version ${_running_major} ($(asterisk -V 2>/dev/null | head -1))."
				message ""
				message "Modules built from Asterisk ${ASTVERSION} source cannot be safely deployed into"
				message "a running Asterisk ${_running_major} — internal structs differ between major versions."
				message ""
				message "Fix: use --version=${_running_major} (or omit --version to auto-detect)."
				terminate 1
			fi
		fi

		# Detect or use specified CPU architecture
		if [[ -z "$CPU_ARCH" ]]; then
		       CPU_ARCH=$(detect_cpu_arch || true)
		       if [[ -z "$CPU_ARCH" ]]; then
		               message "ERROR: Could not detect CPU architecture. Please specify using --arch=<arch>"
		               terminate
		       fi
		       message "Detected CPU architecture: $CPU_ARCH"

		       # Use dpkg to detect Debian architecture (most reliable for native system)
		       DEBIAN_ARCH=$(detect_debian_arch || true)
		       if [[ -z "$DEBIAN_ARCH" ]]; then
		               # Fallback to mapping from CPU architecture if dpkg is not available
		               DEBIAN_ARCH=$(map_to_debian_arch "$CPU_ARCH")
		               message "Debian architecture (mapped from CPU arch): $DEBIAN_ARCH"
		       else
		               message "Debian architecture (from dpkg): $DEBIAN_ARCH"
		       fi
		else
		       # Architecture was manually specified via --arch parameter
		       # User may have provided either kernel arch (x86_64, aarch64) or Debian arch (amd64, arm64)
		       message "Using specified architecture: $CPU_ARCH (from --arch parameter)"

		       # Map to Debian architecture (handles both kernel and Debian arch names)
		       DEBIAN_ARCH=$(map_to_debian_arch "$CPU_ARCH")

		       # If user provided a Debian arch name, we need to map back to kernel arch for CPU_ARCH
		       # Check if CPU_ARCH is a Debian arch name by seeing if mapping changed it
		       if [[ "$CPU_ARCH" == "$DEBIAN_ARCH" ]] && [[ "$CPU_ARCH" =~ ^(amd64|arm64|armhf|i386|ppc64el)$ ]]; then
		               # User provided Debian arch name, map to kernel arch for CPU_ARCH
		               local kernel_arch
		               kernel_arch=$(map_to_kernel_arch "$CPU_ARCH")
		               message "Detected Debian architecture name provided; mapping to kernel architecture"
		               message "  Debian architecture: $DEBIAN_ARCH"
		               message "  Kernel architecture: $kernel_arch"
		               CPU_ARCH="$kernel_arch"
		       else
		               message "Debian architecture: $DEBIAN_ARCH"
		       fi
		fi

		# Construct prebuilt base URL with detected/specified architecture.
		# Modules are organised in the repo by Debian release/arch, then major Asterisk version.
		# e.g. …/prebuilt/debian12-amd64/asterisk-22/res_pjsip.so
		PREBUILT_BASE_URL="https://github.com/Vince-0/MSTeams-PJSIPNAT/raw/main/prebuilt/debian12-${DEBIAN_ARCH}"

		# Check architecture support and warn if needed
		check_architecture_support "$CPU_ARCH"

		if [[ "$dryrun" == true ]]; then
	       local lib_path fqdn_display mode_desc ssl_desc
	       lib_path=$(get_lib_path)

	       # Get FQDN for display (used for SSL and ms_signaling_address examples)
	       if [[ "$restore" == true || "$copyback" == true || "$downloadonly" == true ]]; then
	           fqdn_display="N/A (not needed for this operation)"
	       else
	           if [[ -n "$CLI_FQDN" ]]; then
	               fqdn_display="$CLI_FQDN"
	           else
	               fqdn_display="$(hostname)"
	           fi
	       fi

	       # Determine operation mode description
	       if [[ "$ASTERISK_ONLY" == true ]]; then
	           mode_desc="--asterisk-only (Standalone Asterisk install, no FreePBX)"
	       elif [[ "$downloadonly" == true ]]; then
	           mode_desc="--downloadonly (download prebuilt full PJSIP module set from GitHub for Asterisk ${ASTVERSION} ${DEBIAN_ARCH})"
	       elif [[ "$restore" == true ]]; then
	           mode_desc="--restore (Restore original full PJSIP module set: res_pjsip*.so + chan_pjsip.so from .ORIG backups)"
	       elif [[ "$copyback" == true ]]; then
	           mode_desc="--copyback (Copy back MSTeams-patched full PJSIP module set: res_pjsip*.so + chan_pjsip.so from .MSTEAMS)"
	       else
	           mode_desc="FreePBX install + build patched full PJSIP module set (res_pjsip*.so + chan_pjsip.so) for MSTeams"
	       fi

	       # Determine SSL description, including any existing certificate detection
	       local ssl_cert_info=""
	       if [[ "$SKIP_SSL" == true ]]; then
	           ssl_desc="--no-ssl (SSL disabled - required for MSTeams Direct Routing)"
	       else
	           if [[ "$fqdn_display" != "N/A"* && -n "$fqdn_display" ]]; then
	               local _cb_dir="/etc/letsencrypt/live/${fqdn_display}"
	               local _ast_ssl="/etc/asterisk/ssl"
	               local _expiry
	               if [[ -f "${_cb_dir}/fullchain.pem" && -f "${_cb_dir}/privkey.pem" ]]; then
	                   _expiry=$(openssl x509 -enddate -noout -in "${_cb_dir}/fullchain.pem" 2>/dev/null | sed 's/notAfter=//')
	                   ssl_cert_info=" | Found certbot cert: ${_cb_dir} (expires: ${_expiry:-unknown})"
	               elif [[ -f "${_ast_ssl}/cert.crt" && -f "${_ast_ssl}/privkey.crt" ]]; then
	                   _expiry=$(openssl x509 -enddate -noout -in "${_ast_ssl}/cert.crt" 2>/dev/null | sed 's/notAfter=//')
	                   ssl_cert_info=" | Found existing cert: /etc/asterisk/ssl/ (expires: ${_expiry:-unknown})"
	               else
	                   ssl_cert_info=" | No existing cert found for ${fqdn_display}"
	               fi
	           fi
	           if [[ -n "$SSL_EMAIL" ]]; then
	               ssl_desc="--email=$SSL_EMAIL (SSL enabled)${ssl_cert_info}"
	           else
	               ssl_desc="Enabled (email will be requested)${ssl_cert_info}"
	           fi
	       fi

	       message "==================================================="
	       message "DRY-RUN: No changes will be made. Summary of planned actions:"
	       message "Operation mode: $mode_desc"
	       message "Asterisk: --version=$ASTVERSION"
	       message "Architecture: --arch=$DEBIAN_ARCH (CPU: $CPU_ARCH)"
	       message "Hostname: --fqdn=$fqdn_display"
	       message "Library path: --lib=$lib_path"
	       message "SSL: $ssl_desc"
	       message "==================================================="
	       if [[ "$ASTERISK_ONLY" == true ]]; then
	               tarurl="https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-${ASTVERSION}-current.tar.gz"
	               message "  Would download and extract: $tarurl"
	               message "  Would apply the MS Teams ms_signaling_address runtime patch to PJSIP sources."
	               message "  Would run ./configure with a chosen installation prefix (default: /usr, configs in /etc, data in /var)."
	               message "  Would run make && make install to install Asterisk into the chosen prefix."
	               message "  Would optionally create and enable a systemd service at /etc/systemd/system/asterisk.service."
	               message "  Would optionally install sample configuration files via 'make samples'."
	       elif [[ "$downloadonly" == true ]]; then
	               message "  Would detect the exact running Asterisk version (asterisk -V) for ABI verification."
	               message "  Would check for bundle URL in order: exact-version SHA256SUMS → major-version SHA256SUMS → legacy 2-module."
	               message "    — Exact-version:  ${PREBUILT_BASE_URL}/asterisk-<full-version>/SHA256SUMS"
	               message "    — Major-version:  ${PREBUILT_BASE_URL}/asterisk-${ASTVERSION}/SHA256SUMS"
	               message "    — Legacy bundles: warn that they cause crashes; require user confirmation."
	               message "  For full bundles: would download all modules listed in SHA256SUMS (~47 modules)."
	               message "  For legacy bundles: would download only res_pjsip.so + res_pjsip_nat.so."
	               message "  Would ABI-verify res_pjsip.so and res_pjsip_nat.so (version string embedded in .so)."
	               message "    — Version mismatch: warns and asks for confirmation rather than hard-aborting."
	               message "  Would create .ORIG backups for all replaced modules (first run only)."
	               message "  Would deploy the full downloaded set to the Asterisk module directory."
	       elif [[ "$restore" == true ]]; then
	               message "  Would discover all res_pjsip*.so.ORIG and chan_pjsip.so.ORIG backups in the module directory."
	               message "  Would restore each discovered .ORIG backup to its original module name."
	               message "  Would require a full Asterisk/FreePBX restart afterward."
	       elif [[ "$copyback" == true ]]; then
	               message "  Would discover all res_pjsip*.so.MSTEAMS and chan_pjsip.so.MSTEAMS copies in the module directory."
	               message "  Would copy each .MSTEAMS file back to its active module name."
	               message "  Would require a full Asterisk/FreePBX restart afterward."
	       else
	               tarurl="https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-${ASTVERSION}-current.tar.gz"
	               message "  Would detect running Asterisk version (asterisk -V) and check for exact-version tarball:"
	               message "    https://downloads.asterisk.org/pub/telephony/asterisk/releases/asterisk-<full-version>.tar.gz"
	               message "  If found, uses it (modules match running binary exactly)."
	               message "  If not, falls back to: $tarurl"
	               message "  Would apply the MS Teams ms_signaling_address runtime patch to Asterisk PJSIP sources."
	               message "  Would compile Asterisk (make) and collect full PJSIP module set from build output:"
	               message "    res/res_pjsip*.so  — PJSIP core and supplementary modules"
	               message "    channels/chan_pjsip.so — SIP channel driver"
	               message "  Would back up originals (.ORIG) and deploy the full set to the FreePBX module directory."
	               message "  Every module linking against res_pjsip.h is replaced together to prevent ABI crashes."
	               message "  Would verify res_pjsip.so and res_pjsip_nat.so contain ms_signaling_address."
	               message "  Would require a full fwconsole restart afterward."
	       fi
	       message "DRY-RUN: Exiting without making any changes."
	       terminate
		fi

		# For real runs, confirm configuration with the user before proceeding
		confirm_run_options

	if [[ "$restore" == true ]] ; then
	       message "Restore option enabled: restoring full PJSIP module set (res_pjsip*.so + chan_pjsip.so) from .ORIG backups."
	       restore
	elif [[ "$copyback" == true ]] ; then
	        message "Copy back option enabled: copying full PJSIP module set (res_pjsip*.so + chan_pjsip.so) from .MSTEAMS copies."
	        copyback
	elif [[ "$downloadonly" == true ]] ; then
	        message "Download only option enabled: downloading full PJSIP module set from GitHub for Asterisk ${ASTVERSION} (${DEBIAN_ARCH})."
	        downloadonly
	elif [[ "$ASTERISK_ONLY" == true ]] ; then
	        message "Asterisk standalone install option enabled: building and installing Asterisk from source."
	        build_asterisk_only "$ASTVERSION"
	else
	        message "No options enabled: running MSTeams-FreePBX-Install."
	        build_msteams $ASTVERSION
	fi

	## FINISH
	apt install -y bc
	duration=$(echo "$(date +%s.%N) - $start" | bc)
	execution_time=$(printf "%.2f seconds" $duration)
	message "Total script Execution Time: $execution_time"
		if [[ "$ASTERISK_ONLY" == true ]]; then
		        print_asterisk_only_summary
		elif [[ "$restore" == true ]]; then
		        local modules_dir
		        modules_dir=$(get_asterisk_module_dir)
		        message "Restore operation summary:"
		        message "  - Mode: restore original full PJSIP module set from .ORIG backups"
		        message "  - Module directory: $modules_dir"
		        message "  - All res_pjsip*.so.ORIG and chan_pjsip.so.ORIG backups in that directory were restored."
		        message "  - Every module linking against res_pjsip.h is restored together to prevent ABI mismatches."
		        message "  - REQUIRED: Restart Asterisk/FreePBX to activate: fwconsole restart"
		elif [[ "$copyback" == true ]]; then
		        local modules_dir
		        modules_dir=$(get_asterisk_module_dir)
		        message "Copyback operation summary:"
		        message "  - Mode: copy back MSTeams-patched full PJSIP module set from .MSTEAMS copies"
		        message "  - Module directory: $modules_dir"
		        message "  - All res_pjsip*.so.MSTEAMS and chan_pjsip.so.MSTEAMS copies in that directory were deployed."
		        message "  - Every module linking against res_pjsip.h is deployed together to prevent ABI mismatches."
		        message "  - REQUIRED: Restart Asterisk/FreePBX to activate: fwconsole restart"
		elif [[ "$downloadonly" == true ]]; then
		        local modules_dir
		        modules_dir=$(get_asterisk_module_dir)
		        message "Download/install operation summary:"
		        message "  - Mode: download prebuilt full PJSIP module set from GitHub"
		        message "  - Source repo: https://github.com/Vince-0/MSTeams-PJSIPNAT"
		        message "  - Source URL:  ${PREBUILT_BASE_URL}/asterisk-${ASTVERSION}/"
		        message "  - Asterisk major version: ${ASTVERSION}"
		        message "  - Architecture: ${DEBIAN_ARCH}"
		        message "  - Module directory: ${modules_dir}"
		        message "  - All installed res_pjsip*.so and chan_pjsip.so modules were candidates for replacement."
		        message "  - Core modules (res_pjsip.so, res_pjsip_nat.so) are required; others downloaded if available."
		        message "  - .ORIG backups created for each replaced module (first run only; existing backups preserved)."
		        message "  - Every downloaded module ABI-verified (Asterisk version string present in .so)."
		        message "  - Every module linking against res_pjsip.h must be replaced together to prevent crashes."
		        message "  - REQUIRED: Restart Asterisk/FreePBX to activate: fwconsole restart"
		else
		        print_freepbx_summary
		        message "Finished MSTeams-FreePBX-Install process for $host"
		fi
	terminate
