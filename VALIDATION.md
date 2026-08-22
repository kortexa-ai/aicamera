# Validation record

## Build 14 dependency refresh and notarized distribution candidate

Date: 2026-08-21

Machine: `snappy`, Apple Silicon, macOS 26.5.2, Xcode 26.6

- Updated LiveKit WebRTC from `144.7559.13` to `144.7559.14` and the vendored three.js overlay runtime from r149 to npm release `0.185.1` / r185. Both three.js copies are byte-identical classic-script bundles generated from the official ESM release and retain the upstream MIT license. Added `LSApplicationCategoryType=public.app-category.video` to remove the actionable archive metadata warning.
- The overlay spike now records the page's three.js revision and WebGL2 availability. Its development-only content security policy permits its existing inline harness script; the production overlay keeps its strict external-script policy. The final r185 spike rendered 55 frames in two seconds at 29.7 fps through WebGL2 and completed alpha-compositing samples successfully.
- `scripts/validate.sh` passed with 89 Swift tests and a successful unsigned four-target build. The strict C11 HAL harness and its AddressSanitizer/UndefinedBehaviorSanitizer and ThreadSanitizer variants passed. `git diff --check` passed. The audio driver remains the previously validated build 12; the app and camera extension report build 14.
- The universal Release archive and exported app, frameworks, camera system extension, and HAL driver are signed with the existing Developer ID Application identity. Strict nested verification passed, and neither the app nor extension contains `get-task-allow`.
- Apple accepted notarization submission `a790793d-5572-4bdd-b7e5-6aedaa3936eb` with no issues. The ticket was stapled and validated, strict signature verification still passed, and Gatekeeper accepted the app with source `Notarized Developer ID`. The final stapled archive is `build/AICamera-0.1.0-build14-notarized-final.zip`, SHA-256 `514407f0369f4cc88b3184e0559b408a09dd862bfd03d0c3b3b8b733d4e42a35`.
- This work did not install or launch build 14, request media access, activate or replace the camera extension, copy or reload the HAL driver, register a login item, or change System Settings. Installed build 13 remains active and unchanged.

## Builds 11–13 post-restart demand-delivery validation

Date: 2026-08-16

Machine: `snappy`, Apple Silicon, macOS 26.5.2, Xcode 26.6

- The restart removed the retired camera-extension generation. Camera extension build 10 is active, enabled, and published. Its newer embedded generation has not been activated.
- Native inspection showed why the build-10 HAL selector was invisible through Core Audio although the direct driver harness could call it: custom HAL selectors must be declared through `kAudioObjectPropertyCustomPropertyInfoList` and use a supported cross-process type.
- Build 11 declares `aicc` as a `CFPropertyList` custom property, returns a retained `CFNumber`, reads it with explicit ownership in Swift, rejects nonzero qualifiers, and extends the direct harness for the exact custom-property contract. Full validation, strict C11, ASan/UBSan, TSan, signing, and `git diff --check` passed.
- With explicit approval, the protected installer installed the strict-signed build-11 host and HAL driver and reloaded Core Audio. The app, driver, and protected generation marker report 11; `get-task-allow` is absent. Camera extension build 10 was not updated.
- A separate native Core Audio process verified the live device, the one-entry custom-property info list, selector `aicc`, `CFPropertyList` data type, no qualifier type, pointer-sized result, and a nonnegative `CFNumber` value. A bounded no-recording AudioDevice client then produced 469 callbacks while the same live property transitioned `0 → 1 → 0`; a long-lived watcher independently observed the same levels, proving the value is not stale across queries.
- Host acceptance exposed a separate app-side timing defect: `@Published` emits from `willSet`, and the synchronous snapshot subscriber reconciled against the previous demand value. The HAL returned to zero, but the long-running host remained at **Microphone in use**. The host was quit cleanly; all bounded clients exited, the live count is zero, and the physical input is released.
- Build 12 defers demand reconciliation to the next MainActor turn. An independent review confirmed that level-triggered reconciliation remains safe under rapid transitions and that analogous manager/configuration subscriptions are already deferred. Build 12 passed 68 Swift tests, full non-installing validation, the strict HAL harness, sanitizer variants, strict Release signing, and `git diff --check`.
- With explicit approval, the protected installer installed the strict-signed build-12 host. The in-app microphone update then installed HAL build 12 and reloaded Core Audio through a visible administrator authorization. The protected marker, app, and HAL driver report 12, strict signature checks pass, and `get-task-allow` is absent. Camera extension build 10 remained active and was not updated.
- Four normal microphone cycles and 50–100 ms clients each produced live callbacks, demand `0 → 1 → 0`, physical Yeti acquisition only while requested, prompt host startup, return to idle, and hardware release. Two simultaneous clients produced `0 → 1 → 2 → 1 → 0`. Forced client exit cleared demand. External demand cancelled local tests, and a client that stayed open across host quit/relaunch was served after relaunch. The Core Audio watcher and UI state agreed except when a separately configured transcription endpoint reported its own connection failure.
- A no-recording QuickTime Movie Recording preview exposed and selected **AI Camera**, but the host remained at **Waiting for a camera client**. Unified logs showed the build-10 extension running inside `cmiodalassistant` and resolving its app-group container under that service account, separate from the GUI user's container; sandbox policy denied the expected shared JSON-file access. QuickTime was closed without recording or saving, all temporary clients exited, HAL demand returned to zero, and the physical microphone was released.
- Build 13 replaces the unusable camera file transport with a bounded timestamped `NSData` snapshot on the read-only `4cc_aicd_glob_0000` CoreMediaIO device property. Source start/stop transitions and one-second active heartbeats update the DAL cache. The host resolves the device by stable UID, reads only 1–4096 raw bytes, retries one size race, decodes the bounded snapshot, and rejects missing, malformed, negative-count, future-dated, or older-than-two-second values. Four new shared-wire tests bring the Swift total to 72. Full non-installing validation, the strict HAL harness, unsigned four-target build, strict Release signing, absence of `get-task-allow`, embedded property-name inspection, and `git diff --check` pass. An independent current-macOS review confirmed the custom-key mapping, raw `NSData` ABI, UID lookup, memory ownership, locking, cache notification, and fail-closed freshness behavior with no blocking defect. CoreMediaIO reports aggregate first-client/last-client source activity, normally 0 or 1 rather than exact client cardinality; that matches the host's `> 0` contract. The app and extension report build 13; the intentionally unchanged bundled audio driver reports build 12.
- With separate explicit approval, the protected installer installed app build 13 and left HAL build 12 unchanged. Strict installed signature and entitlement checks pass, and the protected generation marker reports 13. The camera update inherited approval and reached **activated enabled** for build 13. macOS invalidated build 10 and marked it for removal at restart, but launchd rejected the build-13 job submission because the build-10 job was still in progress. Build 10 then exited, build 13 did not launch, the virtual camera disappeared from bounded AVFoundation discovery, and the native `aicd` probe failed closed with `device-missing`. After an explicit status refresh, the Camera row correctly reported **Active — device unavailable** and instructed a restart. Live property and camera acceptance require that restart; none was performed.
- After a separately approved restart, build 10 was removed and build 13 remained the only **activated enabled** generation. Its provider process runs under `cmiodalassistant`, bounded AVFoundation discovery again exposes **AI Camera** at stable UID `38A6609A-FA9E-44FE-B667-4536B8491009`, and the refreshed host reports both virtual devices **Ready**.
- A native CoreMediaIO probe resolved the live device, verified global/main selector `aicd`, confirmed `settable=false`, read 123–124 raw bytes, and decoded a fresh idle snapshot with aggregate count 0. A normal no-recording QuickTime source changed `aicd` `0 → 1 → 0`; the host changed **Ready → Camera in use → Ready**, authorized its feeder, and returned to idle after client close.
- Two separate QuickTime processes opened the source concurrently without recording. CoreMediaIO correctly kept aggregate `aicd` at 1 after the first client closed and returned it to 0 only after the final client closed. This confirms the first-client/last-client stream contract rather than exact client cardinality.
- Combined camera and virtual-microphone demand produced `aicd=1`, `aicc=1`, physical Yeti running, host state **Camera and microphone in use**, and 469 audio callbacks. After the audio client stopped, `aicc` returned to 0 and the host remained **Camera in use** until the camera client closed. Final physical input state returned to zero.
- Starting both local tests and then opening an external camera client cancelled both tests; both buttons returned to **Test camera**/**Test microphone** and only **Camera in use** remained. Force-killing the exact no-recording QuickTime test process changed `aicd` `1 → 0` and restored idle within three seconds.
- With a camera source left active, quitting the host preserved fresh `aicd=1` and extension placeholder service. Relaunching the signed host reacquired demand and restored **Camera in use** without reopening the client; closing that client returned `aicd` to 0 and the host to idle. Extension logs recorded authorized feeders with no rejection, revocation, or sink-consume error.
- Final post-acceptance state is `aicd=0`, `aicc=0`, physical Yeti running state 0, physical camera `inUse=false`, no QuickTime/audio/FFmpeg test client, and an idle build-13 host. No recording was started or saved and no media was persisted.

## Build 10 local-test and source-navigation validation

Date: 2026-08-16

Machine: `snappy`, Apple Silicon, macOS 26.5.2, Xcode 26.6

- Added idle-only **Test camera** and **Test microphone** controls. The camera uses the normal processed preview; the microphone displays a 10 Hz UI poll of a one-slot, normalized peak snapshot written only on the bounded audio processing queue.
- Local tests may run together. Any external camera or microphone demand cancels both tests and performs a serialized full coordinator teardown and scene reset before client capture starts, so test-derived inference, transcripts, speech, and overlays cannot enter a client session.
- Camera and microphone starts remain independent. Demand polling now publishes one atomic combined snapshot in common run-loop modes; desired lanes start before undesired lanes stop. Per-lane gates reject stale callbacks, and a failed camera feeder cleanup is retained separately so it cannot pin or starve microphone demand.
- Inline source settings buttons route to stable Camera and Microphone anchors under **Settings → General**, including repeat requests while Settings is already open. The physical-input eligibility note applies to both lanes.
- `scripts/validate.sh` passed with 68 Swift tests and a successful unsigned four-target Xcode build. The strict C11 HAL harness passed. AddressSanitizer/UndefinedBehaviorSanitizer and ThreadSanitizer HAL variants passed. `git diff --check` passed.
- Tests cover local-test arbitration and external-client cancellation, bounded audio-level normalization, loop-safe physical-input policy, pure-passthrough defaults, lifecycle decisions, and the existing privacy, adapter, conversation, and transport boundaries. Independent lifecycle and UX source reviews found no remaining concrete issue.

The protected installer then replaced and relaunched the signed Release host without reinstalling or activating either system component. The installed app remains build 10, its protected generation marker is 10, strict nested signature verification passes, and `get-task-allow` is absent.

Signed native host acceptance passed for the following cases without persisting media:

- Camera-only testing started the resolved hardware camera and replaced the idle camera symbol with a live processed preview. Stopping it restored the idle preview and state.
- Microphone-only testing started the resolved Yeti through `AVCaptureAudioDataOutput`. The bounded meter produced finite live values between 0 and 1 and disappeared immediately on stop.
- Both tests ran together. Stopping either lane left the other active; both orders passed without a stale preview, meter, error, or callback.
- Local-only tests did not open an unconsumed CoreMediaIO feeder or virtual microphone output. The earlier AVAudioEngine physical-input path was replaced after native probes showed that explicit input-node device assignment caused startup error `-10875`; AVCapture probes received and converted samples from both the default and an explicitly selected alternate physical microphone.
- Both inline source settings buttons opened the foreground Settings window on **General** and targeted their stable Camera or Microphone sections. Updated capture copy and the shared physical-input eligibility note were present.
- Independent lifecycle, UX, and AVCapture reviews found no remaining concrete source-level issue after queue separation, full audio format preservation, partial-graph rollback, bounded copied-buffer caps, and teardown hardening.

Two daemon-level acceptance items remain after the user-owned reboot. The extension reports build 10 as activated/enabled, but macOS is not currently publishing **AI Camera** and build 9 remains queued for removal; the permanent health row now reports **Active — device unavailable** instead of **Ready**. The on-disk HAL binary matches the current build and **AI Camera Microphone** is visible, but the live Core Audio device object does not yet expose the new `aicc` demand property. A bounded FFmpeg client read the virtual microphone successfully into a null sink, but could not trigger client-demand takeover in that stale live instance. Reboot or an explicitly approved Core Audio refresh is required before external-client cancellation, cross-lane takeover, and final physical-device release can be accepted.

## Build 10 signed installation and physical-input safety follow-up

Date: 2026-08-16

Machine: `snappy`, Apple Silicon, macOS 26.5.2, Xcode 26.6

- The protected installer replaced `/Applications/AI Camera.app` with a strict-signed Release build 10. The app is running; camera extension build 10 reports **activated enabled**; HAL microphone build 10 is loaded and visible to Core Audio. Camera extension build 9 remains reboot-gated for cleanup.
- The menu-bar panel keeps permanent virtual-device health rows, reports the resolved physical inputs, uses a foregrounded Settings window, and keeps the login-item control under **Settings → General**.
- System-default resolution now reads the CoreMediaIO camera default and Core Audio microphone default. Only recognized direct-hardware transports are eligible. Software loopbacks, aggregate/auto-aggregate, network, unknown-transport, and wired/wireless/legacy Continuity inputs fail closed.
- If an ineligible default is selected, the host chooses the first compatible physical input in stable name-and-ID order and shows an orange warning naming the default and fallback. If no compatible input exists, capture remains blocked until the user selects a compatible physical device or video frame rate.
- A read-only native resolver check selected **HD Webcam eMeet C950** and **Yeti Stereo Microphone** from the current defaults. It excluded OBS Virtual Camera, the Continuity camera/microphone, BlackHole, and AI Camera from physical-input choices while preserving supported duplex virtual devices as advanced audio destinations.
- `scripts/validate.sh` passed with 62 Swift tests and a successful unsigned four-target Xcode build. The strict C11 HAL harness passed. AddressSanitizer/UndefinedBehaviorSanitizer and ThreadSanitizer HAL variants also passed. `git diff --check` passed.
- Pure policy tests cover known physical transports, virtual/aggregate/network/unknown/Continuity rejection, default retention, deterministic fallback admission, and no-hardware failure. An independent resolver review found no remaining issues after compatibility, ordering, warning-text, and fallback-API corrections.

This follow-up did not change the system camera or microphone default to AI Camera. A live self-default warning/fallback check and the broader independent/simultaneous/multi-client demand matrix remain signed native acceptance work.

## Build 10 automatic-lifecycle validation

Date: 2026-08-16

Machine: `snappy`, Apple Silicon, macOS 26.5.2, Xcode 26.6

- `scripts/validate.sh` passed after the build-10 automatic lifecycle and documentation changes.
- Swift Package Manager ran 54 tests with 0 failures, including pure-passthrough defaults, independent camera/microphone decisions, and fail-closed invalid-profile demand.
- The unsigned app, core framework, CoreMediaIO extension, and HAL driver built successfully. App-group metadata, component build 10 versions, entitlements, embedded paths, scripts, installer rendering, and the exported driver factory passed validation.
- The strict C11 HAL compile and in-process harness passed. Demand remained zero for output-only `StartIO` and companion-host reads, became active only after real external `ReadInput` operations, handled concurrent first reads and multiple clients without duplicate identities, cleared on stop/removal, and retained the existing clock, loopback, wrap, reset, malformed-input, and sample-rate checks.
- AddressSanitizer/UndefinedBehaviorSanitizer and ThreadSanitizer harness variants passed after the demand-table changes.
- Camera demand now uses serialized current-state snapshots, a one-second active heartbeat, and two-second host expiry. The extension and host integration compiled in both unsigned targets; crash expiry and physical camera release still need signed native acceptance.
- `SMAppService.mainApp` login controls compile and expose macOS approval state. Authorization status now refreshes periodically and on app activation; invalid saved profiles block demand until repaired; transient failures expose an explicit retry path. Login/logout, permission revocation, and failure recovery still need signed native acceptance.

This validation did not request camera/microphone access, register a login item, install/reload the HAL driver, submit a system-extension request, or alter the installed build-9 app. Signed build-10 demand, permission-loss, login, update, and physical-release checks remain the current release boundary.

## Build 9 signed acceptance record

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

Development-signed device acceptance is complete. Restoring the Yeti/HyperX defaults is not a new audible human check; repeat that short check for the final distribution candidate.

Build 13 was the previously installed and accepted Developer ID build. Build 14 is now the current non-installed distribution candidate after the dependency refresh. Its exact signing, notarization, and archive evidence is recorded at the top of this file.

A distributable release still needs the planned installer package, clean-machine install/upgrade/rollback/removal checks, and the user-owned reboot that clears retired extension generations.

These operations can change system state or request authorization. They remain manual and approval-gated.
