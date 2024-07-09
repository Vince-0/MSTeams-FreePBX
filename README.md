# MSTeams-FreePBX
## MS Teams Direct Routing compatible PJSIP NAT module for Asterisk under FreePBX

Author [https://github.com/Vince-0](https://github.com/Vince-0/Projects)

This script compiles Asterisk from source for a modified PJSIP NAT module and installs into Asterisk for use under FreePBX to act as an SBC for MS Teams Direct Routing VOIP calls. It can also download a precompiled version from this repo.
  
## Requires
FreePBX. Usually installed from https://github.com/FreePBX/sng_freepbx_debian_install

Debian 12 Bookworm

Asterisk 21

## Usage
### Download

`wget https://github.com/Vince-0/MSTeams-FreePBX/blob/main/MSTeams-FreePBX-Install.sh](https://raw.githubusercontent.com/Vince-0/MSTeams-FreePBX/main/MSTeams-FreePBX-Install.sh`

### Permision

`chmod +x MSTeams-FreePBX-Install.sh`

### Execute

`bash MSTeams-FreePBX-Install.sh`

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
<p align="center">
<img src="https://github.com/Vince-0/MSTeams-FreePBX/blob/9660cbc6282b76b1156d93897cc81612802bca68/MSTEAMS-Asterisk.png" />
</p>

<p align="center">
<img src="https://github.com/Vince-0/MSTeams-FreePBX/blob/bfe585223027dddd8220907ff325088090d5cb41/MSTeams-dialpad2.png" />
</p>

Organisations with MS Teams may want to enable their users to make phone calls from the MS Teams application. This is done with MS Teams Direct Routing.

MS Teams does not oficially support [Asterisk](https://en.wikipedia.org/wiki/Asterisk_(PBX)) as an SBC to connect VOIP services to MS Teams Direct Routing but [SIP](https://en.wikipedia.org/wiki/Session_Initiation_Protocol) is SIP and each implementation is **almost** close enough to work out of the box.

MS Teams uses an implementation of Session Initiation Protocol and [Asterisk](https://www.asterisk.org/) is a SIP back-to-back user agent. 

This allows Asterisk to bridge SIP channels together for example a telecoms provider on one side and an MS Teams Direct Routing channel on the other.

Asterisk implements a SIP channel driver called [PJSIP](https://github.com/pjsip/pjproject). PJSIP is a [GNU GPL](https://www.gnu.org/) [licensed](https://docs.pjsip.org/en/latest/overview/license_pjsip.html), multimedia communication library written in C.

By default the PJSIP NAT module does not present a FQDN in the CONTACT and VIA SIP headers so one can change this behavior in the module's source code.

Asterisk under FreePBX is an easy way to connect a SIP server with a GUI to MS Teams but any SIP switch/proxy like FreeSwitch or Kamailio could do it.

MS Teams can route media (audio) directly between MS Teams users and the SBC to shorten the path media takes, greatly decreasing latency and network hops and so increasing call quality and reliability. This requires an ICE (Interactive Connectivity Establishment) server configured in Asterisk to offer its public IP as a candidate for peer to peer connections for VOIP.

MS Teams offers a number of media codecs for VOIP calls but the best for Internet connections is SILK because it offers forward error correction, is quite tolerant of packet loss and has various bandwidth options.

## How

1. Prepare and install a custom PJSIP NAT module for Asterisk under FreePBX.

2. Configure TLS certificates from [LetsEncrypt](https://letsencrypt.org/) using (acme.sh)[https://github.com/acmesh-official/acme.sh] for Asterisk to provide SRTP encryption on calls. This requires a publicly accessible DNS FQDN on your server.
  
3. Use FreePBX to control Asterisk dialplan to route calls in and out of MS Teams and any SIP connection like a telecoms carrier.

4. Configure MS Teams, with the appropriate "Phone System" licenses, to use MS Teams Direct Routing for your tenant's users via this Asterisk as an SBC.

## To Do

- Fix email option for SSL provisioning - currently does not configure SSL properly
- Asterisk mulitple version options
- Precompile PJSIP NAT module for mulitple Asterisk versions
- Asterisk basic standalone option

## Compiled PJSIP NAT module for Asterisk 21

[Vince-0/MSTeams-PJSIPNAT](https://github.com/Vince-0/MSTeams-PJSIPNAT)

## Reference Links

[Asterisk Developer Mail List](https://asterisk-dev.digium.narkive.com/ucZYhaLE/asterisk-16-pjsip-invite-contact-field-and-fqdn#post12)

[Nick Bouwhuis](https://nick.bouwhuis.net/posts/2022-01-02-asterisk-as-a-teams-sbc)

[Ayonik](https://www.ayonik.de/blog/item/90-microsoft-teams-direct-routing-with-asterisk-pbx)

[godril at Otakudang.org](https://www.otakudang.org/?p=969)


## MS Documentation

[Plan Direct Routing](https://learn.microsoft.com/en-us/microsoftteams/direct-routing-border-controllers)

[Configure Voice Routing](https://learn.microsoft.com/en-us/microsoftteams/direct-routing-configure#configure-voice-routing)

[Media Bypass](https://learn.microsoft.com/en-us/microsoftteams/direct-routing-plan-media-bypass)




