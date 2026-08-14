# Validation record

Date: 2026-08-13
Machine: `snappy`, Apple Silicon, macOS 26.5.2, Xcode 26.6

## Safe automated validation

- `scripts/validate.sh` passed after the final build-9 source changes.
- `swift test` ran 50 tests with 0 failures.
- The unsigned Debug build passed for the app, core framework, CoreMediaIO system extension, and Core Audio HAL driver.
- Validation compiled every shell script, compiled the installer AppleScript without running it, rendered its privileged shell command, and passed `/bin/sh -n` on that command.
- Bundle identifiers, embedded paths, resources, property lists, entitlements, and the exported HAL factory symbol passed the project checks.
- The strict C11 HAL build and non-installing harness passed property validation, clock and restart behavior, independent clients, timeline gaps, concurrent ring wrap, reset, and coalesced 44.1/48 kHz changes.
- AddressSanitizer, UndefinedBehaviorSanitizer, float-cast-overflow, ThreadSanitizer, and the separate property-size/canary checks passed earlier in this acceptance cycle.
- Streaming transport tests cover redirect rejection, cumulative and buffer limits, startup cancellation, active-body cancellation, sample-rate validation, and complete-WAV fallback.

Safe validation does not request media access, start inference services, install a driver, or submit a system-extension request.

## Signed build and installer checks

- Apple Development-signed Release build 9 passed strict nested signature verification for the app, framework, camera extension, and bundled audio driver.
- The app and extension both report build 9, have hardened runtime enabled, and do not contain `get-task-allow`.
- Exact Apple-anchored, same-team host and extension identity requirements passed. The installer accepts that strict identity for a signed Debug predecessor, while its new-product no-debug requirement rejects the same Debug host.
- Sandboxed native probes confirmed that `PROC_PIDUNIQIDENTIFIERINFO` and PID-version-bound `csops_audittoken` queries work across users on this host. The checked layout and selectors match the current XNU ABI.
- The finalized protected installer completed a build-9 replacement transaction. The app root and generation marker are root-owned and immutable, the marker contains `9`, and no lock or private staging residue remains.
- The installer verifies identity before and after private staging, rejects debug entitlements on the new product, strips ACL and group/world write access, uses no-follow final and rollback moves, binds the final move to the staged inode before marker commit, and rolls back catchable failures and signals.

## Development-signed camera acceptance

Build 9 is installed at `/Applications/AI Camera.app`. The camera extension reports `(0.1.0/9) [activated enabled]`.

All camera clients were bounded AVFoundation canaries. They kept media in memory and wrote no frames to disk.

- With the host stopped, the source produced 12 unique animated 1920×1080 placeholder frames with strictly increasing timestamps. Frame intervals were 0.03331–0.03387 seconds. A separate classifier identified all 24 sampled frames as placeholders.
- Starting the host authorized its feeder in the real `_cmiodalassistants` service through the PID-version-bound kernel path after Security-framework lookup was unavailable. No status `-4`, rejection, or binding revocation occurred.
- With the host live, one canary received 24 distinct 1280×720 hardware-fed frames; all 24 were non-placeholder frames and timestamps increased strictly. A second canary received 12 unique frames with 0.03310–0.03413-second intervals.
- Host stop returned the source to the animated placeholder. The post-stop canary received 12 unique 1920×1080 frames with increasing timestamps, and the classifier identified all 24 sampled frames as placeholders.
- Host restart again produced 24 distinct non-placeholder frames with increasing timestamps.
- Two simultaneous independent source clients each received 24 distinct non-placeholder frames with increasing timestamps.
- Final host stop completed without a feeder stop error. After the user re-enabled the updated extension in System Settings, the app reports **Stopped**, virtual camera **Ready**, and virtual microphone **Ready**.
- After the finalized installer transaction, a stopped-host sanity canary again received 12 unique 1920×1080 placeholder frames with increasing timestamps; the app and both device rows remained **Ready**.

Older terminated camera-extension generations remain queued for removal by macOS. Their cleanup is reboot-gated and does not block active build 9. The user will perform that reboot.

## Audio and conversation acceptance

- The installed HAL driver publishes the duplex **AI Camera Microphone** device with UID `ai.kortexa.aicamera.audio.device` at 48 kHz. Independent clients previously captured non-silent microphone loopback, concurrent reads, and silence after proxy stop.
- Silent ASR → agent → bounded streamed PCM TTS completed in a development-signed build. Complete-WAV fallback, repeated bounded admissions, virtual-microphone output, and accepted barge-in cancellation passed.
- The changed local ASR, agent, and TTS routes passed their real request paths. ASR accepted both WAV and raw PCM requests with the pinned MLX 0.31.1 runtime.
- No raw media was persisted. In-memory acceptance buffers were released after aggregate metrics were computed.

After acceptance, the normal wake-phrase profile was restored. The default input is **Yeti Stereo Microphone**, the default output is **HyperX Virtual Surround Sound**, AI Camera is stopped, and both virtual devices report **Ready**.

## Remaining release boundary

Development-signed device acceptance is complete. Restoring the Yeti/HyperX defaults is not a new audible human check; repeat that short check for the final distribution candidate. A distributable release still needs Developer ID signing, notarization, clean-machine install/upgrade/rollback/removal checks, and the user-owned reboot that clears retired extension generations.

These operations can change system state or request authorization. They remain manual and approval-gated.
