#!/bin/bash
#####################################################################################
# @author https://github.com/Vince-0
#
# This script carries no warranty. Use at your own risk.
#
# Requires: Debian 12, FreePBX with Asterisk 21.
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
ASTVERSION=21
LOG_FILE='/var/log/pbx/MSTeams-FreePBX-Install.log'
log=$LOG_FILE

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
    echo "  --downloadonly  Downloads and installs compiled PJSIP NAT module from Vince github repo and install into FreePBX Asterisk"
    echo "  --restore       Copy original PJSIP NAT module back and install"
    echo "  --copyback      Copy customized MSTeams compatible PJSIP NAT module back and install" 
    echo "  -h, --help      Show this help message and exit"
}

log() {
        echo "$(date +"%Y-%m-%d %T") - $*" >> "$LOG_FILE"
}

message() {
        echo "$(date +"%Y-%m-%d %T") - $*"
        echo "$(date +"%Y-%m-%d %T") - $*" >> "$LOG_FILE"
}

terminate() {
        # removing pid file
        rm -rf $pidfile
        exit 0;
}

##ARGUMENT PARSE
POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
        case $1 in
                --restore)
                        restore=true
                        shift # past argument
                        ;;
                --copyback)
                        restore=true
                        shift # past argument
                        ;;
                --downloadonly)
                        downloadonly=true
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
        message "Downloading custom PJSIP NAT module for FreePBX Asterisk 21 on Debian 12 from Vince-0's repo"
        wget -O res_pjsip_nat.so.MSTEAMS -P /usr/lib/x86_64-linux-gnu/asterisk/modules/ https://github.com/Vince-0/MSTeamsPJSIPNAT_Debian12/blob/5dcd26ef97841268ac030a39643b1b074cff362d/res_pjsip_nat.so
        mv /usr/lib/x86_64-linux-gnu/asterisk/modules/res_pjsip_nat.so  /usr/lib/x86_64-linux-gnu/asterisk/modules/res_pjsip_nat.so.ORIG
        cp -v /usr/lib/x86_64-linux-gnu/asterisk/modules/res_pjsip_nat.so.MSTEAMS /usr/lib/x86_64-linux-gnu/asterisk/modules/res_pjsip_nat.so
        asterisk -rx 'module unload res_pjsip_nat.so'
        asterisk -rx 'module load res_pjsip_nat.so'
}

#Install SSL from LetsEncrypt using acme.sh
install_letsencrypt() {
       #curl https://get.acme.sh | sh -s email=$EMAIL
       read -p "Email for SSL: " EMAIL

       #curl https://get.acme.sh | sh -s email=$EMAIL
       apt install -y git
       git clone https://github.com/acmesh-official/acme.sh.git
       cd ./acme.sh
       service apache2 stop
       ./acme.sh --install -m my@example.com
       #mkdir /etc/asterisk/ssl
       ./acme.sh --issue --standalone \
        -d $FQDN \
        --fullchain-file /etc/asterisk/ssl/cert.crt \
        --cert-file /etc/asterisk/ssl/ca.crt \
        --key-file /etc/asterisk/ssl/privkey.crt \
        --server https://acme-v02.api.letsencrypt.org/directory
        service apache2 start
}

#Compile custom Asterisk with PJSIP NAT module and load
build_msteams() {
        ASTVERSION=$1
        SRCDIR="/usr/src"

        checkfqdn

        # Get source
        message "Download Asterisk source code tarball..."
        cd /usr/src/
        wget -P /usr/src/ https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-$ASTVERSION-current.tar.gz

        # Extract the tarball
        message "Extracting Asterisk source tarball..."
        tar -xzf /usr/src/asterisk-21-current.tar.gz

        # Navigate to extracted directory
        cd /usr/src/asterisk-21.*

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

        # Configure Asterisk
        message "Configuring Asterisk..."
        ./configure

        # Create  menuselect.makeopts
        message "Creating meneselect.makeopts..."
        cat <<ENDOFFILE >> menuselect.makeopts
MENUSELECT_ADDONS=chan_mobile chan_ooh323 format_mp3 res_config_mysql
MENUSELECT_APPS=app_flash app_skel app_voicemail_imap app_voicemail_odbc app_ivrdemo app_saycounted app_statsd app_meetme
MENUSELECT_BRIDGES=binaural_rendering_in_bridge_softmix
MENUSELECT_CDR=cdr_beanstalkd
MENUSELECT_CEL=cel_beanstalkd
MENUSELECT_CHANNELS=chan_dahdi
MENUSELECT_CODECS=codec_dahdi codec_opus codec_siren7 codec_siren14 codec_g729a codec_silk
MENUSELECT_FORMATS=
MENUSELECT_FUNCS=
MENUSELECT_PBX=
MENUSELECT_RES=res_ari_mailboxes res_mwi_external res_mwi_external_ami res_pjsip_stir_shaken res_stasis_mailbox res_stasis_test res_stir_shaken res_timing_dahdi res_chan_stats res_cliexec res_corosync res_endpoint_stats res_remb_modifier res_timing_kqueue res_digium_phone
MENUSELECT_TESTS=test_abstract_jb test_acl test_aeap test_aeap_speech test_aeap_transaction test_aeap_transport test_amihooks test_aoc test_app test_ari test_ari_model test_ast_format_str_reduce test_astobj2 test_astobj2_thrash test_astobj2_weaken test_bridging test_bucket test_callerid test_capture test_cdr test_cel test_channel test_channel_feature_hooks test_config test_conversions test_core_codec test_core_format test_crypto test_data_buffer test_db test_devicestate test_dlinklists test_dns test_dns_naptr test_dns_query_set test_dns_recurring test_dns_srv test_endpoints test_event test_expr test_file test_format_cache test_format_cap test_func_file test_gosub test_hashtab_thrash test_heap test_http_media_cache test_jitterbuf test_json test_linkedlists test_locale test_logger test_media_cache test_message test_mwi test_named_lock test_netsock2 test_optional_api test_pbx test_poll test_res_pjsip_scheduler test_res_pjsip_session_caps test_res_rtp test_res_stasis test_sched test_scope_trace test_scoped_lock test_security_events test_skel test_sorcery test_sorcery_astdb test_sorcery_memory_cache_thrash test_sorcery_realtime test_stasis test_stasis_channels test_stasis_endpoints test_stasis_state test_stream test_stringfields test_strings test_substitution test_taskprocessor test_threadpool test_time test_uri test_utils test_uuid test_vector test_voicemail_api test_websocket_client test_xml_escape test_res_prometheus
MENUSELECT_CFLAGS=BUILD_NATIVE OPTIONAL_API
MENUSELECT_UTILS=astcanary astdb2sqlite3 astdb2bdb
MENUSELECT_AGIS=
MENUSELECT_CORE_SOUNDS=CORE-SOUNDS-EN-GSM
MENUSELECT_MOH=MOH-OPSOUND-WAV
MENUSELECT_EXTRA_SOUNDS=
MENUSELECT_BUILD_DEPS=bridge_holding app_cdr func_periodic_hook app_confbridge res_speech res_agi res_stasis res_adsi res_smdi res_audiosocket res_odbc res_crypto res_xmpp res_pjsip res_pjsip_pubsub res_pjsip_session res_rtp_multicast res_curl app_chanspy func_cut func_groupcount func_uri res_ael_share res_http_websocket res_ari res_ari_model res_stasis_recording res_stasis_playback res_stasis_answer res_stasis_snoop res_stasis_device_state func_curl res_odbc_transaction res_sorcery_config res_pjproject res_sorcery_memory res_sorcery_astdb res_statsd res_geolocation res_pjsip_outbound_publish chan_pjsip res_calendar res_fax res_hep res_phoneprov res_pjsip_outbound_registration DONT_OPTIMIZE G711_NEW_ALGORITHM
MENUSELECT_DEPSFAILED=MENUSELECT_APPS=app_flash
MENUSELECT_DEPSFAILED=MENUSELECT_CDR=cdr_beanstalkd
MENUSELECT_DEPSFAILED=MENUSELECT_CEL=cel_beanstalkd
MENUSELECT_DEPSFAILED=MENUSELECT_CHANNELS=chan_dahdi
MENUSELECT_DEPSFAILED=MENUSELECT_CODECS=codec_dahdi
MENUSELECT_DEPSFAILED=MENUSELECT_RES=res_pjsip_stir_shaken
MENUSELECT_DEPSFAILED=MENUSELECT_RES=res_stasis_test
MENUSELECT_DEPSFAILED=MENUSELECT_RES=res_stir_shaken
MENUSELECT_DEPSFAILED=MENUSELECT_RES=res_timing_dahdi
MENUSELECT_DEPSFAILED=MENUSELECT_RES=res_timing_kqueue
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_abstract_jb
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_acl
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_aeap
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_aeap_speech
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_aeap_transaction
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_aeap_transport
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_amihooks
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_aoc
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_app
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_ari
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_ari_model
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_ast_format_str_reduce
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_astobj2
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_astobj2_thrash
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_astobj2_weaken
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_bridging
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_bucket
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_callerid
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_capture
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_cdr
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_cel
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_channel
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_channel_feature_hooks
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_config
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_conversions
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_core_codec
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_core_format
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_crypto
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_data_buffer
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_db
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_devicestate
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_dlinklists
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_dns
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_dns_naptr
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_dns_query_set
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_dns_recurring
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_dns_srv
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_endpoints
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_event
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_expr
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_file
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_format_cache
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_format_cap
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_func_file
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_gosub
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_hashtab_thrash
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_heap
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_http_media_cache
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_jitterbuf
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_json
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_linkedlists
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_locale
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_logger
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_media_cache
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_message
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_mwi
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_named_lock
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_netsock2
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_optional_api
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_pbx
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_poll
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_res_pjsip_scheduler
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_res_pjsip_session_caps
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_res_rtp
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_res_stasis
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_sched
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_scope_trace
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_scoped_lock
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_security_events
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_skel
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_sorcery
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_sorcery_astdb
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_sorcery_memory_cache_thrash
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_sorcery_realtime
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_stasis
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_stasis_channels
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_stasis_endpoints
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_stasis_state
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_stream
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_stringfields
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_strings
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_substitution
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_taskprocessor
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_threadpool
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_time
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_uri
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_utils
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_uuid
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_vector
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_voicemail_api
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_websocket_client
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_xml_escape
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_res_prometheus
ENDOFFILE

       #Configure make menuselect options
        #message "Configure menuselect options"
        #make menuselect.makeopts

        # Compile Asterisk
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

       install_letsencrypt
}

##START RUN
host=`hostname`
pidfile='/var/run/MSTEAMS-FreePBX-Install.pid'

if [ -f "$pidfile" ]; then
        message "MSTeams-FreePBX-Install process is running PID"
        message "If this may be due to unclean termination then delete $pidfile file and run MSTeams-FreePBX-Install.sh again"
        exit 1;
fi

start=$(date +%s.%N)
message "  Start MSTeams-FreePBX-Install process for $host $kernel"
message "  Log file here $log"
touch $pidfile

if [ $restore ] ; then
       message "Restore option enabled: cp nat_pjsip_nat.so.ORIG nat_pjsip_nat.so."
       restore 
elif [ $copyback ] ; then
        message "Copy back option enabled: cp nat_pjsip_nat.so.MSTEAMS nat_pjsip_nat.so."
        copyback
elif [ $downloadonly ] ; then
        message "Download only option enabled: download nat_pjsip_nat.so for Debian 12 from github repo"
        downloadonly
else
        message "No options enabled: running MSTeams-FreePBX-Install."
        build_msteams $ASTVERSION
fi

## FINISH
apt install -y bc
duration=$(echo "$(date +%s.%N) - $start" | bc)
execution_time=`printf "%.2f seconds" $duration`
message "Total script Execution Time: $execution_time"
message "Finished MSTeams-FreePBX-Install process for $host $kernel"
message "fwconsole restart"
fwconsole restart
terminate
