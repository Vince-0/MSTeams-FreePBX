# MSTeams-FreePBX
MS Teams compatible PJSIP NAT module for FreePBX

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
