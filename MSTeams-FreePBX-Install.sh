#!/bin/bash
#####################################################################################
# @author https://github.com/Vince-0
#
# Use at your own risk.
#
# Requires: Debian 12, FreePBX with Asterisk 21, 22 or 23 (or standalone Asterisk with --asterisk-only).
#
# This script does this:
# Compile Asterisk from source for a modified PJSIP NAT module compatible with MSTeams and install into FreePBX Asterisk.
# Install Letsencrypt SSL using certbot (preferred) and/or existing certificates
#
# Options:
# --downloadonly: Downloads and installs compiled PJSIP NAT module from Vince-0 github repo and install into FreePBX Asterisk.
# --restore: Copy original PJSIP NAT module back and install.
# --copyback: Copy customized MSTeams compatible PJSIP NAT module back and install.
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
		echo "Successfully downloaded: ${patch_file}"
	else
		echo "ERROR: Failed to download patch file from: $remote_url"
		echo "Please check your internet connection or download manually from:"
		echo "https://github.com/Vince-0/MSTeams-FreePBX/tree/main/patches"
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
	    echo "  --downloadonly   Downloads and installs compiled PJSIP NAT module from Vince github repo and install into FreePBX Asterisk"
	    echo "  --restore        Copy original PJSIP NAT module back and install"
	    echo "  --copyback       Copy customized MSTeams compatible PJSIP NAT module back and install"
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
	        mode_desc="--downloadonly (Download prebuilt pjsip_nat.so module from Vince-0's repo)"
	    elif [[ "$restore" == true ]]; then
	        mode_desc="--restore (Restore original pjsip_nat.so module from res_pjsip_nat.so.ORIG)"
	    elif [[ "$copyback" == true ]]; then
	        mode_desc="--copyback (Copy back modified pjsip_nat.so module from res_pjsip_nat.so.MSTEAMS)"
	    else
	        mode_desc="FreePBX install + patch for MSTeams PJSIP NAT module"
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

#Copy original PJSIP NAT module back and load
restore() {
        local lib_path modules_dir
        lib_path=$(get_lib_path)
        modules_dir="$lib_path/asterisk/modules"

        message "Restoring original res_pjsip_nat.so and install"
        mv "$modules_dir/res_pjsip_nat.so" "$modules_dir/res_pjsip_nat.so.MSTEAMS"
        cp -v "$modules_dir/res_pjsip_nat.so.ORIG" "$modules_dir/res_pjsip_nat.so"
        asterisk -rx 'module unload res_pjsip_nat.so'
        asterisk -rx 'module load res_pjsip_nat.so'
}

#Copy modified PJSIP NAT module back and load
copyback() {
        local lib_path modules_dir
        lib_path=$(get_lib_path)
        modules_dir="$lib_path/asterisk/modules"

        message "Copying modified res_pjsip_nat.so.MSTEAMS back and install"
        mv "$modules_dir/res_pjsip_nat.so" "$modules_dir/res_pjsip_nat.so.ORIG"
        cp -v "$modules_dir/res_pjsip_nat.so.MSTEAMS" "$modules_dir/res_pjsip_nat.so"
        asterisk -rx 'module unload res_pjsip_nat.so'
        asterisk -rx 'module load res_pjsip_nat.so'
}

downloadonly() {
	        # Check if prebuilt modules are available for this architecture
	        if [[ "$DEBIAN_ARCH" != "amd64" ]]; then
	                message "ERROR: Prebuilt modules are not available for architecture '$CPU_ARCH' (Debian: $DEBIAN_ARCH)."
	                message "Prebuilt modules are only available for x86_64 (amd64) architecture."
	                message ""
	                message "Please run the script without --downloadonly to build from source instead."
	                message "Building from source supports all architectures that Asterisk supports."
	                exit 1
	        fi

	        local lib_path modules_dir
	        lib_path=$(get_lib_path)
	        modules_dir="$lib_path/asterisk/modules"
	        local target_so="${modules_dir}/res_pjsip_nat.so"
	        local backup_orig="${modules_dir}/res_pjsip_nat.so.ORIG"
	        local backup_msteams="${modules_dir}/res_pjsip_nat.so.MSTEAMS"
	        local url="${PREBUILT_BASE_URL}/asterisk-${ASTVERSION}/res_pjsip_nat.so"

	        message "Downloading custom PJSIP NAT module for FreePBX Asterisk ${ASTVERSION} on Debian 12 from Vince-0's repo: ${url}"

	        mkdir -p "${modules_dir}"
	        if ! wget -O "${backup_msteams}" "${url}"; then
	            message "ERROR: Failed to download precompiled res_pjsip_nat.so from ${url}"
	            exit 1
	        fi

	        if [[ -f "${target_so}" && ! -f "${backup_orig}" ]]; then
	            mv "${target_so}" "${backup_orig}"
	        fi

	        cp -v "${backup_msteams}" "${target_so}"
        asterisk -rx 'module unload res_pjsip_nat.so'
        asterisk -rx 'module load res_pjsip_nat.so'
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
	local cb_cmd_out cb_cmd_rc
	if [[ "$cert_source" == "certbot-renew" ]]; then
		message "Renewing certificate with certbot for $FQDN..."
		cb_cmd_out=$(certbot renew --cert-name "$FQDN" --non-interactive 2>&1)
		cb_cmd_rc=$?
	else
		message "Obtaining new certificate with certbot for $FQDN (email: $SSL_EMAIL)..."
		cb_cmd_out=$(certbot certonly --standalone --non-interactive --agree-tos \
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
	        cd "$SRCDIR"
	        TARBALL="asterisk-${ASTVERSION}-current.tar.gz"

	        if [[ -f "$SRCDIR/$TARBALL" ]]; then
	                message "Found existing Asterisk tarball: $TARBALL (skipping download)"
	        else
	                message "Downloading Asterisk source code tarball..."
	                wget -P "$SRCDIR" "https://downloads.asterisk.org/pub/telephony/asterisk/$TARBALL"
	        fi

	        # Extract the tarball
	        message "Extracting Asterisk source tarball..."
		        tar -xzf "$SRCDIR/$TARBALL"
	
		        # Navigate to extracted directory
		        cd "$SRCDIR"/asterisk-"${ASTVERSION}".*

        # Install dependencies
        message "Installing dependencies..."
        contrib/scripts/install_prereq install

	        # Apply MS Teams runtime FQDN patch (ms_signaling_address) to PJSIP NAT
	        if ! apply_ms_teams_runtime_patch "$PWD" "$ASTVERSION"; then
	                message "ERROR: Failed to apply MS Teams runtime patch to Asterisk sources."
	                terminate 1
	        fi

	        # Configure Asterisk with default module set
        message "Configuring Asterisk with default menuselect options..."
        ./configure

        # Compile Asterisk (using default menuselect options)
        message "Compile Asterisk"
        make

        # Install Asterisk
        local lib_path modules_dir
        lib_path=$(get_lib_path)
        modules_dir="$lib_path/asterisk/modules"

	        message "Copy custom res_pjsip_nat.so to FreePBX Asterisk $modules_dir"
	        # NOTE: 'make install' is intentionally NOT run here. FreePBX owns the running Asterisk
	        # installation; only the patched res_pjsip_nat.so module needs to be replaced.
	        # Running 'make install' would overwrite FreePBX-managed Asterisk binaries and configs.
	        #make install
	        #ldconfig
	
	        # Move and replace res_pjsip_nat.so, keeping a one-time backup of the original
	        if [[ -f "$modules_dir/res_pjsip_nat.so" && ! -f "$modules_dir/res_pjsip_nat.so.ORIG" ]]; then
	                mv "$modules_dir/res_pjsip_nat.so" "$modules_dir/res_pjsip_nat.so.ORIG"
	        else
	                message "res_pjsip_nat.so.ORIG already exists in $modules_dir; leaving existing backup in place."
	        fi
	        cp -v res/res_pjsip_nat.so "$modules_dir/"
	asterisk -rx 'module unload res_pjsip_nat.so'
	asterisk -rx 'module load res_pjsip_nat.so'

	# Install Asterisk sample configuration files
        # message "Installing Asterisk sample configuration files..."
        # make samples
	   message "MSTeams res_pjsip_nat.so installed"

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
	
	        cd "$SRCDIR"
	        TARBALL="asterisk-${ASTVERSION}-current.tar.gz"

	        if [[ -f "$SRCDIR/$TARBALL" ]]; then
	                message "Found existing Asterisk tarball: $TARBALL (skipping download)"
	        else
	                message "Downloading Asterisk source code tarball for standalone install..."
	                wget -P "$SRCDIR" "https://downloads.asterisk.org/pub/telephony/asterisk/${TARBALL}"
	        fi

	        message "Extracting Asterisk source tarball..."
	        tar -xzf "$SRCDIR/$TARBALL"
	
	        cd "$SRCDIR"/asterisk-"${ASTVERSION}".*

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
		if ! apply_ms_teams_runtime_patch "$PWD" "$ASTVERSION"; then
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
	        message "  external_signaling_address=${PUBLIC_IPV4}    ; Public IP address of your SBC"
	        message "  external_signaling_port=5061                 ; External SIP TLS port"
	        message "  ms_signaling_address=${fqdn_display}         ; FQDN hostname (e.g., sbc.example.com)"
	        message ""
	        message "  IMPORTANT: ms_signaling_address must be set to a FQDN hostname (not an IP address)."
	        message "  This FQDN must match your TLS certificate and MS Teams SBC configuration."
	        message ""
	        message "Next steps:"
	        message "  1. Review and customise your Asterisk configuration in ${config_dir}"
	        message "  2. REQUIRED: Configure ms_signaling_address hostname in ${pjsip_conf_file} as shown above"
	        message "  3. Start Asterisk with: systemctl start asterisk   (if systemd service was created)"
	        message "  4. Reload PJSIP after config changes: asterisk -rx 'pjsip reload'"
}

print_freepbx_summary() {
	        local lib_path modules_dir fqdn_display PUBLIC_IPV4
	        lib_path=$(get_lib_path)
	        modules_dir="$lib_path/asterisk/modules"
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
	        message "  - Active PJSIP NAT module: ${modules_dir}/res_pjsip_nat.so"
	        message "  - Original PJSIP NAT backup (if present): ${modules_dir}/res_pjsip_nat.so.ORIG"
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
	        message "  external_signaling_address=${PUBLIC_IPV4}    ; Public IP address of your SBC"
	        message "  external_signaling_port=5061                 ; External SIP TLS port"
	        message "  ms_signaling_address=${fqdn_display}         ; FQDN hostname (e.g., sbc.example.com)"
	        message ""
	        message "  IMPORTANT: ms_signaling_address must be set to a FQDN hostname (not an IP address)."
	        message "  This FQDN must match your TLS certificate and MS Teams SBC configuration."
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

		# Construct prebuilt base URL with detected/specified architecture
		PREBUILT_BASE_URL="https://github.com/Vince-0/MSTeamsPJSIPNAT_Debian12/raw/main/prebuilt/debian12-${DEBIAN_ARCH}"

		# Check architecture support and warn if needed
		check_architecture_support "$CPU_ARCH"

		if [[ "$dryrun" == true ]]; then
	       local lib_path fqdn_display mode_desc ssl_desc
	       lib_path=$(get_lib_path)

	       # Get FQDN for display (used for SSL and ms_signaling_address examples)
	       if [[ "$restore" == true || "$copyback" == true ]]; then
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
	           mode_desc="--downloadonly (Download prebuilt pjsip_nat.so module from Vince-0's repo)"
	       elif [[ "$restore" == true ]]; then
	           mode_desc="--restore (Restore original pjsip_nat.so module from res_pjsip_nat.so.ORIG)"
	       elif [[ "$copyback" == true ]]; then
	           mode_desc="--copyback (Copy back modified pjsip_nat.so module from res_pjsip_nat.so.MSTEAMS)"
	       else
	           mode_desc="FreePBX install + patch for MSTeams PJSIP NAT module"
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
	               message "  Would apply the MS Teams ms_signaling_address runtime patch to res/res_pjsip_nat.c (runtime-configurable FQDN via pjsip.conf)."
	               message "  Would run ./configure with a chosen installation prefix (default: /usr, configs in /etc, data in /var)."
	               message "  Would run make && make install to install Asterisk into the chosen prefix."
	               message "  Would optionally create and enable a systemd service at /etc/systemd/system/asterisk.service."
	               message "  Would optionally install sample configuration files via 'make samples'."
	       elif [[ "$downloadonly" == true ]]; then
	               url="${PREBUILT_BASE_URL}/asterisk-${ASTVERSION}/res_pjsip_nat.so"
	               message "  Would download precompiled module from: $url"
	               message "  Would back up and replace $lib_path/asterisk/modules/res_pjsip_nat.so"
	       elif [[ "$restore" == true ]]; then
	               message "  Would restore original res_pjsip_nat.so from res_pjsip_nat.so.ORIG"
	       elif [[ "$copyback" == true ]]; then
	               message "  Would copy res_pjsip_nat.so.MSTEAMS over res_pjsip_nat.so"
	       else
	               tarurl="https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-${ASTVERSION}-current.tar.gz"
	               message "  Would download and extract: $tarurl"
	               message "  Would apply the MS Teams ms_signaling_address runtime patch to res/res_pjsip_nat.c (runtime-configurable FQDN via pjsip.conf)."
	               message "  Would compile Asterisk and copy res_pjsip_nat.so into the FreePBX modules directory"
	       fi
	       message "DRY-RUN: Exiting without making any changes."
	       terminate
		fi

		# For real runs, confirm configuration with the user before proceeding
		confirm_run_options

	if [[ "$restore" == true ]] ; then
	       message "Restore option enabled: cp res_pjsip_nat.so.ORIG res_pjsip_nat.so."
	       restore 
	elif [[ "$copyback" == true ]] ; then
	        message "Copy back option enabled: cp res_pjsip_nat.so.MSTEAMS res_pjsip_nat.so."
	        copyback
	elif [[ "$downloadonly" == true ]] ; then
	        message "Download only option enabled: download nat_pjsip_nat.so for Debian 12 from github repo"
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
		        local lib_path modules_dir
		        lib_path=$(get_lib_path)
		        modules_dir="$lib_path/asterisk/modules"
		        message "Restore operation summary:"
		        message "  - Mode: restore original res_pjsip_nat.so module"
		        message "  - Module directory: $modules_dir"
		        message "  - Active module: res_pjsip_nat.so (restored from res_pjsip_nat.so.ORIG)"
		elif [[ "$copyback" == true ]]; then
		        local lib_path modules_dir
		        lib_path=$(get_lib_path)
		        modules_dir="$lib_path/asterisk/modules"
		        message "Copyback operation summary:"
		        message "  - Mode: copy back MSTeams res_pjsip_nat.so.MSTEAMS module"
		        message "  - Module directory: $modules_dir"
		        message "  - Active module: res_pjsip_nat.so (from res_pjsip_nat.so.MSTEAMS)"
		elif [[ "$downloadonly" == true ]]; then
		        local lib_path modules_dir
		        lib_path=$(get_lib_path)
		        modules_dir="$lib_path/asterisk/modules"
		        message "Download/install operation summary:"
		        message "  - Mode: download and activate precompiled MSTeams res_pjsip_nat.so module"
		        message "  - Module directory: $modules_dir"
		        message "  - Active module: res_pjsip_nat.so (downloaded for Asterisk ${ASTVERSION})"
		else
		        print_freepbx_summary
		        message "Finished MSTeams-FreePBX-Install process for $host"
		fi
	terminate
