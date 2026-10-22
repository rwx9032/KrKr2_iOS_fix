# Source-Only Validation

Date: 2026-10-21. Validated the generated source tree in place; no parent files,
original IPA, games, saves, certificates, secrets, or full crash logs were read.

## Layout and contents

- 19 source/documentation files before this validation report: `README.md`, `build.sh`, `.gitignore`,
  3 files under `Sources/`, 3 under `tools/`, and 10 under `tests/`.
- The publication allowlist contains text source or documentation only, including
  this report (20 files total). No `.ipa`, `.dylib`, `.app`, Mach-O binary,
  game asset, provisioning profile, or prebuilt plugin is staged. Test-generated
  binaries remain local and ignored.
- `.gitignore` excludes build outputs, generated `.xp3` fixtures, dylibs, and IPAs.

## Commands and results

### Python tests

```sh
python3 -m unittest discover -s tests -p 'test_*.py'
```

Result: `Ran 33 tests in 0.033s` — `OK (skipped=2)`, **31 passed, 2 skipped,
0 failures, 0 errors**, exit 0. The two skips are opt-in real-IPA tests:

- `test_inject.IPATests.test_real_supplied_ipa` (needs `XP3COMPAT_ORIGINAL_IPA`
  and `XP3COMPAT_DYLIB`)
- `test_clone_ipa.CloneIPATests.test_real_ipa_integration` (needs
  `XP3COMPAT_CLONE_INPUT_IPA`)

The verbose run also emitted a Python `UserWarning` about a deliberately
duplicated ZIP member inside a negative test; the test passes as intended.

### Native tests

```sh
bash tests/run_native_tests.sh
```

Result: exit 0. Three binaries ran:

| Binary | Result |
| --- | --- |
| `native-tests` (fake UIKit) | `PASS: 51 native semantic checks` |
| `native-minimal-abi-tests` (`XP3_MINIMAL_SDK=1`) | `PASS: 51 native semantic checks` |
| `native-input-tests` | `PASS: 9 native modal input checks` |

Total: **111 checks passed**, 0 failures.

### Documented build commands

Both documented build modes were run into `/tmp` (not the repository):

```sh
XP3_OUTPUT=/tmp/.../XP3Compat.dylib XP3_BUILD_DIR=/tmp/.../build bash build.sh
XP3_BUILD_MODE=minimal XP3_OUTPUT=... XP3_BUILD_DIR=... bash build.sh
```

Both exited 0 and produced an arm64 dynamically linked shared library. `auto`
selected the installed iPhoneOS 27.1 SDK; `minimal` generated 55 explicit link
stub imports. One expected deprecation warning for `UIAlertView` and one
duplicate `-lobjc` linker warning were emitted; neither is an error.

## README / CLI agreement

- `bash build.sh` defaults to `XP3Compat.dylib` in the repository root, matching
  the dylib argument used by the documented `inject_ipa.py` call.
- `tools/inject_ipa.py` CLI is `ipa dylib output`; README uses that exact order.
- `tools/clone_ipa.py` CLI is `inputIPA outputIPA` with optional
  `--bundle-id`/`--display-name`; README uses the positional form correctly.
- README no longer treats a fixed SHA-256 as a support boundary; the injector records the
  input executable's actual hash in its report only. Same-version decrypted/signed copies may
  have different bytes and hashes while still passing the identity/version/Mach-O/ZIP checks.
- README's test command works as written (with or without `-v`).
- README states that fullscreen and window scaling are not universally fixed,
  and that iPhone Duo folding adaptation is outside the current scope. The repository must
  not be treated as having fixed them. It also denies fixed device sizes,
  forced rotation, and game-stretch patches.

## Change made

`tests/test_clone_ipa.py`: corrected the stale copied-layout docstring from
`outputs/XP3Compat/tests` to the repository-relative `tests` path and removed an
obsolete `DEVELOPER_DIR` line. No production or test logic was changed.

### 2026-10-21 hash-record-only update

- `tools/inject_ipa.py`: removed the hard-coded executable-hash constant and its reject guard;
  the existing report field `original_executable_sha256` remains for traceability.
- `tests/test_inject.py`: removed the mock hash constant; the old rejection test now
  injects two distinct valid Mach-O fixtures and verifies each report hash plus payload
  preservation. The optional real-IPA test compares against the input archive's actual
  executable hash instead of a constant.
- `README.md` / `README.zh-CN.md`: removed fixed-hash support wording and documented that
  same-version decrypted/signed copies may differ; this is not a claim of arbitrary-version support.
- Preserved existing Mach-O/arm64/unencrypted, injection-space, identity/version, ZIP safety,
  no-overwrite, and no-UUID/alternate-binding checks.

## Scope boundaries

- No git commit/push, network, authentication, or `.git/config` access.
- No real IPA, installed app, original binary, or third-party game asset used.
- Native tests use real Foundation plus a fake UIKit; they do not replace
  physical-device testing, and fullscreen/Duo behavior was not exercised.
- Publication allowlist is left to the repository owner.
