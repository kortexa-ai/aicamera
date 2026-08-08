# Validation record

Date: 2026-08-08
Machine: Apple Silicon macOS development host

## Passed

- `scripts/validate.sh`: complete safe validation passed after the final code change.
- `swift test`: 27 tests, 0 failures.
- Unsigned clean Xcode build: app, dynamic core framework, CoreMediaIO system extension, and Core Audio HAL driver all built successfully.
- Bundle checks: camera extension is under `Contents/Library/SystemExtensions`; HAL driver is under app resources; driver localization and Apple license files are present; bundle identifiers and exported factory symbol match.
- Strict C11 warning-as-error syntax checks passed for the HAL driver and its harness.
- The non-installing HAL harness passed the exact object graph, class/base-class/owner values, scopes and elements, malformed qualifiers and property sizes, buffer canaries, clock catch-up/restart, invalid timestamps and I/O sizes, independent multi-client reads, timeline gaps, concurrent ring wrap, reset, and coalesced 44.1/48 kHz configuration changes. Three repeated runs passed.
- `scripts/validate-hal-sanitizers.sh` passed AddressSanitizer, UndefinedBehaviorSanitizer, float-cast-overflow sanitizer, and ThreadSanitizer runs. Leak detection was disabled because the macOS AddressSanitizer runtime does not support it. A separate exhaustive property-size/canary run completed with `failures=0`.
- All three administrator AppleScript programs (driver install, driver removal, and app installation) compiled with `osacompile`; none was executed.
- Unsigned menu-bar application launch and targeted quit smoke test passed without requesting media access or installing system software.
- Live configured VLM route smoke: `POST http://127.0.0.1:2052/chat/completions` with a generated 64×64 JPEG and the configured LiquidAI model returned HTTP 200 and the expected dominant-color answer. The already-running managed service was used; no service was started.
- Redirect threat reproduction was converted to an automated fail-closed delegate test. Production model HTTP rejects redirects and uses an ephemeral no-cache/no-cookie session.
- The target HAL installation path was absent and `systemextensionsctl list` showed no AI Camera extension after validation.

## Not performed

- Camera extension activation or virtual camera capture.
- Installation/loading of the bundled HAL driver or independent audio loopback recording.
- End-to-end hardware camera/microphone plus ASR/agent/TTS routing.
- Release notarization.

These checks are manual and opt-in because they change system state, need media permissions, and can interrupt audio.

## Signing blocker on this machine

The signed development build was attempted and failed before installation. Xcode reported that no developer account was configured and that the available wildcard Mac provisioning profile did not contain the System Extension capability or `com.apple.developer.system-extension.install` entitlement. No extension or driver was installed.

A maintainer must add an Apple account and explicit profiles for the host and extension bundle IDs. After that, follow [`docs/testing.md`](docs/testing.md) and record the device acceptance results before calling a distributable release complete.
