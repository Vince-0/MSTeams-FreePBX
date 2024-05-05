# MSTeams-FreePBX
## MS Teams Direct Routing compatible PJSIP NAT module for Asterisk under FreePBX

Author [https://github.com/Vince-0](https://github.com/Vince-0/Projects)

Compile Asterisk from source for a modified PJSIP NAT module and install into FreePBX Asterisk to act as an SBC for MS Teams Direct Routing VOIP calls.
Installs Letsencrypt SSL using acme.sh
  
## Requires
FreePBX. Usually installed from https://github.com/FreePBX/sng_freepbx_debian_install

Debian 12 Bookworm

Asterisk 21

## Usage
### Download

`wget https://github.com/Vince-0/MSTeams-FreePBX/blob/main/MSTeams-FreePBX-Install.sh`

### Permision

`chmod +x MSTeams-FreePBX-Install.sh`

### Execute

`bash STeams-FreePBX-Install.sh`

### Options
```
--downloadonly
Downloads and installs compiled PJSIP NAT module from Vince-0 github repo and install into FreePBX Asterisk.

--restore
Copy original PJSIP NAT module back and install.

--copyback
Copy customized MSTeams compatible PJSIP NAT module back and install.
```

Use at your own risk.

## Why

## To Do

- Fix email option for SSL provisioning
- Asterisk version options
- Asterisk basic standalone option
