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

Organisations with MS Teams may want to enable their users to make phone calls from the MS Teams application. This is done with Direct Routing

MS Teams does not oficially support Asterisk as an SBC to connect VOIP services to MS Teams Direct Routing but SIP is SIP.

MS Teams uses an implementation of Session Initiation Protocol and [Asterisk](https://www.asterisk.org/) is a SIP back-to-back user agent. 

This allows Asterisk to bridge SIP channels together for example a telecoms provider on one side and an MS Teams Direct Routing channel on the other.

Asterisk implements a SIP channel driver called [PJSIP](https://github.com/pjsip/pjproject). PJSIP is a [GNU GPL](https://www.gnu.org/) [licensed](https://docs.pjsip.org/en/latest/overview/license_pjsip.html), multimedia communication library written in C.

## MS Documentation

[Session Border Controllers certified for Direct Routing](https://learn.microsoft.com/en-us/microsoftteams/direct-routing-border-controllers)

[Connect your Session Border Controller (SBC) to Direct Routing](https://learn.microsoft.com/en-us/microsoftteams/direct-routing-connect-the-sbc)



## To Do

- Fix email option for SSL provisioning
- Asterisk version options
- Asterisk basic standalone option
