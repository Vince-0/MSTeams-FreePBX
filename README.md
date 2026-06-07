# VOIP Microsoft Teams Gateway
Connect phone VOIP calls from MS Teams using Direct Routing compatible patched PJSIP modules for Asterisk under FreePBX.

Author [https://github.com/Vince-0](https://github.com/Vince-0/Projects)

Use at your own risk.

## Attribution
Updates provided by [Rowan S](https://github.com/rowansc1) for source versions and directory fixes in [Pull #7](https://github.com/Vince-0/MSTeams-FreePBX/pull/7)

## What?
This BASH [script](https://github.com/Vince-0/MSTeams-FreePBX/blob/main/MSTeams-FreePBX-Install.sh) compiles Asterisk from source, applies the `ms_signaling_address` patch, and deploys the full patched PJSIP module set (`res_pjsip*.so` + `chan_pjsip.so`) into FreePBX Asterisk to act as an SBC for MS Teams Direct Routing VOIP calls.

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

By default the PJSIP NAT module does not present a FQDN in the CONTACT and VIA SIP headers. This project applies a small patch across `res_pjsip.so` (which stores the transport configuration) and `res_pjsip_nat.so` (which rewrites the headers) so that the FQDN can be set at runtime via the `ms_signaling_address` transport option in `pjsip.conf`. Because the patch changes structs from `res_pjsip.h`, every module compiled against those structs must come from the same build tree. That means all `res_pjsip*.so` modules and `chan_pjsip.so` are deployed together as a matched full PJSIP module set.

Asterisk under FreePBX is an easy way to connect a SIP server with a GUI to MS Teams but any SIP switch/proxy like FreeSwitch or Kamailio could do it.

MS Teams can route media (audio) directly between MS Teams users and the SBC to shorten the path media takes, greatly decreasing latency and network hops and so increasing call quality and reliability. This requires an ICE (Interactive Connectivity Establishment) server configured in Asterisk to offer its public IP as a candidate for peer to peer connections for VOIP.

MS Teams offers a number of media codecs for VOIP calls but the best for Internet connections is SILK because it offers forward error correction, is quite tolerant of packet loss and has various bandwidth options.

## How

1. Compile Asterisk from source with the `ms_signaling_address` patch and deploy the patched full PJSIP module set (`res_pjsip*.so` + `chan_pjsip.so`) into FreePBX Asterisk.

2. Configure TLS certificates from [Let's Encrypt](https://letsencrypt.org/) using [certbot](https://certbot.eff.org/) for Asterisk to provide SRTP encryption on calls. This requires a publicly accessible DNS FQDN on your server.
  
3. Use FreePBX to control Asterisk dialplan to route calls in and out of MS Teams and any SIP connection like a telecoms carrier.

4. Configure MS Teams, with the appropriate "Phone System" licenses, to use MS Teams Direct Routing for your tenant's users via this Asterisk as an SBC.
  
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
Downloads and installs a prebuilt full PJSIP module bundle from Vince-0's GitHub repo and installs it into FreePBX Asterisk.

--restore
Restore original PJSIP modules from `.ORIG` backups (`res_pjsip*.so` + `chan_pjsip.so`).

--copyback
Copy the MSTeams-compatible patched PJSIP module set back from `.MSTEAMS` copies.

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

## Standalone Asterisk-only mode

The script can also install Asterisk itself from source on a bare Debian 12 system, without FreePBX:

- Use `--asterisk-only` to trigger this mode.
- The script will still:
  - Detect or prompt for the Asterisk major version (or use `--version=<21|22|23>`),
  - Apply the `ms_signaling_address` runtime patch to the PJSIP sources so that the FQDN can be configured at runtime via `pjsip.conf` (no hard-coded FQDN),
  - Optionally install Let's Encrypt SSL certificates (respecting `--email` / `--no-ssl`).

During `--asterisk-only` runs you will be prompted to:

- Choose an installation prefix (default: `/usr` with config in `/etc/asterisk` and data under `/var`).
- Decide whether to create and enable a `systemd` service unit at `/etc/systemd/system/asterisk.service`.
- Decide whether to install the sample configuration files (`make samples`).

`--asterisk-only` is **mutually exclusive** with `--downloadonly`, `--restore`, and `--copyback`.


## Runtime FQDN configuration (`ms_signaling_address`)

This project uses an Asterisk PJSIP NAT patch based on the following upstream work:

<https://github.com/eagle26/asterisk/commit/8ee033215acf4e7de7b4aa415539d82a54eadf64>

The patch adds a new transport option `ms_signaling_address`. Instead of hard-coding the FQDN at build time, it is read from your PJSIP transport configuration at runtime. The patch touches three source files: `include/asterisk/res_pjsip.h` (struct definition), `res/res_pjsip/config_transport.c` (config parsing, compiled into `res_pjsip.so`), and `res/res_pjsip_nat.c` (header rewriting, compiled into `res_pjsip_nat.so`). Because `res_pjsip.h` defines structs used across the PJSIP module family, every `res_pjsip*.so` module and `chan_pjsip.so` must be replaced from the same patched build.

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
bind=0.0.0.0:5061
cert_file=/etc/letsencrypt/live/sbc.example.com/fullchain.pem
priv_key_file=/etc/letsencrypt/live/sbc.example.com/privkey.pem
method=tlsv1_2
external_signaling_address=XXX.XXX.XXX.XXX    ; public IP address of your SBC
external_signaling_port=5061               ; external SIP TLS port
ms_signaling_address=sbc.example.com      ; FQDN — must match your certificate CN
```

**TLS certificate requirements:**
- MS Teams Direct Routing requires an **RSA** certificate. ECDSA certificates (e.g. issued by Let's Encrypt's E5/E6/E7 CAs) will cause a TLS handshake failure (`no shared cipher`).
- `cert_file` **must** point to `fullchain.pem` (leaf certificate + all intermediate CA certificates), never to `cert.pem` (leaf only). MS Teams validates the entire certificate chain; if any intermediate is missing the TLS handshake fails and Teams drops the SIP connection silently or with a timeout.
- To obtain an RSA certificate with certbot: `certbot certonly --key-type rsa --rsa-key-size 2048 -d sbc.example.com`
- The FQDN in `ms_signaling_address` must match the certificate Common Name (CN) and the SBC hostname configured in Microsoft 365.

> **⚠️ Important: ECDSA certificates cause Asterisk to crash — always use RSA**
>
> Certbot version 2.0 and later (the version shipped with Debian 12 Bookworm) changed its default key type from RSA to **ECDSA**. Unless RSA is explicitly requested, certbot silently issues an ECDSA certificate.
>
> MS Teams Direct Routing only accepts **RSA** certificates on the SBC's TLS transport. When Teams periodically pings the SBC (roughly every 60 seconds) and receives an ECDSA certificate during the TLS handshake, Asterisk's PJSIP TLS stack hits an unhandled code path and **terminates with a core dump**. This repeats on every ping, making the SBC completely unstable.
>
> The install script fixes this by passing `--key-type rsa --rsa-key-size 2048` to every `certbot` invocation (both new issuance and renewal), ensuring all certificates are 2048-bit RSA regardless of the certbot version installed.
>
> If you manage certificates manually or use an existing certificate, verify the key type before deploying:
> ```bash
> openssl x509 -in /etc/letsencrypt/live/<your-fqdn>/cert.pem -noout -text | grep "Public Key Algorithm"
> # Must output: rsaEncryption — not id-ecPublicKey
> ```
> To replace an existing ECDSA certificate with an RSA one:
> ```bash
> certbot certonly --standalone --key-type rsa --rsa-key-size 2048 -d <your-fqdn>
> ```

> **🔍 Troubleshooting: TLS handshake failures — `cert.pem` vs `fullchain.pem`**
>
> If MS Teams cannot establish a SIP TLS connection to the SBC, one of the most common root causes is that `cert_file` in the PJSIP transport stanza points to `cert.pem` (the leaf certificate only) rather than `fullchain.pem` (the leaf certificate plus all intermediate CA certificates). MS Teams validates the **entire** certificate chain; a missing intermediate causes the TLS handshake to fail, and Teams either times out or drops the TCP connection without sending any SIP traffic.
>
> **Symptoms:** Teams shows the SBC as unreachable; no `OPTIONS` ping responses appear; SIP trunk stays down.
>
> **Diagnose with `sngrep`:**
> ```bash
> apt install sngrep
> sngrep port 5061
> ```
> Watch for incoming connections from Microsoft's SIP proxy IP ranges on port 5061. If you see a TCP session open and close immediately with no SIP messages visible, the TLS handshake failed before any SIP was exchanged — this is the signature of a missing certificate chain.
>
> **Fix:** Ensure `cert_file` in your PJSIP transport block uses `fullchain.pem`:
> ```ini
> cert_file=/etc/letsencrypt/live/<your-fqdn>/fullchain.pem   ; correct — full chain
> # cert_file=/etc/letsencrypt/live/<your-fqdn>/cert.pem      ; wrong  — leaf only
> ```
> Restart Asterisk after correcting the path (`fwconsole restart` or `systemctl restart asterisk`), then recheck with `sngrep` — you should now see complete TLS handshakes followed by SIP `OPTIONS` messages.

If `ms_signaling_address` is not set, Asterisk continues to use the existing behaviour based on `external_signaling_address` and `external_signaling_port`.

The install script:

- Applies the `ms_signaling_address` patch to the Asterisk sources and deploys the full matched PJSIP module set (`res_pjsip*.so` + `chan_pjsip.so`) in default FreePBX mode. In `--asterisk-only` mode, the patched Asterisk tree is built and installed as a complete standalone install.

## Compiled PJSIP module set for Asterisk 21, 22 and 23 on Debian 12

Precompiled full PJSIP module bundles for Asterisk 21, 22 and 23 on Debian 12 amd64 are available in the following repository. Each major-version folder contains every `res_pjsip*.so` module plus `chan_pjsip.so`, built from the same patched source tree:

[Vince-0/MSTeams-PJSIPNAT](https://github.com/Vince-0/MSTeams-PJSIPNAT/tree/main/prebuilt/debian12-amd64)

The installer `--downloadonly` mode fetches from `prebuilt/debian12-<arch>/asterisk-<major>/`, verifies ABI compatibility, backs up originals as `.ORIG`, saves patched copies as `.MSTEAMS`, and deploys the modules together.

## Further Development

Requires testing for SSL, CPU architectures, Raspberry Pi.

Operating system version and distribution options.

See [Unit-Testing.md](Unit-Testing.md) for the CI/CD pipeline setup, current ShellCheck status,
and the phased roadmap for adding BATS unit tests and regression guards.

### `--upgrade-asterisk` mode

Add an `--upgrade-asterisk` mode to `MSTeams-FreePBX-Install.sh` that upgrades (or downgrades) the running Asterisk installation to a specified major version, then automatically applies the `ms_signaling_address` PJSIP patch to the newly installed version.

**Requirements:**

1. **New flag**: `--upgrade-asterisk` — must be used together with `--version=<21|22|23>`. Using `--upgrade-asterisk` without `--version` should abort with a clear error. If the specified version already matches the running major version, print a message and exit cleanly (nothing to do).

2. **Pre-upgrade safety checks** (abort if any fail):
   - Confirm FreePBX is present (`fwconsole` on PATH) — this mode targets FreePBX systems only.
   - Confirm the target version is in `SUPPORTED_AST_VERSIONS`.
   - Warn clearly that this is a **destructive, service-interrupting operation** and require explicit `--yes` confirmation to proceed (same pattern as other destructive operations in the script).
   - Back up the current `/etc/asterisk/` configuration directory before proceeding.

3. **Upgrade steps** (in order):
   - Stop Asterisk/FreePBX gracefully (`fwconsole stop`).
   - Remove the currently installed Asterisk packages (e.g. `apt-get remove --purge asterisk*` or equivalent for the detected package manager).
   - Download and install the target Asterisk major version from source using the same `asterisk-XX-current.tar.gz` download mechanism already used by the script's build path.
   - Run `make install` and `make config` for the new version.
   - Restore `/etc/asterisk/` configuration from backup.
   - Reload FreePBX module state (`fwconsole chown && fwconsole reload`).

4. **Post-upgrade patch**: After the Asterisk upgrade completes and the new version is confirmed running (`asterisk -V` matches the target major version), automatically proceed with the standard PJSIP patch build-and-deploy flow (same as running the script without `--upgrade-asterisk`), including `.ORIG` backups and matched-set deployment of all `res_pjsip*.so` modules plus `chan_pjsip.so`.

5. **Update `show_help()`**, `confirm_run_options()`, and the end-of-run summary to describe the new mode accurately.


## Reference Links

### Run Time Patch

[Jose's](https://github.com/eagle26) run time [patch](https://github.com/asterisk/asterisk/compare/master...eagle26:asterisk:master)

### Upstream effort — native `external_signaling_hostname` transport option

There is an open Asterisk upstream pull request to add a native `external_signaling_hostname` transport option directly to PJSIP, which would make this runtime patch unnecessary:

[asterisk/asterisk#1960 — Add external_signaling_hostname transport option](https://github.com/asterisk/asterisk/pull/1960)

If merged, a future Asterisk release would support setting the FQDN in SIP Contact and Via headers via `pjsip.conf` without any source patch or module replacement.

### Related projects

For automated installation and building from source, see:

- [MSTeams-PJSIPNAT](https://github.com/Vince-0/MSTeams-PJSIPNAT) - Prebuilt full PJSIP module bundles for Debian 12 amd64.


### Build Time Patch (Old Method)


[Asterisk Developer Mail List](https://asterisk-dev.digium.narkive.com/ucZYhaLE/asterisk-16-pjsip-invite-contact-field-and-fqdn#post12)

[Nick Bouwhuis](https://nick.bouwhuis.net/posts/2022-01-02-asterisk-as-a-teams-sbc)

[Ayonik](https://www.ayonik.de/blog/item/90-microsoft-teams-direct-routing-with-asterisk-pbx)

[godril at Otakudang.org](https://www.otakudang.org/?p=969)


### MS Documentation

[Plan Direct Routing](https://learn.microsoft.com/en-us/microsoftteams/direct-routing-border-controllers)

[Configure Voice Routing](https://learn.microsoft.com/en-us/microsoftteams/direct-routing-configure#configure-voice-routing)

[Media Bypass](https://learn.microsoft.com/en-us/microsoftteams/direct-routing-plan-media-bypass)




