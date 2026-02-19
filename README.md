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

--email=<addr>
Email address to use for Let's Encrypt SSL; avoids the interactive email prompt. If omitted, the script will prompt interactively (entering blank skips issuance and falls back to any existing certificate).

--fqdn=<name>
Override detected host FQDN (used for Let's Encrypt certificates and as the recommended PJSIP transport ms_signaling_address). If omitted, the script uses the system hostname. **Note:** the hostname must contain a dot (e.g. `sbc.example.com`); a bare name such as `localhost` will cause the script to abort.

--use-existing-cert
Use an existing certificate for the FQDN if found (non-interactive; skips issuance and renewal).

--no-ssl
Skip Let's Encrypt / SSL installation step (alias: --skip-ssl).

--asterisk-only
Install Asterisk from source (standalone, no FreePBX). Prompts for installation prefix, optional systemd service, and optional sample configs. Respects --version, --email, --use-existing-cert, --no-ssl, and --dry-run.
```

If you run `bash MSTeams-FreePBX-Install.sh` with no options, the script will:
- Auto-detect the Asterisk major version (falls back to 22 LTS) and prompt you to confirm or override it.
- Auto-detect CPU architecture and the Asterisk module library path — no prompt, silent.
- Auto-detect the system hostname as the FQDN — no prompt, silent (use `--fqdn` if the hostname is not a public FQDN).
- Prompt for an email address to use for Let's Encrypt SSL (entering blank falls back to any existing certificate).

To run non-interactively, specify `--version` and `--email`, or use `--no-ssl` to skip SSL entirely.

## Standalone Asterisk-only mode (`--asterisk-only`)

The script can also install Asterisk itself from source on a bare Debian 12 system, without FreePBX:

- Use `--asterisk-only` to trigger this mode.
- The script will still:
  - Detect or prompt for the Asterisk major version (or use `--version=<21|22|23>`),
  - Apply the Asterisk ms_signaling_address runtime patch to `res/res_pjsip_nat.c` so that the FQDN can be configured at runtime via `pjsip.conf` (no hard-coded FQDN),
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

By default the PJSIP NAT module does not present a FQDN in the CONTACT and VIA SIP headers, so this project applies a small patch to the module so that the FQDN can be set at runtime via the `ms_signaling_address` transport option in `pjsip.conf`.

Asterisk under FreePBX is an easy way to connect a SIP server with a GUI to MS Teams but any SIP switch/proxy like FreeSwitch or Kamailio could do it.

MS Teams can route media (audio) directly between MS Teams users and the SBC to shorten the path media takes, greatly decreasing latency and network hops and so increasing call quality and reliability. This requires an ICE (Interactive Connectivity Establishment) server configured in Asterisk to offer its public IP as a candidate for peer to peer connections for VOIP.

MS Teams offers a number of media codecs for VOIP calls but the best for Internet connections is SILK because it offers forward error correction, is quite tolerant of packet loss and has various bandwidth options.

## How

1. Prepare and install a custom PJSIP NAT module for Asterisk under FreePBX.

2. Configure TLS certificates from [Let's Encrypt](https://letsencrypt.org/) using [certbot](https://certbot.eff.org/) for Asterisk to provide SRTP encryption on calls. This requires a publicly accessible DNS FQDN on your server.
  
3. Use FreePBX to control Asterisk dialplan to route calls in and out of MS Teams and any SIP connection like a telecoms carrier.

4. Configure MS Teams, with the appropriate "Phone System" licenses, to use MS Teams Direct Routing for your tenant's users via this Asterisk as an SBC.

## Runtime FQDN configuration (`ms_signaling_address`)

This project uses an Asterisk PJSIP NAT patch based on the following upstream work:

<https://github.com/eagle26/asterisk/commit/8ee033215acf4e7de7b4aa415539d82a54eadf64>

The patch adds a new transport option `ms_signaling_address`. Instead of hard-coding the FQDN into `res/res_pjsip_nat.c` at build time, the module reads the FQDN from your PJSIP transport configuration at runtime.

The key parameters on your `transport` object in `pjsip.conf` are:

- `external_signaling_address` – the **public IP address** of your SBC as seen by MS Teams (usually your WAN IP or load balancer VIP).
- `external_signaling_port` – the **external SIP port** forwarded from the internet to Asterisk (typically `5061` for TLS).
- `ms_signaling_address` – the **FQDN** MS Teams expects to see in SIP Contact and Via headers (this must match the FQDN you configure in Microsoft 365 and on your TLS certificate).

To configure these options:

1. Choose the FQDN that will represent your SBC to MS Teams, for example `sbc.example.com`. This FQDN:
   - Must resolve in public DNS to your SBC public IP.
   - Must appear in the certificate presented by Asterisk (CN or SAN).
   - Must match what you configure in the Microsoft Teams Direct Routing/SBC settings.
2. Determine the public IP and port that MS Teams will use to reach your SBC:
   - `external_signaling_address` = that public IP address.
   - `external_signaling_port` = the TLS SIP port you expose (commonly `5061`).
3. Edit your PJSIP transport configuration:
   - On a plain Asterisk system, edit `/etc/asterisk/pjsip.conf` and add or update the appropriate `transport` section.
   - On a FreePBX system, add the transport in the appropriate custom file (for example `/etc/asterisk/pjsip.transports_custom.conf`), rather than editing the FreePBX‑managed `pjsip.conf` directly.
4. Set `ms_signaling_address` to the SBC FQDN you chose in step 1.
5. Reload PJSIP (for example from the Asterisk CLI with `pjsip reload` or via FreePBX) so the new transport settings take effect.

Example transport stanza:

```ini
[transport-ms-teams]
type=transport
protocol=tls
external_signaling_address=203.0.113.10
external_signaling_port=5061
ms_signaling_address=sbc.example.com
```

If `ms_signaling_address` is not set, Asterisk continues to use the existing behaviour based on `external_signaling_address` and `external_signaling_port`.

The install script:

- Applies the `ms_signaling_address` patch to the Asterisk sources whenever it builds from source (both default FreePBX mode and `--asterisk-only`).
- Or downloads precompiled `res_pjsip_nat.so` modules that were built from patched sources (see below).

## Compiled PJSIP NAT modules for Asterisk 21, 22 and 23 on Debian 12

Precompiled `res_pjsip_nat.so` modules for multiple Asterisk versions are available in the following repository (organised by Asterisk major version). These modules are built from sources that include the `ms_signaling_address` runtime FQDN patch described above (v2 and later):

[Vince-0/MSTeamsPJSIPNAT_Debian12](https://github.com/Vince-0/MSTeamsPJSIPNAT_Debian12)

## Further Development

Requires testing for SSL, CPU architectures, Raspberry Pi.

Operating system version and distribution options.

## Reference Links

### Run Time Patch

[Jose's](https://github.com/eagle26) run time [patch](https://github.com/asterisk/asterisk/compare/master...eagle26:asterisk:master)

### Related projects

For automated installation and building from source, see:

- [MSTeams-PJSIPNAT](https://github.com/Vince-0/MSTeams-PJSIPNAT) - Compiled res_pjsip_nat.so modules for Debian.


### Build Time Patch (Old Method)

[Vince-0/MSTeams-FreePBX](https://raw.githubusercontent.com/Vince-0/MSTeams-FreePBX/refs/heads/main/README-v1.md)

[Asterisk Developer Mail List](https://asterisk-dev.digium.narkive.com/ucZYhaLE/asterisk-16-pjsip-invite-contact-field-and-fqdn#post12)

[Nick Bouwhuis](https://nick.bouwhuis.net/posts/2022-01-02-asterisk-as-a-teams-sbc)

[Ayonik](https://www.ayonik.de/blog/item/90-microsoft-teams-direct-routing-with-asterisk-pbx)

[godril at Otakudang.org](https://www.otakudang.org/?p=969)


### MS Documentation

[Plan Direct Routing](https://learn.microsoft.com/en-us/microsoftteams/direct-routing-border-controllers)

[Configure Voice Routing](https://learn.microsoft.com/en-us/microsoftteams/direct-routing-configure#configure-voice-routing)

[Media Bypass](https://learn.microsoft.com/en-us/microsoftteams/direct-routing-plan-media-bypass)




