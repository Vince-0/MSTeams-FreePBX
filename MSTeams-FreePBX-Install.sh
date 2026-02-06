#!/bin/bash
#####################################################################################
# @author https://github.com/Vince-0
#
# Use at your own risk.
#
# Requires: Debian 12, FreePBX with Asterisk 21, 22 or 23.
#
# This script does this:
# Compile Asterisk from source for a modified PJSIP NAT module compatible with MSTeams and install into FreePBX Asterisk.
# Install Letsencrypt SSL using acme.sh
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
PREBUILT_BASE_URL="https://github.com/Vince-0/MSTeamsPJSIPNAT_Debian12/raw/main/prebuilt/debian12-amd64"
SSL_EMAIL=""
SKIP_SSL=false
SSL_STATUS="Not requested"
ASTERISK_ONLY=false
ASTERISK_PREFIX=""
ASTERISK_SYSCONFDIR=""
ASTERISK_LOCALSTATEDIR=""
ASTERISK_SAMPLES_INSTALLED=false
ASTERISK_SERVICE_CREATED=false
ASTERISK_SERVICE_ENABLED=false

##PREPARE
mkdir -p '/var/log/pbx/'
echo "" > $log

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
	    echo "  --dry-run        Show what actions would be taken (including selected Asterisk version and URLs) without making any changes"
	    echo "  --debug          Alias for --dry-run"
	    echo "  --email <addr>   Email address to use for Let's Encrypt SSL; avoids interactive prompt"
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
	    local mode_desc ssl_desc email_desc confirm
	    local host_name fqdn_desc

	    host_name=$(hostname)

	    if [[ "$ASTERISK_ONLY" == true ]]; then
	        mode_desc="Standalone Asterisk install (no FreePBX)"
	    elif [[ "$downloadonly" == true ]]; then
	        mode_desc="Download precompiled PJSIP NAT module only"
	    elif [[ "$restore" == true ]]; then
	        mode_desc="Restore original PJSIP NAT module"
	    elif [[ "$copyback" == true ]]; then
	        mode_desc="Copy back MSTeams PJSIP NAT module"
	    else
	        mode_desc="FreePBX install/patch for MSTeams PJSIP NAT module"
	    fi

	    if [[ "$SKIP_SSL" == true ]]; then
	        ssl_desc="DISABLED (--no-ssl/--skip-ssl specified)"
	    else
	        if [[ -n "$SSL_EMAIL" ]]; then
	            ssl_desc="ENABLED (Let's Encrypt via acme.sh)"
	            email_desc="$SSL_EMAIL"
	        else
	            ssl_desc="ENABLED (email will be requested during install; blank will skip SSL)"
	        fi
	    fi

	    # Determine FQDN summary (only required for modes that patch PJSIP NAT)
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

	    message "==================================================="
	    message "MSTeams-FreePBX-Install run configuration summary:"
	    message "  - Operation mode: $mode_desc"
	    message "  - Target Asterisk major version: $ASTVERSION"
	    message "  - Hostname: $host_name"
	    message "  - FQDN (for PJSIP NAT): $fqdn_desc"
	    if [[ "$SKIP_SSL" == true ]]; then
	        message "  - SSL: $ssl_desc"
	    else
	        if [[ -n "$email_desc" ]]; then
	            message "  - SSL: $ssl_desc (email: $email_desc)"
	        else
	            message "  - SSL: $ssl_desc"
	        fi
	    fi
	    if [[ "$ASTERISK_ONLY" == true ]]; then
	        message "  - Asterisk-only sub-options (prefix, systemd service, samples) will be confirmed during install."
	    fi
	    message "==================================================="
		    message "Proceed with these settings? (y/n) [y]: "
		    read -r confirm
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
		                --no-ssl|--skip-ssl)
		                        SKIP_SSL=true
		                        shift # past argument
		                        ;;
		                --asterisk-only|--standalone-asterisk)
		                        ASTERISK_ONLY=true
		                        shift # past argument
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

##MAIN FUNCTIONS

#Check for host FQDN
checkfqdn() {
        FQDN=$(hostname)
        message "Check if this host has a FQDN"
        if [[ $FQDN == *.* ]]; then
          message "Hostname '${FQDN}' is a FQDN."
          message "Proceeding."
        else
          message "Hostname '${FQDN}' is not a FQDN."
          #message "Please configure a FQDN host name and run this script again"
          #read -p "Input FQDN: " FQDN
          terminate
          exit
        fi
}

#Copy original PJSIP NAT module back and load
restore() {
        message "Restoring original res_pjsip_nat.so and install"
        mv /usr/lib/x86_64-linux-gnu/asterisk/modules/res_pjsip_nat.so  /usr/lib/x86_64-linux-gnu/asterisk/modules/res_pjsip_nat.so.MSTEAMS
        cp -v /usr/lib/x86_64-linux-gnu/asterisk/modules/res_pjsip_nat.so.ORIG /usr/lib/x86_64-linux-gnu/asterisk/modules/res_pjsip_nat.so
        asterisk -rx 'module unload res_pjsip_nat.so'
        asterisk -rx 'module load res_pjsip_nat.so'
}

#Copy modified PJSIP NAT module back and load
copyback() {
        message "Copying modified res_pjsip_nat.so.MSTEAMS back and install"
        mv /usr/lib/x86_64-linux-gnu/asterisk/modules/res_pjsip_nat.so  /usr/lib/x86_64-linux-gnu/asterisk/modules/res_pjsip_nat.so.ORIG
        cp -v /usr/lib/x86_64-linux-gnu/asterisk/modules/res_pjsip_nat.so.MSTEAMS /usr/lib/x86_64-linux-gnu/asterisk/modules/res_pjsip_nat.so
        asterisk -rx 'module unload res_pjsip_nat.so'
        asterisk -rx 'module load res_pjsip_nat.so'
}

downloadonly() {
	        local modules_dir="/usr/lib/x86_64-linux-gnu/asterisk/modules"
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

#Install SSL from LetsEncrypt using acme.sh
install_letsencrypt() {
	       local email
	       local acme_home="/root/.acme.sh"
	       local acme_cmd="${acme_home}/acme.sh"
	       local acme_clone_dir="/opt/acme.sh"
	       local apache_was_running=false

	       if [[ -n "$SSL_EMAIL" ]]; then
	               email="$SSL_EMAIL"
	               message "Using SSL email from command line: $email"
	       else
	               read -p "Email for SSL: " email
	               if [[ -n "$email" ]]; then
	                       SSL_EMAIL="$email"
	               fi
	       fi

	       if [[ -z "$email" ]]; then
	               message "No email provided for SSL; skipping Let's Encrypt installation."
	               SSL_STATUS="Skipped: no email provided; no SSL certificates installed"
	               return 0
	       fi

	       # Ensure SSL directory exists
	       if ! mkdir -p /etc/asterisk/ssl; then
	               message "ERROR: Unable to create /etc/asterisk/ssl directory."
	               SSL_STATUS="FAILED: unable to create /etc/asterisk/ssl directory"
	               return 1
	       fi

	       # Install acme.sh if not already present
	       if [[ ! -x "$acme_cmd" ]]; then
	               message "acme.sh not found at $acme_cmd; installing..."
	               if ! apt install -y git; then
	                       message "ERROR: Failed to install git. Cannot continue with Let's Encrypt installation."
	                       SSL_STATUS="FAILED: could not install git dependency for acme.sh"
	                       return 1
	               fi

	               if [[ -d "$acme_clone_dir" ]]; then
	                       message "Removing existing temporary acme.sh clone at $acme_clone_dir"
	                       rm -rf "$acme_clone_dir"
	               fi

	               if ! git clone https://github.com/acmesh-official/acme.sh.git "$acme_clone_dir"; then
	                       message "ERROR: Failed to clone acme.sh repository."
	                       SSL_STATUS="FAILED: git clone of acme.sh repository failed"
	                       return 1
	               fi

	               if ! ( cd "$acme_clone_dir" && ./acme.sh --install -m "$email" ); then
	                       message "ERROR: acme.sh installation failed."
	                       SSL_STATUS="FAILED: acme.sh installation failed"
	                       return 1
	               fi
	       else
	               message "acme.sh already installed at $acme_cmd; skipping installation."
	       fi

	       if [[ ! -x "$acme_cmd" ]]; then
	               message "ERROR: acme.sh binary not found at $acme_cmd even after installation attempt."
	               SSL_STATUS="FAILED: acme.sh binary not found after installation attempt"
	               return 1
	       fi

	       # Stop apache2 only if present and running
	       if command -v systemctl >/dev/null 2>&1; then
	               if systemctl is-active --quiet apache2; then
	                       apache_was_running=true
	                       message "Stopping apache2 service for standalone Let's Encrypt challenge..."
	                       if ! systemctl stop apache2; then
	                               message "WARNING: Failed to stop apache2 service."
	                       fi
	               else
	                       message "apache2 service not active; not stopping."
	               fi
	       elif command -v service >/dev/null 2>&1; then
	               if service apache2 status >/dev/null 2>&1; then
	                       apache_was_running=true
	                       message "Stopping apache2 service (via service) for standalone Let's Encrypt challenge..."
	                       if ! service apache2 stop; then
	                               message "WARNING: Failed to stop apache2 service (via service)."
	                       fi
	               fi
	       else
	               message "No service manager found for apache2; skipping apache2 stop/start."
	       fi

	       message "Issuing/renewing Let's Encrypt certificate for $FQDN..."
	       if ! "$acme_cmd" --issue --standalone \
	               -d "$FQDN" \
	               --fullchain-file /etc/asterisk/ssl/cert.crt \
	               --cert-file /etc/asterisk/ssl/ca.crt \
	               --key-file /etc/asterisk/ssl/privkey.crt \
	               --server https://acme-v02.api.letsencrypt.org/directory; then
	               message "ERROR: SSL certificate issuance failed for $FQDN."
	               if [[ "$apache_was_running" == true ]]; then
	                       if command -v systemctl >/dev/null 2>&1; then
	                               systemctl start apache2 || message "WARNING: Failed to restart apache2 service after failure."
	                       elif command -v service >/dev/null 2>&1; then
	                               service apache2 start || message "WARNING: Failed to restart apache2 service (via service) after failure."
	                       fi
	               fi
	               SSL_STATUS="FAILED: certificate issuance failed for $FQDN"
	               return 1
	       fi

	       # Restart apache2 if we stopped it
	       if [[ "$apache_was_running" == true ]]; then
	               message "Restarting apache2 service..."
	               if command -v systemctl >/dev/null 2>&1; then
	                       systemctl start apache2 || message "WARNING: Failed to restart apache2 service."
	               elif command -v service >/dev/null 2>&1; then
	                       service apache2 start || message "WARNING: Failed to restart apache2 service (via service)."
	               fi
	       fi

	       message "Let's Encrypt SSL installation completed successfully for $FQDN."
	       SSL_STATUS="Installed: Let's Encrypt SSL certificate for $FQDN (certs in /etc/asterisk/ssl)"
}

#Compile custom Asterisk with PJSIP NAT module and load
build_msteams() {
        ASTVERSION=$1
        SRCDIR="/usr/src"

        checkfqdn

        # Get source
        message "Download Asterisk source code tarball..."
	        cd "$SRCDIR"
	        wget -P "$SRCDIR" "https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-${ASTVERSION}-current.tar.gz"

        # Extract the tarball
        message "Extracting Asterisk source tarball..."
	        TARBALL="asterisk-${ASTVERSION}-current.tar.gz"
	        tar -xzf "$SRCDIR/$TARBALL"

	        # Navigate to extracted directory
	        cd "$SRCDIR"/asterisk-"${ASTVERSION}".*

        # Install dependencies
        message "Installing dependencies..."
        contrib/scripts/install_prereq install

        # Mod PJSIP channel driver res/res_pjsip_nat.c
        #- pj_strdup2(tdata->pool, &uri->host, ast_sockaddr_stringify_host(&transport_state->external_signaling_address));
        #+ pj_strdup2(tdata->pool, &uri->host, "FQDN");
        sed -i "s/pj_strdup2(tdata->pool, &uri->host, ast_sockaddr_stringify_host(&transport_state->external_signaling_address));/pj_strdup2(tdata->pool, \&uri->host, \"$FQDN\");/g" res/res_pjsip_nat.c

        #- pj_strdup2(tdata->pool, &via->sent_by.host, ast_sockaddr_stringify_host(&transport_state->external_s>
        #+ pj_strdup2(tdata->pool, &via->sent_by.host, "FQDN");
        sed -i "s/pj_strdup2(tdata->pool, &via->sent_by.host, ast_sockaddr_stringify_host(&transport_state->external_signaling_address));/pj_strdup2(tdata->pool, \&via->sent_by.host, \"$FQDN\");/g" res/res_pjsip_nat.c

        # Configure Asterisk with default module set
        message "Configuring Asterisk with default menuselect options..."
        ./configure

        # Compile Asterisk (using default menuselect options)
        message "Compile Asterisk"
        make

        # Install Asterisk
        message "Copy custom res_pjsip_nat.so to FreePBX Asterisk /usr/lib/x86_64-linux-gnu/asterisk/modules"
        #make install
        #ldconfig

        #Move and replace res_pjsip_nat.so
        mv /usr/lib/x86_64-linux-gnu/asterisk/modules/res_pjsip_nat.so  /usr/lib/x86_64-linux-gnu/asterisk/modules/res_pjsip_nat.so.ORIG
        cp -v res/res_pjsip_nat.so /usr/lib/x86_64-linux-gnu/asterisk/modules/
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

	        message "Download Asterisk source code tarball for standalone install..."
	        cd "$SRCDIR"
	        TARBALL="asterisk-${ASTVERSION}-current.tar.gz"
	        wget -P "$SRCDIR" "https://downloads.asterisk.org/pub/telephony/asterisk/${TARBALL}"

	        message "Extracting Asterisk source tarball..."
	        tar -xzf "$SRCDIR/$TARBALL"

	        cd "$SRCDIR"/asterisk-"${ASTVERSION}".*

	        message "Installing dependencies for standalone Asterisk build..."
	        contrib/scripts/install_prereq install

	        # Prompt for installation prefix
	        local prefix_input
	        read -p "Enter installation prefix [/usr (Debian standard)]: " prefix_input
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

	        # Patch PJSIP NAT source to hard-code FQDN
	        sed -i "s/pj_strdup2(tdata->pool, &uri->host, ast_sockaddr_stringify_host(&transport_state->external_signaling_address));/pj_strdup2(tdata->pool, \&uri->host, \"$FQDN\");/g" res/res_pjsip_nat.c
	        sed -i "s/pj_strdup2(tdata->pool, &via->sent_by.host, ast_sockaddr_stringify_host(&transport_state->external_signaling_address));/pj_strdup2(tdata->pool, \&via->sent_by.host, \"$FQDN\");/g" res/res_pjsip_nat.c

	        message "Configuring Asterisk for standalone install..."
	        ./configure --prefix="$ASTERISK_PREFIX" --sysconfdir="$ASTERISK_SYSCONFDIR" --localstatedir="$ASTERISK_LOCALSTATEDIR"

	        message "Compiling Asterisk (standalone)..."
	        make

	        message "Installing Asterisk (make install)..."
	        make install

	        # Systemd service prompt
	        local svc_reply
	        read -p "Create and enable systemd service for Asterisk? (y/n) [y]: " svc_reply
	        if [[ -z "$svc_reply" || "$svc_reply" =~ ^[Yy] ]]; then
	                message "Creating and enabling systemd service for Asterisk..."
	                create_asterisk_systemd_service
	        else
	                message "Skipping systemd service creation."
	        fi

	        # Sample configs prompt
	        local samples_reply
	        read -p "Install sample Asterisk configuration files? (y/n) [n]: " samples_reply
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
	        local config_dir modules_dir

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
	        message "  - FQDN hardcoded into res_pjsip_nat.c: ${FQDN}"
	        message "  - Let's Encrypt SSL: ${SSL_STATUS}"
	        if [[ "$SSL_STATUS" == Installed:* ]]; then
	                message "    - Full chain certificate: /etc/asterisk/ssl/cert.crt"
	                message "    - CA certificate:         /etc/asterisk/ssl/ca.crt"
	                message "    - Private key:            /etc/asterisk/ssl/privkey.crt"
	                message "    - acme.sh client:         /root/.acme.sh (handles automatic certificate renewal)"
	        fi
	        message "Next steps:"
	        message "  - Review and customise your Asterisk configuration in ${config_dir}"
	        message "  - Start Asterisk with: systemctl start asterisk   (if systemd service was created)"
}

print_freepbx_summary() {
	        local modules_dir
	        modules_dir="/usr/lib/x86_64-linux-gnu/asterisk/modules"

	        message "MSTeams-FreePBX installation summary:"
	        message "  - Host: ${host}"
	        message "  - Asterisk version targeted: ${ASTVERSION}"
	        message "  - FQDN hardcoded into res_pjsip_nat.c: ${FQDN}"
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
		                message "    - acme.sh client:         /root/.acme.sh (handles automatic certificate renewal)"
		        fi
	        fi
	        message "  - Systemd services: existing FreePBX/Asterisk services were not modified by this script"
	        message "Next steps:"
	        message "  - FreePBX: fwconsole restart (this script will now run it)"
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
message "  Start MSTeams-FreePBX-Install process for $host $kernel"
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

		# If version wasn't explicitly provided on the command line, prompt to confirm/override
		if [[ "$ASTVERSION_FROM_CLI" != true ]]; then
		       message "Asterisk versions supported by this script: $SUPPORTED_AST_VERSIONS"
		       read -p "Enter Asterisk major version to use [$ASTVERSION]: " REPLY_VERSION
		       if [[ -n "$REPLY_VERSION" ]]; then
		               ASTVERSION="$REPLY_VERSION"
		       fi
		fi

		if ! is_supported_version "$ASTVERSION"; then
		       message "ERROR: Asterisk version '$ASTVERSION' is not supported. Supported versions: $SUPPORTED_AST_VERSIONS"
		       terminate
		fi

		message "Using Asterisk major version: $ASTVERSION"

		if [[ "$dryrun" == true ]]; then
	       message "DRY-RUN: No changes will be made. Summary of planned actions:"
	       message "  - Target Asterisk major version: $ASTVERSION"
	       if [[ "$ASTERISK_ONLY" == true ]]; then
	               message "  - Standalone Asterisk install (no FreePBX)."
	               tarurl="https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-${ASTVERSION}-current.tar.gz"
	               message "  - Would download and extract: $tarurl"
	               message "  - Would patch res/res_pjsip_nat.c to hard-code the server FQDN into CONTACT/VIA headers."
	               message "  - Would run ./configure with a chosen installation prefix (default: /usr, configs in /etc, data in /var)."
	               message "  - Would run make && make install to install Asterisk into the chosen prefix."
	               message "  - Would optionally create and enable a systemd service at /etc/systemd/system/asterisk.service."
	               message "  - Would optionally install sample configuration files via 'make samples'."
	               if [[ "$SKIP_SSL" == true ]]; then
	                       message "  - Would skip Let's Encrypt SSL installation (--no-ssl specified)."
	               else
	                       message "  - Would install Let's Encrypt SSL certificates via acme.sh."
	               fi
	       elif [[ "$downloadonly" == true ]]; then
	               url="${PREBUILT_BASE_URL}/asterisk-${ASTVERSION}/res_pjsip_nat.so"
	               message "  - Would download precompiled module from: $url"
	               message "  - Would back up and replace /usr/lib/x86_64-linux-gnu/asterisk/modules/res_pjsip_nat.so"
	       elif [[ "$restore" == true ]]; then
	               message "  - Would restore original res_pjsip_nat.so from res_pjsip_nat.so.ORIG"
	       elif [[ "$copyback" == true ]]; then
	               message "  - Would copy res_pjsip_nat.so.MSTEAMS over res_pjsip_nat.so"
	       else
	               tarurl="https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-${ASTVERSION}-current.tar.gz"
	               message "  - Would download and extract: $tarurl"
	               message "  - Would patch res/res_pjsip_nat.c to hard-code the server FQDN into CONTACT/VIA headers."
	               message "  - Would compile Asterisk and copy res_pjsip_nat.so into the FreePBX modules directory"
	       fi
	       message "DRY-RUN: Exiting without making any changes."
	       terminate
		fi

		# For real runs, confirm configuration with the user before proceeding
		confirm_run_options

	if [[ "$restore" == true ]] ; then
	       message "Restore option enabled: cp nat_pjsip_nat.so.ORIG nat_pjsip_nat.so."
	       restore 
	elif [[ "$copyback" == true ]] ; then
	        message "Copy back option enabled: cp nat_pjsip_nat.so.MSTEAMS nat_pjsip_nat.so."
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
	execution_time=`printf "%.2f seconds" $duration`
	message "Total script Execution Time: $execution_time"
		if [[ "$ASTERISK_ONLY" == true ]]; then
		        print_asterisk_only_summary
		elif [[ "$restore" == true ]]; then
		        message "Restore operation summary:"
		        message "  - Mode: restore original res_pjsip_nat.so module"
		        message "  - Module directory: /usr/lib/x86_64-linux-gnu/asterisk/modules"
		        message "  - Active module: res_pjsip_nat.so (restored from res_pjsip_nat.so.ORIG)"
		elif [[ "$copyback" == true ]]; then
		        message "Copyback operation summary:"
		        message "  - Mode: copy back MSTeams res_pjsip_nat.so.MSTEAMS module"
		        message "  - Module directory: /usr/lib/x86_64-linux-gnu/asterisk/modules"
		        message "  - Active module: res_pjsip_nat.so (from res_pjsip_nat.so.MSTEAMS)"
		elif [[ "$downloadonly" == true ]]; then
		        message "Download/install operation summary:"
		        message "  - Mode: download and activate precompiled MSTeams res_pjsip_nat.so module"
		        message "  - Module directory: /usr/lib/x86_64-linux-gnu/asterisk/modules"
		        message "  - Active module: res_pjsip_nat.so (downloaded for Asterisk ${ASTVERSION})"
		else
		        print_freepbx_summary
		        message "Finished MSTeams-FreePBX-Install process for $host $kernel"
		        message "fwconsole restart"
		        fwconsole restart
		fi
	terminate
