# MS Teams Direct Routing Wizard — Implementation Plan

**New script**: `MSTeams-DR-Wizard.sh`
**Supersedes**: `MSTeams-FreePBX-Install.sh` (legacy, Asterisk 21 patch-based)
**Approach**: Native `external_signaling_hostname` transport option (Asterisk PR #1960)
**No source patching. No module replacement.**

---

## Locked Design Decisions

| Question | Decision |
|---|---|
| FreePBX config method | `_custom.conf` file injection only — no `fwconsole` DB/GUI changes |
| Greenfield install | Vanilla Asterisk only — no FreePBX installation |
| Asterisk 21 handling | Out of scope here — separate patch plan to follow |

---

## Supported Versions (native `external_signaling_hostname`)

| Branch | Minimum version | Notes |
|---|---|---|
| 20 | 20.21.0 | LTS; cherry-picked from master |
| 22 | 22.11.0 | LTS; cherry-picked from master |
| 23 | 23.5.0 | Standard; cherry-picked from master |
| 24+ | any | Merged natively in master before first release |
| 21 | ❌ none | EOL before backport — future separate plan |

---

## Script Modes

| Flag | Purpose |
|---|---|
| *(no flag)* | Interactive wizard: detect environment, configure transport |
| `--greenfield` | Build and install vanilla Asterisk from source, then configure |
| `--check` | Read-only audit: version, cert, DNS, firewall, transport config |
| `--ssl-only` | Certificate management only (issue/renew RSA cert via certbot) |
| `--generate-config` | Print PJSIP config snippets to stdout without writing files |
| `--dry-run` / `--debug` | Show all actions without making any changes |
| `-h` / `--help` | Show usage |

Mutually exclusive: `--greenfield` cannot be combined with `--check` or `--ssl-only`.

---

## Phase 0 — Script Scaffolding ✅ COMPLETE

- [x] **P0-01** Create `MSTeams-DR-Wizard.sh` with shebang, `set -euo pipefail`, and top-level comment block.
- [x] **P0-02** Port `message()`, `terminate()`, `cleanup()`, logging, and PID-file guard.
- [x] **P0-03** Define global variables: `WIZARD_VERSION`, `MIN_NATIVE_VERSION` map, `NATIVE_SUPPORTED_MAJORS`.
- [x] **P0-04** Implement `show_help()` covering all modes and flags.
- [x] **P0-05** Implement argument parser (long-opts) covering all flags.
- [x] **P0-06** Implement mutual-exclusion guard for incompatible mode flags.
- [x] **P0-07** Port `detect_cpu_arch()`, `detect_debian_arch()`, `map_to_debian_arch()`, `map_to_kernel_arch()`.
- [x] **P0-08** Port OS validation (Debian 12 check).
- [x] **P0-09** Add `--fqdn`, `--email`, `--no-ssl`, `--use-existing-cert`, `--version` flags.
- [x] **P0-10** Add `confirm_run_options()` summary + y/n prompt.

**Notes:**
- `exec 2>>"$LOG_FILE"` placed inside `main()` (after pidfile creation) so pre-`main` argument errors reach the terminal.
- SC2034 (unused vars) suppressed via `: "${VAR:-}"` null-reference block at end of globals — these vars are used by Phases 1-10.
- `detect_asterisk_major()` and `check_native_support_stub()` included as stubs; replaced by full semver logic in Phase 1.
- `dry_run_gate()` and `dry_run_write_file()` helpers implemented and ready for use in Phases 2-10.

**Verified:** `bash -n` PASS · `shellcheck -S warning` CLEAN · `--help` exit 0 · `--check --greenfield` exit 1 · `--bogus` exit 1 · `--version=21` exit 1 · `--check --fqdn=sbc.example.com` exit 0

---

## Phase 1 — Asterisk Version Detection & Upgrade Path ✅ COMPLETE

- [x] **P1-01** `detect_asterisk_full_version()` — parses `asterisk -V`; handles 3-part and 4-part security-release versions.
- [x] **P1-02** `semver_gte()` — compares MAJOR.MINOR.PATCH[.SECURITY] without external deps.
- [x] **P1-03** `check_native_support()` — outputs `STATUS full_ver` on stdout; all log output to stderr. Statuses: `SUPPORTED`, `UPGRADE_NEEDED`, `UNSUPPORTED_BRANCH`, `NOT_INSTALLED`, `UNKNOWN_BRANCH`.
- [x] **P1-04** `handle_version_check()` — interactive upgrade-or-quit prompt on `UPGRADE_NEEDED`; hard-exit on `UNSUPPORTED_BRANCH` (Asterisk 21); greenfield path on `NOT_INSTALLED`.
- [x] **P1-05** `UNSUPPORTED_BRANCH`: prints clear message, points to legacy script, aborts exit 1.
- [x] **P1-06** `NOT_INSTALLED`: defers to greenfield path or aborts with instructions.
- [x] **P1-07** FreePBX detection (`fwconsole`) already done in Phase 0.

**Notes:**
- `check_native_support` uses `echo "STATUS full_ver"` protocol so callers can `read -r status ver` without subshell variable-propagation issues.
- `message()` redirected to `>&2` inside `check_native_support` to keep stdout clean for capture.
- BASH_SOURCE guard restructured: all function definitions at top level; only arg parser + mutual exclusion check + `main "$@"` wrapped in the guard.
- Unit test at `/tmp/test_phase1.sh` (25/25 PASS).

**Verified:** `bash -n` PASS · `shellcheck -S warning` CLEAN · 25/25 unit tests pass · real Asterisk 22.7.0 detected as UPGRADE_NEEDED with correct min version (22.11.0) · Asterisk 21 exits 1 · BASH_SOURCE sourcing works cleanly

---

## Phase 2 — RSA Certificate Management ✅ COMPLETE

- [x] **P2-01** `install_ssl()` — port of `install_letsencrypt()` from legacy; no `ms_signaling_address` references.
- [x] **P2-02** RSA enforcement: all certbot calls include `--key-type rsa --rsa-key-size 2048`.
- [x] **P2-03** `verify_cert_is_rsa()` — checks `openssl x509` public key algorithm; warns on ECDSA with crash explanation.
- [x] **P2-04** `verify_cert_chain()` — checks that `cert_file` ends in `fullchain.pem`; prints fix instructions if bare `cert.pem`.
- [x] **P2-05** `cert_expiry_check()` — configurable threshold (default 30 days); warns on near-expiry or expired cert with renewal command.
- [x] **P2-06** `verify_fqdn_matches_cert()` — checks CN and SAN DNS entries; handles wildcard certs.
- [x] **P2-07** `check_tls_cert()` — combined read-only audit; used by `--check` mode (Phase 10) and end of `install_ssl`.
- [x] **P2-08** `--ssl-only` mode wired to `install_ssl()`.
- [x] **P2-09** `_install_certs_from_dir()`, `_stop_apache2()`, `_restart_apache2()`, `_show_cert_expiry()` helpers — all dry-run-aware.
- [x] **P2-10** `install_ssl` called from interactive wizard and greenfield paths.

**Verified:** `bash -n` PASS · `shellcheck -S warning` CLEAN · 15/15 unit tests pass (using openssl-generated RSA and ECDSA certs) · `--ssl-only --dry-run` prints certbot command with `--key-type rsa --rsa-key-size 2048`, exit 0

---

## Phase 3 — FQDN & DNS Validation ✅ COMPLETE

- [x] **P3-01** `resolve_fqdn()` — reads system hostname (`hostname -f`); validates dot-in-name; sets global `$FQDN`.
- [x] **P3-02** `detect_public_ip()` — tries ipify, ifconfig.me, icanhazip then `ip route get`; sets global `$PUBLIC_IPV4`.
- [x] **P3-03** `verify_dns_resolution()` — resolves FQDN via `dig`/`host`; compares to `$PUBLIC_IPV4`; warns on mismatch (never aborts).
- [x] **P3-04** `dns_check_with_confirm()` — interactive wrapper: warns on DNS mismatch; requires y/N confirmation; skips prompt in read-only/dry-run modes.
- [x] **P3-05** `--check` mode runs `verify_dns_resolution` + `check_tls_cert` non-interactively; version mismatch no longer prompts in `--check`/`--dry-run`/`--generate-config`.

**Verified:** 12/12 unit tests pass · `--check --fqdn=open-stock.bnr.la` runs fully non-interactively, exit 0.

---

## Phase 4 — PJSIP Transport Configuration Wizard ✅ COMPLETE

- [x] **P4-01** `prompt_transport_params()` — interactively collects FQDN, public IP, SIP port (default 5061), bind address, cert/key paths with sensible auto-detected defaults.
- [x] **P4-02** `set_transport_defaults()` — non-interactive default population for `--generate-config --dry-run` and pre-flight use.
- [x] **P4-03** `generate_transport_stanza()` — outputs `[transport-ms-teams-tls]` block using `external_signaling_hostname` (never `ms_signaling_address`); includes `method=tlsv1_2`, `verify_client=no`.
- [x] **P4-04** `backup_config_file()` — timestamped `.WIZARD_BACKUP.<ts>` copy; never overwrites existing backup; dry-run-aware.
- [x] **P4-05** `inject_transport_config()` — idempotent: detects existing stanza, prompts to overwrite (y/N), removes old block before re-injection; dry-run-aware.
- [x] **P4-06** `reload_pjsip_transport()` — standalone: `asterisk -rx 'pjsip reload'` (dry-run-gated); FreePBX: prints `fwconsole reload` instruction only.
- [x] **P4-07** `run_transport_wizard()` — orchestrates prompt → generate → confirm → inject → reload.
- [x] **P4-08** `--generate-config` mode: calls `set_transport_defaults` + optional interactive `prompt_transport_params`; prints stanza to stdout; no files modified.
- [x] **P4-09** `dry_run_gate()` fixed to return 1 in dry-run mode (was returning 0) so `if dry_run_gate ...; then` correctly guards all destructive operations.

**Verified:** `bash -n` PASS · `shellcheck -S warning` CLEAN · 20/20 unit tests pass · `--generate-config --dry-run --fqdn=sbc.example.com` prints stanza with `external_signaling_hostname` and `method=tlsv1_2`, exit 0, no files modified.

---

## Phase 5 — MS Teams PJSIP Endpoint Templates ✅ COMPLETE

- [x] **P5-01** `generate_endpoint_stanza()` — outputs `[MSTeams]` endpoint, `[MSTeams]` aor (3 MS SIP proxy contacts), `[identify-MSTeams]` with all 5 Microsoft IP ranges.
- [x] **P5-02** Endpoint defaults: `transport=transport-ms-teams-tls`, `disallow=all`, `allow=ulaw,alaw,g722`, `direct_media=no`, `ice_support=yes`, `rtp_symmetric=yes`, `rewrite_contact=yes`, `send_rpid=yes`, `timers=no`, `aors=MSTeams`.
- [x] **P5-03** All 5 Microsoft IP ranges as `match=` entries in `[identify-MSTeams]`.
- [x] **P5-04** `inject_endpoint_config()` — idempotent injection into `$PJSIP_ENDPOINT_CONF`; prompts overwrite (y/N); backs up before write.
- [x] **P5-05** `ensure_pjsip_include()` — standalone only: appends `#include pjsip_msteams_endpoint.conf` to `pjsip.conf` if absent; idempotent; FreePBX is no-op.
- [x] **P5-06** `prompt_endpoint_params()` / `set_endpoint_defaults()` — interactive + non-interactive param collection; FreePBX defaults to `from-trunk`, standalone to `from-external`.
- [x] **P5-07** `run_endpoint_wizard()` — full Phase 5 flow: prompt → generate → confirm → inject → ensure include.
- [x] **P5-08** `--generate-config` prints both transport and endpoint/AOR/identify stanzas to stdout with target-file banners; no files modified.

**Verified:** 39/39 unit tests pass · `--generate-config --dry-run` prints both stanzas with all 5 IP ranges, exit 0 · total regression: 96/96 tests pass across all phases.

---

## Phase 6 — Firewall & Connectivity Validation ✅ COMPLETE

- [x] **P6-01** `_check_port_bound(port)` — checks TCP binding via `ss -tlnp`; extracts process name if available; returns 0 if bound, 1 if not; graceful if `ss` absent.
- [x] **P6-02** `_check_ufw_port(port)` — checks ufw status non-interactively; warns with `ufw allow <port>/tcp` fix if port is missing; no-op if ufw absent or inactive.
- [x] **P6-03** `_check_iptables_port(port)` — best-effort iptables check (silently skips on permission denied); warns on DROP default policy with no ACCEPT for the port.
- [x] **P6-04** `print_msteams_connectivity_info()` — prints all 3 MS SIP proxy FQDNs, OPTIONS-ping info, and `sngrep`/`tcpdump` capture commands.
- [x] **P6-05** `check_firewall_ports()` — orchestrates all sub-checks; informational only (never aborts); returns 0 only if all checks pass.
- [x] **P6-06** Wired into `--check` mode (after cert audit) and end of interactive + greenfield wizard modes.

**Verified:** 24/24 unit tests pass (mocked `ss`, `ufw`, `iptables`) · `--check --fqdn=open-stock.bnr.la` prints port/firewall/proxy section, exit 0 · total regression: 120/120 pass.

---

## Phase 7 — Greenfield Vanilla Asterisk Install ✅ COMPLETE

`--greenfield` builds and installs a clean Asterisk from source on a bare Debian 12 system. No FreePBX. No PJSIP patch.

- [x] **P7-01** `select_asterisk_tarball(major)` — sets `TARBALL` / `TARBALL_URL` using `asterisk-<major>-current.tar.gz` from `downloads.asterisk.org` (greenfield always uses -current; no existing binary to pin against).
- [x] **P7-02** `download_asterisk_source()` — downloads tarball to `$SRCDIR`; skips if cached; dry-run-aware.
- [x] **P7-03** `extract_asterisk_source()` — removes old source trees for idempotency, extracts tarball, sets `ASTERISK_SRC_DIR`; dry-run-aware.
- [x] **P7-04** `install_build_prereqs()` — runs `contrib/scripts/install_prereq install` from inside the extracted source tree; dry-run-aware.
- [x] **P7-05** `prompt_install_prefix()` — interactive prefix prompt (default `/usr`); sets `ASTERISK_PREFIX`, `ASTERISK_SYSCONFDIR`, `ASTERISK_LOCALSTATEDIR`; skipped in dry-run with defaults shown.
- [x] **P7-06** `configure_asterisk_build()` — runs `./configure --prefix --sysconfdir --localstatedir`; dry-run-aware.
- [x] **P7-07** `compile_and_install_asterisk()` — runs `make && make install`; dry-run-aware.
- [x] **P7-08** `verify_installed_version()` — calls `check_native_support()` on newly installed binary; aborts on `UPGRADE_NEEDED`; warns on ambiguous states. (P7-04 requirement)
- [x] **P7-09** `create_asterisk_systemd_service()` / `prompt_systemd_service()` — writes `asterisk.service`, runs `systemctl enable`; dry-run prints unit file content.
- [x] **P7-10** `prompt_make_samples()` — optional `make samples`; dry-run-aware; default N.
- [x] **P7-11** `print_greenfield_summary()` — completion summary with binary/config paths and next-step commands.
- [x] **P7-12** `build_asterisk_from_source()` — orchestrates all above steps; called from GREENFIELD MODE dispatch, which then chains Phase 2–6 (SSL → transport → endpoint → firewall check).

**Verified:** 44/44 unit tests pass (all dry-run, tarball URL, prefix defaults, verify_installed_version branches) · `--greenfield --version=22 --dry-run --fqdn=sbc.example.com` prints full action plan including download URL, configure flags, make commands, systemd unit, and transport config · total regression: 164/164 pass.

---

## Phase 8 — Brownfield: Existing Installation Configuration

Detect and configure an existing Asterisk (with or without FreePBX).

- [ ] **P8-01** On wizard entry (no `--greenfield`): run `check_native_support()`; if `SUPPORTED`, proceed; if `UPGRADE_NEEDED`, prompt and offer upgrade; if `NOT_INSTALLED`, redirect to `--greenfield`.
- [ ] **P8-02** Implement `offer_asterisk_upgrade()` — downloads and builds the latest tarball for the same major branch; runs `make install` without overwriting `/etc/asterisk`; restarts Asterisk.
- [ ] **P8-03** Before any upgrade or config change: back up `/etc/asterisk/` → `/etc/asterisk.WIZARD_BACKUP.<timestamp>/`.
- [ ] **P8-04** After upgrade, re-run `check_native_support()` to confirm version now meets threshold before proceeding.
- [ ] **P8-05** Detect existing `[transport-ms-teams-tls]` stanza in target config file; offer to update in-place or skip.

**Verification**: `--check` on a system with Asterisk 22.10.0 reports `UPGRADE_NEEDED: minimum 22.11.0 required` and lists upgrade option.

---

## Phase 9 — Dry-Run & Safety Mechanisms ✅ COMPLETE

- [x] **P9-01** All file-write operations gated behind `dry_run_gate()` with a matching `"[DRY-RUN] Would write: <path>"` message.
- [x] **P9-02** All `asterisk -rx` reload calls gated with dry-run guard.
- [x] **P9-03** All `apt-get`, `make install`, `certbot` calls gated with dry-run guard.
- [x] **P9-04** `--dry-run` mode prints a full action plan with file paths, version strings, URLs, and config snippets — enough to manually reproduce every step.
- [x] **P9-05** `backup_etc_asterisk()` — copies `/etc/asterisk` to a timestamped `.WIZARD_BACKUP.<ts>` directory; sets `LAST_BACKUP_PATH` global; dry-run-aware.
- [x] **P9-06** `restore_etc_asterisk()` — lists available snapshots (sorted newest-first), numbered prompt, double-confirm (`yes` required), takes a pre-restore safety backup, then `rm -rf` + `cp -a`; dry-run-aware.

**Verified:** `bash -n` PASS · `shellcheck -S warning` CLEAN · 24/24 Phase 9+10 unit tests pass · restore dry-run shows plan without touching files · live restore verifies file content replaced · cancel/invalid input handled gracefully.

---

## Phase 10 — `--check` Audit Mode ✅ COMPLETE

Runs all read-only checks and prints a structured report. No changes made.

- [x] **P10-01** Asterisk version vs. minimum threshold — `check_native_support` result shown with SUPPORTED / UPGRADE_NEEDED / UNSUPPORTED_BRANCH labels.
- [x] **P10-02** FreePBX detected: yes/no — shown in Environment section.
- [x] **P10-03** FQDN detection and DNS resolution check — `verify_dns_resolution` integrated.
- [x] **P10-04** Cert file: RSA check, chain check, expiry check — `check_tls_cert` integrated.
- [x] **P10-05** `check_external_signaling_hostname()` — greps all `*.conf` files under `/etc/asterisk` for `external_signaling_hostname`; reports value and FQDN match/mismatch.
- [x] **P10-06** Port 5061 binding check — `check_firewall_ports` integrated.
- [x] **P10-07** `_chk_fail` counter tracks failing checks; `terminate "$_chk_fail"` — exits 0 if all pass, N if N checks fail (CI-safe).

**Verified:** `--check` exits 0 on passing environment; exits with count of failures when checks fail; banner summarises pass/fail; 24/24 unit tests pass.

---

## Phase 11 — Testing ✅ COMPLETE (automated); manual checklists below

- [x] **P11-01** ShellCheck clean: `shellcheck -x -S warning MSTeams-DR-Wizard.sh` — 0 findings.
- [x] **P11-02** Syntax check: `bash -n MSTeams-DR-Wizard.sh` — passes.
- [x] **P11-03** BATS 1.8.2 test suite — `tests/wizard.bats` — **25/25 pass**:
  - `semver_gte`: 8 tests — equal, patch ahead, minor ahead, major ahead, patch below, 4-part security below, empty string, single-component.
  - `check_native_support`: 6 tests — SUPPORTED (22.11.0, 20.21.0, 24.0.0), UPGRADE_NEEDED (22.10.9), UNSUPPORTED_BRANCH (21.3.0), NOT_INSTALLED.
  - `generate_transport_stanza`: 5 tests — section header, external_signaling_hostname, method=tlsv1_2, verify_client=no, bind address.
  - `--dry-run`: 3 tests — no file writes (monitored temp dir), exits 0, FQDN in output.
  - `--check`: 3 tests — exits non-zero with missing cert, audit header present, WARNING printed.
- **Total automated tests: 244/244 pass** (219 bash + 25 BATS)

**Verified:** `bats tests/wizard.bats` — 25 tests, 0 failures.

### P11-04 — Manual Integration Checklist: FreePBX Brownfield

> Run these on a live FreePBX system before production deployment.

```bash
# 1. Pre-flight audit (read-only)
bash MSTeams-DR-Wizard.sh --check --fqdn=<your-sbc-fqdn>
# Expected: exit 0 if all pass; non-zero lists failures to fix first

# 2. Dry-run (verify planned actions, no changes)
bash MSTeams-DR-Wizard.sh --dry-run --fqdn=<your-sbc-fqdn>
# Expected: full action plan printed; no files written

# 3. Live run
bash MSTeams-DR-Wizard.sh --fqdn=<your-sbc-fqdn>
# Expected: wizard completes; confirm the following:

# 4. Verify transport config written
grep external_signaling_hostname /etc/asterisk/pjsip.transports_custom_post.conf
# Expected: external_signaling_hostname = <your-sbc-fqdn>

# 5. Reload FreePBX
fwconsole reload
# Expected: exits 0, no PJSIP errors in output

# 6. Verify Asterisk picked up the config
asterisk -rx 'pjsip show transports'
# Expected: transport-ms-teams-tls listed with external_signaling_hostname
```

### P11-05 — Manual Integration Checklist: Greenfield Vanilla Asterisk

> Run these on a fresh Debian 12 minimal install.

```bash
# 1. Dry-run greenfield build (verify plan only)
bash MSTeams-DR-Wizard.sh --greenfield --version=22 --dry-run \
    --fqdn=<your-sbc-fqdn> --no-ssl
# Expected: download URL shown (downloads.asterisk.org/…asterisk-22-current.tar.gz)
#           configure/make/install steps printed; nothing downloaded

# 2. Full greenfield build (takes 10–20 min)
bash MSTeams-DR-Wizard.sh --greenfield --version=22 \
    --fqdn=<your-sbc-fqdn> --email=<admin@example.com>
# Expected: Asterisk 22.x built, installed, systemd unit created, cert issued,
#           transport config written, Asterisk started

# 3. Post-install audit
bash MSTeams-DR-Wizard.sh --check --fqdn=<your-sbc-fqdn>
# Expected: all checks pass, exit 0

# 4. Sanity check
asterisk -V         # Should show 22.11.0+ or later
asterisk -rx 'pjsip show transports'   # Should show transport-ms-teams-tls
```

---

## Phase 12 — Documentation

- [x] **P12-01** Update `README.md` to add a section for `MSTeams-DR-Wizard.sh` above the legacy script section.
- [x] **P12-02** Include quick-start for brownfield FreePBX: three command sequence (download, chmod, run).
- [x] **P12-03** Include quick-start for greenfield vanilla Asterisk.
- [x] **P12-04** Document all flags in `README.md`.
- [x] **P12-05** Add `--check` output example to README so users know what a healthy system looks like.
- [x] **P12-06** Update `Unit-Testing.md` with BATS test plan for the new wizard.

---

## Iteration Checkpoints

Each phase should be committed and manually verified before the next begins.

| Phase | Deliverable | Acceptance Criteria |
|---|---|---|
| 0 | Script skeleton | `--help` works; syntax clean; ShellCheck clean |
| 1 | Version detection | Correct branch/result for all 5 version cases |
| 2 | SSL management | certbot dry-run shows RSA flags |
| 3 | DNS/FQDN validation | `--check` reports DNS status |
| 4 | Transport wizard | `--generate-config` outputs valid stanza |
| 5 | Endpoint templates | `--generate-config` outputs identify block |
| 6 | Firewall check | `--check` reports port 5061 status |
| 7 | Greenfield install | `--greenfield --dry-run` shows full plan |
| 8 | Brownfield config | Wizard injects config on live FreePBX |
| 9 | Dry-run | No file changes after `--dry-run` on live system |
| 10 | `--check` audit | Exit code reflects actual system state |
| 11 | Tests | ShellCheck + BATS pass |
| 12 | Docs | README updated; Unit-Testing.md updated |


---
