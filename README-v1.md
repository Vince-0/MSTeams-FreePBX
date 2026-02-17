# VOIP Microsoft Teams Gateway
Connect phone VOIP calls from MS Teams using Direct Routing compatible PJSIP NAT module for Asterisk under FreePBX.

Author [https://github.com/Vince-0](https://github.com/Vince-0/Projects)

Use at your own risk.

## What?
This BASH [script](https://github.com/Vince-0/MSTeams-FreePBX/blob/main/MSTeams-FreePBX-Install.sh) compiles Asterisk from source for a modified PJSIP NAT module and installs into Asterisk for use under FreePBX to act as an SBC for MS Teams Direct Routing VOIP calls. It can also download a precompiled version from this [repo](https://github.com/Vince-0/MSTeams-PJSIPNAT).
  
## Requires
FreePBX (for the default FreePBX integration mode). Usually installed from https://github.com/FreePBX/sng_freepbx_debian_install

Debian 12 Bookworm

Asterisk 21, 22 (LTS) or 23 (pre-installed for FreePBX mode; for `--asterisk-only` the script builds Asterisk itself)

## Usage
### Download

Download the install script directly from the raw GitHub URL:

`wget https://raw.githubusercontent.com/Vince-0/MSTeams-FreePBX/main/MSTeams-FreePBX-Install.sh`

### Permission

`chmod +x MSTeams-FreePBX-Install.sh`

### Execute

`bash MSTeams-FreePBX-Install.sh`

### Options
```
--downloadonly
Downloads and installs a compiled PJSIP NAT module from Vince-0's GitHub repo and installs it into FreePBX Asterisk.

--restore
Copy original PJSIP NAT module back and install.

--copyback
Copy customized MSTeams compatible PJSIP NAT module back and install.

--version=<21|22|23>
Specify the Asterisk major version to target. If omitted, the script will:
- Try to auto-detect the installed version (or fall back to 22 (LTS) if it cannot), and
- Prompt you to confirm or override the version, defaulting to the detected/fallback value.

--arch=<arch>
Override CPU architecture detection (e.g., amd64, arm64, armhf, i386, ppc64el). Accepts Debian arch names or kernel names (x86_64, aarch64). Auto-detected if omitted.

**Note:** Prebuilt modules (--downloadonly) are only available for amd64 architecture. Other architectures must build from source (default mode).

Examples:
- `--arch=amd64` (64-bit x86)
- `--arch=arm64` (64-bit ARM)
- `--arch=armhf` (32-bit ARM hard-float)
- `--arch=i386` (32-bit x86)
- `--arch=ppc64el` (64-bit PowerPC little-endian)

--lib=<path>
Override the library path where Asterisk modules are located. If omitted, the script will auto-detect based on the CPU architecture using multiarch paths.

Examples:
- `--lib=/usr/lib/x86_64-linux-gnu` (64-bit x86)
- `--lib=/usr/lib/aarch64-linux-gnu` (64-bit ARM)
- `--lib=/usr/lib/arm-linux-gnueabihf` (32-bit ARM hard-float)
- `--lib=/custom/path/to/asterisk` (custom installation path)

--dry-run
Show what actions would be taken (including selected Asterisk version, architecture, and URLs) without making any changes.

--debug
Alias for --dry-run.

--email <addr>
Email address to use for Let's Encrypt SSL; avoids the interactive email prompt.

--no-ssl
Skip Let's Encrypt / SSL installation step (alias: --skip-ssl).

--asterisk-only
Install Asterisk from source (standalone, no FreePBX). Prompts for installation prefix, optional systemd service, and optional sample configs. Respects --version, --email, --no-ssl, and --dry-run.
```

If you run `bash MSTeams-FreePBX-Install.sh` with no options, the script will:
- Detect or default the Asterisk major version and prompt you to confirm or override it, and
- Prompt for an email address to use for Let's Encrypt SSL.

To run non-interactively, specify `--version` and `--email`, or use `--no-ssl` to skip SSL entirely.

## Standalone Asterisk-only mode (`--asterisk-only`)

The script can also install Asterisk itself from source on a bare Debian 12 system, without FreePBX:

- Use `--asterisk-only` to trigger this mode.
- The script will still:
  - Detect or prompt for the Asterisk major version (or use `--version=<21|22|23>`),
  - Patch `res/res_pjsip_nat.c` to hard-code your server FQDN into CONTACT/VIA headers,
  - Optionally install Let's Encrypt SSL certificates (respecting `--email` / `--no-ssl`).

During `--asterisk-only` runs you will be prompted to:

- Choose an installation prefix (default: `/usr` with config in `/etc/asterisk` and data under `/var`).
- Decide whether to create and enable a `systemd` service unit at `/etc/systemd/system/asterisk.service`.
- Decide whether to install the sample configuration files (`make samples`).

`--asterisk-only` is **mutually exclusive** with `--downloadonly`, `--restore`, and `--copyback`.

## Why?
Organisations with MS Teams may want to enable their users to make phone calls from the MS Teams application. This is done with MS Teams Direct Routing.
<p align="center">
<img src="https://github.com/Vince-0/MSTeams-FreePBX/blob/9660cbc6282b76b1156d93897cc81612802bca68/MSTEAMS-Asterisk.png" />
</p>

MS Teams users get a phone calls dialpad inside their Teams client
<p align="center">
<img src="https://github.com/Vince-0/MSTeams-FreePBX/blob/bfe585223027dddd8220907ff325088090d5cb41/MSTeams-dialpad2.png" />
</p>


MS Teams does not officially support [Asterisk](https://en.wikipedia.org/wiki/Asterisk_(PBX)) as an SBC to connect VOIP services to MS Teams Direct Routing but [SIP](https://en.wikipedia.org/wiki/Session_Initiation_Protocol) is SIP and each implementation is **almost** close enough to work out of the box.

MS Teams uses an implementation of Session Initiation Protocol and [Asterisk](https://www.asterisk.org/) is a SIP back-to-back user agent. 

This allows Asterisk to bridge SIP channels together for example a telecoms provider on one side and an MS Teams Direct Routing channel on the other.

Asterisk implements a SIP channel driver called [PJSIP](https://github.com/pjsip/pjproject). PJSIP is a [GNU GPL](https://www.gnu.org/) [licensed](https://docs.pjsip.org/en/latest/overview/license_pjsip.html), multimedia communication library written in C.

By default the PJSIP NAT module does not present a FQDN in the CONTACT and VIA SIP headers so one can change this behavior in the module's source code.

Asterisk under FreePBX is an easy way to connect a SIP server with a GUI to MS Teams but any SIP switch/proxy like FreeSwitch or Kamailio could do it.

MS Teams can route media (audio) directly between MS Teams users and the SBC to shorten the path media takes, greatly decreasing latency and network hops and so increasing call quality and reliability. This requires an ICE (Interactive Connectivity Establishment) server configured in Asterisk to offer its public IP as a candidate for peer to peer connections for VOIP.

MS Teams offers a number of media codecs for VOIP calls but the best for Internet connections is SILK because it offers forward error correction, is quite tolerant of packet loss and has various bandwidth options.

## How

1. Prepare and install a custom PJSIP NAT module for Asterisk under FreePBX.

2. Configure TLS certificates from [Let's Encrypt](https://letsencrypt.org/) using [acme.sh](https://github.com/acmesh-official/acme.sh) for Asterisk to provide SRTP encryption on calls. This requires a publicly accessible DNS FQDN on your server.
  
3. Use FreePBX to control Asterisk dialplan to route calls in and out of MS Teams and any SIP connection like a telecoms carrier.

4. Configure MS Teams, with the appropriate "Phone System" licenses, to use MS Teams Direct Routing for your tenant's users via this Asterisk as an SBC.

## Compiled PJSIP NAT modules for Asterisk 21, 22 and 23 on Debian 12

Precompiled `res_pjsip_nat.so` modules for multiple Asterisk versions are available in the following repository (organised by Asterisk major version):

[Vince-0/MSTeamsPJSIPNAT_Debian12](https://github.com/Vince-0/MSTeamsPJSIPNAT_Debian12)

## Further Development

Requires testing for SSL, architectures, Raspberry Pi.

Operating system version and distribution options.

## Reference Links

[Asterisk Developer Mail List](https://asterisk-dev.digium.narkive.com/ucZYhaLE/asterisk-16-pjsip-invite-contact-field-and-fqdn#post12)

[Nick Bouwhuis](https://nick.bouwhuis.net/posts/2022-01-02-asterisk-as-a-teams-sbc)

[Ayonik](https://www.ayonik.de/blog/item/90-microsoft-teams-direct-routing-with-asterisk-pbx)

[godril at Otakudang.org](https://www.otakudang.org/?p=969)


## MS Documentation

[Plan Direct Routing](https://learn.microsoft.com/en-us/microsoftteams/direct-routing-border-controllers)

[Configure Voice Routing](https://learn.microsoft.com/en-us/microsoftteams/direct-routing-configure#configure-voice-routing)

[Media Bypass](https://learn.microsoft.com/en-us/microsoftteams/direct-routing-plan-media-bypass)




