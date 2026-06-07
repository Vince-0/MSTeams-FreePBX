# Unit Testing & CI/CD Roadmap — MSTeams-FreePBX

## Overview

This document tracks the technical debt discovered via static analysis of the installer scripts,
the rationale for the chosen tooling, and the phased implementation plan for building a
maintainable CI/CD test suite for the `MSTeams-FreePBX` repository.

---

## Current Technical Debt (ShellCheck Audit — June 2026)

ShellCheck 0.9.0 was run against `MSTeams-FreePBX-Install.sh` and identified **28 findings**
across 3 severity levels. These were discovered with zero test infrastructure in place.

### Errors (severity: `error`)

| Code | Count | Description | Lines (at time of audit) |
|------|-------|-------------|--------------------------|
| SC2168 | 11 | `local` used outside a function body | 1922, 1967, 1987, 2015, 2020–2022, 2124, 2133, 2142 |

`local` is silently ignored at the top-level script scope in bash — the variable is **not
scoped**, it leaks as a global. Under strict bash versions `local` outside a function is an
exit-code-1 error. All 11 instances were in the dry-run summary block and the post-operation
summary block.

**Status: Fixed in Phase 1.**

### Warnings (severity: `warning`)

| Code | Count | Description | Lines |
|------|-------|-------------|-------|
| SC2221 | 2 | Case pattern `-*` always overrides the `--*` alternative | 575 |
| SC2222 | 2 | Case pattern `--*` is unreachable (shadowed by `-*`) | 575 |
| SC2034 | 5 | Variables assigned but never read (`ARCH_FROM_CLI`, `LIB_FROM_CLI`, `existing_cert`, `existing_key`) | 43, 45, 506, 521, 929, 930 |
| SC2086 | 2 | Variable used without double-quotes (globbing/word-splitting risk) | 2113, 2119 |

**SC2221/SC2222:** In the CLI argument `case` statement, the catch-all branch used `-*|--*`.
Since `-*` already matches anything starting with a dash (including `--foo`), the `--*`
alternative was unreachable dead code. Fixed by reducing to `-*` alone.

**SC2034:** `ARCH_FROM_CLI` and `LIB_FROM_CLI` were sentinel flags set during CLI parsing but
never read by any conditional branch. `existing_cert` and `existing_key` were declared inside
`install_letsencrypt()` but never assigned a value after declaration or read. All removed.

**SC2086:** `build_msteams $ASTVERSION` and `printf "%.2f seconds" $duration` — unquoted
variables risk word-splitting if the value contains whitespace. Fixed with double-quotes.

**Status: All fixed in Phase 1.**

### Informational (severity: `info`)

| Code | Count | Description |
|------|-------|-------------|
| SC2162 | 6 | `read` without `-r` — backslashes in user input silently mangled |
| SC2317 | 2 | `log()` function body flagged as potentially unreachable |

SC2162 is low risk in practice (user input to this installer will never contain raw
backslashes), but adding `-r` is correct defensive style. SC2317 is a false positive — `log()`
is a valid defined helper. Both are informational and do not block the CI pipeline at the
`warning` severity threshold.

**Status: SC2162 fixed in Phase 1. SC2317 suppressed with inline `# shellcheck disable` directive.**

---

## Why BATS (Bash Automated Testing System)

| Criterion | BATS | Alternative (pytest / custom wrappers) |
|-----------|------|----------------------------------------|
| Native bash | ✅ Tests are `.bats` files, sourcing real shell functions | ❌ Python wrappers add a translation layer |
| Mocking | ✅ Override any command via `function name() {...}` before the call | Requires extra libraries |
| CI runner | ✅ `apt install bats` — available on `ubuntu-latest` without extra steps | Varies |
| TAP output | ✅ Integrates natively with GitHub Actions test reporters | Requires adapters |
| Maintenance | ✅ Tests break when logic changes — which is the point | ✅ Same |

### Primary obstacle for BATS in this codebase

`MSTeams-FreePBX-Install.sh` runs top-level side-effect code on source: root check,
`mkdir -p /var/log/pbx/`, live `wget` calls to download patch files. BATS loads scripts via
`source`, so the entire file cannot be sourced in a test context without triggering those
effects.

**Solution (Phase 2):** Extract pure functions into `lib/installer-lib.sh`. The installer
sources this library at startup; tests source only the library. No functional change to
the installer.

---

## Phased Implementation Plan

### Phase 1 — Static Analysis ✅ Complete

**Goal:** Catch syntax errors and portability issues on every push and pull request. Zero
maintenance overhead once the workflow is in place.

**Deliverables:**
- `.github/workflows/lint.yml` — ShellCheck runs on `MSTeams-FreePBX-Install.sh` on every
  `push` and `pull_request` event. Failure threshold: `warning` (errors + warnings fail the
  build; `info` findings are advisory). Note: `build-prebuilt-pjsip-bundles.sh` lives in the
  `MSTeams-PJSIPNAT` repository and is linted by its own CI workflow.
- All ShellCheck `error` and `warning` findings fixed in `MSTeams-FreePBX-Install.sh`.
- SC2162 (`read` without `-r`) fixed as defensive best practice.
- Node.js 20 deprecation resolved — see [CI Workflow Status](#ci-workflow-status) below.

**Effort:** ~2 hours
**CI runtime:** < 5 seconds on `ubuntu-latest`

---

### Phase 2 — Pure Function Unit Tests

**Goal:** Test the deterministic, side-effect-free functions in isolation using BATS. These
functions have no external dependencies and can be tested on any machine without Asterisk,
FreePBX, or root access.

**Deliverables:**
- `lib/installer-lib.sh` — extracted pure functions. `MSTeams-FreePBX-Install.sh` sources this
  file at startup (no functional change to the installer).
- `tests/unit.bats` — unit tests for:
  - `map_to_debian_arch()`: all kernel→Debian arch mappings and pass-through cases
  - `map_to_kernel_arch()`: Debian→kernel arch reverse mappings
  - `get_multiarch_path()`: multiarch path derivation per architecture
  - `is_supported_version()`: boundary tests for 21, 22, 23, and unsupported values (e.g. 20, 24)
  - Version string parsing (`grep -oE '[0-9]+(\.[0-9]+)+'`): 3-part, 4-part security-release
    versions (e.g. `22.8.2.1`), and the empty-string edge case
  - SHA256SUMS manifest parsing (`mapfile + awk`): well-formed, empty, and malformed manifests
- `.github/workflows/lint.yml` extended with a `bats` job.

**Target coverage:** ~20 tests, running in < 3 seconds.
**Effort:** 2–3 hours

---

### Phase 3 — Regression Guards for Bugs 1–7

**Goal:** Prevent regressions in the seven safety guards introduced in commit `3b66bad`.
Each bug has a corresponding test that would have caught it before merge.

**Deliverables:**
- `tests/guards.bats` — regression tests using temp directories and command stubs:

| Bug | Test strategy | Guard being tested |
|-----|---------------|--------------------|
| #1 Source dir resolution | Stub `find` to return empty; assert exit 1 + error message | `extracted_src_dir` validation in both build functions |
| #2 wget termination | Stub `wget` to `return 1`; assert exit 1 | `wget \|\| terminate 1` guard |
| #3 Zero-deploy | Fake module dir with no `.so` files; assert exit 1 | `deployed_count -eq 0` guard in `downloadonly()` |
| #4 Summary accuracy | Deploy 2 of 3 modules; assert `deployed_modules` length = 2 | `deployed_modules` array vs `downloaded_modules` |
| #5 Empty manifest | Stub `curl` to write empty file; assert exit 1 + "manifest is empty" | `modules_to_fetch` empty guard |
| #6 No HEAD probes | Static: `grep -c 'curl -fsIL' install.sh` = 0 | Absence of fragile HEAD probes |
| #7 Build symmetry | Static: `grep -c 'exact_tarball_url' install.sh` ≥ 4 | Both build functions use exact-version tarball |

**Effort:** 4–6 hours

---

### Phase 4 — Binary Verification Tests

**Goal:** Verify the `grep -a -qF` ABI/patch detection logic without requiring a real Asterisk
binary or the `strings` utility.

**Deliverables:**
- `tests/binary.bats` — synthetic binary blob tests:
  - Temp file with embedded version string → assert `grep -a -qF "$version"` exits 0
  - Temp file without the string → assert exit ≠ 0
  - Temp file with a similar but non-matching string → assert no false positive
  - Minimal-`PATH` test confirming the command works without `strings` on `PATH`

**Effort:** 1 hour

---

---

## CI Workflow Status

### First run — June 2026

The workflow triggered successfully on push to `main` (commit `c09a0e1`). ShellCheck passed
with **0 findings** at `warning` severity, confirming all Phase 1 fixes are effective in CI.

**Warning observed on first run:**

```
Node.js 20 actions are deprecated. The following actions are running on Node.js 20 and may
not work as expected: actions/checkout@v4. Actions will be forced to run with Node.js 24 by
default starting June 16th, 2026. Node.js 20 will be removed from the runner on
September 16th, 2026.
```

**Root cause:** `actions/checkout@v4` bundles a Node.js 20 runtime. GitHub Actions announced
a mandatory migration to Node.js 24 as the default from June 16 2026.

**Fix applied (commit `c09a0e1` + follow-up):** Added `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true`
to the workflow-level `env` block in `.github/workflows/lint.yml`. This is the opt-in mechanism
recommended by the deprecation notice itself. It forces the `actions/checkout@v4` action to
execute under Node.js 24 and eliminates the warning.

```yaml
env:
  FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true
```

**Future:** Once `actions/checkout` publishes a Node.js 24-native release (expected as v5 or a
v4.x patch), the `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24` env block should be removed and the
`uses: actions/checkout@v4` pin updated to the new version. The removal is a one-line diff with
no functional impact.

---

## Running ShellCheck Locally

```bash
# Install (Debian/Ubuntu)
apt-get install -y shellcheck

# Run against the installer — matches the CI configuration exactly
shellcheck --severity=warning MSTeams-FreePBX-Install.sh

# Note: build-prebuilt-pjsip-bundles.sh is in MSTeams-PJSIPNAT — lint it there:
#   shellcheck --severity=warning /opt/asterisk/MSTeams-PJSIPNAT/build-prebuilt-pjsip-bundles.sh
```

## Running BATS Locally (Phase 2+)

```bash
# Install BATS (Debian/Ubuntu)
apt-get install -y bats

# Run all test suites
bats tests/

# Run a specific suite
bats tests/unit.bats
bats tests/guards.bats
```

