# AI Camera product plan

AI Camera is a demand-driven macOS virtual camera and microphone. The host acquires each physical input only while the matching virtual device has a client, or while the user runs an explicit local test. Fresh profiles are pure passthrough. Optional bounded local and remote stages can render overlays, transcribe speech, run an agent, and mix speech output.

Detailed test evidence belongs in [`VALIDATION.md`](VALIDATION.md). Manual acceptance procedures belong in [`docs/testing.md`](docs/testing.md). This file is the canonical roadmap and backlog.

## Current status

- Current development target: build 13. Its bundled audio driver remains build 12 because this camera-only change does not alter the validated HAL binary.
- With explicit approval, the strict-signed build-13 host was installed in place. The protected install marker and app report build 13. The intentionally unchanged, already validated HAL driver remains build 12 and Core Audio was not reloaded.
- Build-12 microphone acceptance passed four normal cycles, short-lived clients, two simultaneous clients with `0 → 1 → 2 → 1 → 0` demand, forced client exit, local-test takeover, and host quit/relaunch while demand remained active. Callback flow, physical Yeti acquisition, prompt teardown, and return to idle all passed without recording media.
- A bounded QuickTime check exposed and selected **AI Camera** without recording, but the build-10 extension could not deliver camera demand to the host. The extension runs inside `cmiodalassistant`, whose service container is isolated from the GUI user's app-group container; sandbox logs confirmed that the shared JSON-file transport is not usable across those processes.
- Build 13 replaces that file transport with a bounded timestamped `NSData` snapshot on the read-only CoreMediaIO custom device property `4cc_aicd_glob_0000`. The host resolves the camera by stable UID, reads the raw property bytes through the legacy C API, and rejects missing, malformed, future-dated, or stale snapshots. Build 13 passes 72 Swift tests, full non-installing validation, the strict HAL harness, an unsigned four-target build, strict Release signing without `get-task-allow`, and `git diff --check`.
- After the explicitly approved restart, retired camera extension build 10 was removed. Build 13 is the only active enabled generation, its provider process runs under `cmiodalassistant`, and **AI Camera** is published at its stable UID. A native probe verified that `aicd` is present on the device's global/main address, is read-only, returns bounded raw `NSData` bytes, and reports a fresh idle aggregate count of zero.
- Signed live acceptance passed normal and repeated camera cycles, two simultaneous QuickTime source clients, combined camera-plus-virtual-microphone demand, local-test takeover, forced camera-client exit, and host quit/relaunch while camera demand remained active. CoreMediaIO correctly kept aggregate camera demand at 1 until the final source client closed. Final `aicd` and `aicc` counts are zero, physical camera and microphone inputs are released, all bounded clients have exited, and the build-13 host is running idle.
- Remaining acceptance covers controlled extension freshness, permission recovery, login behavior, the audible distribution-candidate check, and recording those final results. These checks do not block preserving the reviewed automatic-lifecycle implementation in Git.

## Immediate work — close automatic lifecycle

- [x] Install the strict-signed build-12 host and HAL driver with explicit approval, reload Core Audio, and leave the camera extension at build 10.
- [x] Complete the bounded build-12 microphone demand matrix and verify host start, prompt teardown, physical-device release, multi-client levels, crash cleanup, takeover, and host relaunch.
- [x] Diagnose the camera-demand blocker and replace the cross-user app-group file with a read-only custom CoreMediaIO property.
- [x] Complete full non-installing validation and strict Release signing for build 13.
- [x] With separate explicit approval, install the build-13 host and submit activation of its build-13 camera extension without replacing or reloading the validated build-12 HAL driver.
- [x] With explicit approval, restart macOS, remove build 10, publish build 13, and verify the idle read-only `aicd` property before opening a camera client.
- [x] Verify camera-only, microphone-only, simultaneous, and multi-client external demand with bounded native clients.
- [x] Verify that any external camera or microphone client cancels both local tests before client capture starts.
- [x] Verify cross-lane handoff, forced client cleanup, host-absent recovery, and final physical-device release.
- [ ] Verify camera property freshness after a controlled extension crash/restart, permission loss and recovery, and login behavior.
- [ ] Repeat the short audible Yeti/HyperX check for the final distribution candidate.
- [ ] Complete the remaining checks above and record their signed results in `VALIDATION.md`.

## Product backlog

Items inside a section are not priority ordered. Work must continue to satisfy the safety and privacy constraints at the end of this file.

### Installation, onboarding, and product identity

- [ ] Improve first-install and update guidance for enabling the media extension. Detect approval state, give an explicit step-by-step path, and offer to open the relevant System Settings/Preferences page when macOS permits it.
- [ ] Create a production app icon and use the same canonical asset in Finder, Login Items, Extensions, the popup header, and About. The app icon shown inside the popup must not drift from the bundled application icon.
- [ ] Derive a clear monochrome macOS template image for the menu-bar/system-tray item from the same visual identity. Verify the tray glyph and full-color app icon look like one product at standard and Retina sizes.
- [ ] Add a quick status indicator to the menu-bar icon for **attention needed**, **idle**, **camera in use**, **microphone in use**, and **error**. Define an unambiguous combined camera-and-microphone state.
- [ ] Add GitHub release update checks for production/release builds only. Development builds must not poll for updates, and update checks must not install anything without an explicit user action.

### Control center layout and visual design

- [ ] Move the camera and microphone test actions into their matching virtual-device rows, right aligned. Use visible labels **Test** and **Stop**, no icon, and the same restrained plain-text/hover treatment as **Quit**. Keep full accessible labels such as **Test camera** and **Stop microphone testing**, preserve external-client priority and disabled-state rules, and do not displace required **Install**, **Update**, **Open Settings**, or **Repair** actions. Show **Test** only when that lane is locally testable and keep **Stop** available for the full life of its active test.
- [ ] Show the processed camera preview only during an explicit local camera test. Make it span the popup's available content width and derive its height from the selected output dimensions so 4:3 and 16:9 formats keep their aspect ratio without stretching. Verify camera-only and simultaneous local camera-plus-microphone layouts.
- [ ] On any external camera or microphone takeover, immediately hide and clear the popup preview, release stale preview-image UI state, and reserve no empty preview space. Reopening the popup during camera-only, microphone-only, and combined external demand must expose no prior or current frame; the bounded output, feeder, and explicitly enabled inference pixel paths may continue independently.
- [ ] Place the live microphone level meter in the local-test media area below the optional camera preview and above the device-row test actions. Keep it visible during a microphone test even when the camera preview is absent, and retain the existing bounded 10 Hz UI read with no added capture-callback work. Any external takeover must immediately clear and hide the meter so the popup never exposes an external-session level.
- [ ] Add a full-width camera/AI/media-themed header banner with its own color palette, a dark readability gradient, and a compact high-contrast product title. Use a fixed banner height and clip it inside the popup rather than changing layout as status changes.
- [ ] Adopt the compact Kortexa Control Center-inspired popup silhouette: a native transient menu-bar popover with rounded corners, a menu-bar pointer, approximately 400-point base width, content-driven height, and a distinct footer. Prefer the native `NSStatusItem` plus `NSPopover` behavior (or an equivalent native implementation) over simulated window chrome.
- [ ] Add **About · Quit** at the right side of the footer, with **About** immediately to the left of **Quit**. About must close the popup and open or foreground one reusable, titled, closable About window.
- [ ] Give the About window the same visual hierarchy as the Control Center reference: centered 64-point rounded production icon, bold **AI Camera** name, one-line purpose/privacy subtitle, Kortexa website link, version/build and MIT-license information, and compact camera/microphone readiness rows. Return the app to accessory-only behavior when the window closes.

### Profiles and production packaging

- [x] Remove the **Kortexa Local** preset from Settings in production/release builds; keep development access where useful.
- [x] Add validated import and export of versioned profiles so development presets such as **Kortexa Local** can be moved between installations quickly.
- [x] Keep secrets out of ordinary profile exports. Export secret references by default and require a separate explicit secure flow for any secret transfer.
- [x] Ship an importable example OpenAI profile with OpenAI endpoint definitions and an `OPENAI_API_KEY` environment/Keychain reference. Never include a real API key in the repository or app bundle.
- [ ] Add the bounded WebRTC conversation session described in `docs/realtime-conversation.md`: canonical OpenAI Realtime, self-hosted OpenAI-compatible Realtime, and an explicitly experimental ChatGPT/Codex subscription provider; keep separate ASR, agent, and TTS stages as the selectable fallback.
- [ ] Add one-shot **Talk** activation with server VAD and **Stop**: connect with microphone egress closed, transmit only during an explicitly armed utterance, close the gate on VAD stop/timeout/cancellation, and route decoded remote PCM through the existing bounded virtual-microphone mixer.
- [ ] Add Realtime Settings for provider, endpoint, model, voice, and Keychain-backed credentials or OAuth; profiles store secret references only. Test the standard protocol against canonical OpenAI and `api.server`.
- [ ] Normalize standard Realtime function calls and experimental Codex delegation calls into one local bounded tool executor; start with `render_overlay` and `clear_overlay`.

### Development and production isolation

- [ ] Add a co-installable **AI Camera Dev** product flavor so development can continue while the production app remains installed in `/Applications`. Give it a distinct app name and bundle identifier; camera-extension identifier, Mach service, stable device/stream UUIDs, and virtual-camera name; HAL bundle/install name, factory UUID, plug-in/box/device/model identifiers, and device name; plus a distinct app group, Application Support/profile path, generation marker, defaults domain, Keychain service, and login item.
- [ ] Keep feeder authorization flavor-specific: the production extension must accept only the production host and the development extension only the development host, with the existing team, path, hardened-runtime, entitlement, and PID-version checks intact. Dev and production demand signals, profiles, permissions/status, secrets, and component maintenance actions must never cross.
- [ ] Add explicit build/run/package flavor selection and clear visual **Dev** identity. Ordinary development builds and tests must not install or activate either flavor automatically. Validate side-by-side install, upgrade, client selection, crash, repair, and removal; prove that every development maintenance action leaves the production app, marker, driver, extension, login item, profile, Keychain items, and live virtual devices unchanged.

### Natural interaction and conversation UX

- [x] Expose activation mode and wake-window controls in Settings; they are currently Profile JSON options.
- [ ] Show speaker-labelled user transcripts and agent responses in one bounded conversation view and optional overlay.
- [ ] Let the agent choose a voice only from a configured local allowlist, with a deterministic fallback.

### AI-generated camera composition

- [ ] Define bounded structured overlay instructions for text, shapes, boxes, and locally rasterized SVG.
- [ ] Reject external resources, oversized SVG, excessive element counts, and stale overlay work. Model-rendered scripts are covered by the section below.
- [ ] Continue sending clean pre-overlay frames to inference so generated content cannot recursively contaminate vision input.
- [ ] Run an end-to-end `snappy` test that adds random annotations and verifies composed pixels in an independent virtual-camera client.

### Model-rendered overlay scripts (transparent render layer)

Design: `docs/overlay-script-renderer.md`. The model gets a bounded `render_overlay` tool; the script (three.js, WebGL2) runs in a hidden in-app WKWebView and its transparent frames are composited onto the published camera frames.

- [ ] Keep the cheaper structured/SVG overlay path for simple labels; use script rendering for rich 2D/3D/animated content.
- [x] Phase 0 spike: the `AICameraOverlaySpike` dev tool proves hidden WKWebView + three.js + `readPixels` to `CVPixelBuffer` + alpha composite at 30 fps. Results and WebKit/SDK quirks are recorded in `docs/overlay-script-renderer.md`.
- [x] Add `OverlayScriptRenderer` (on-screen at near-zero window alpha so WebKit keeps rendering invisibly, bounded `window.AICamera` bridge, non-persistent storage) and a lock-based single-slot overlay-frame mailbox (`LatestValueSlot`); composite only fresh frames in `OverlayRenderer`; keep the inference path clean. Manual camera-test acceptance confirmed the live camera, rotating cube, and ring composite correctly.
- [ ] Add the Realtime-first bounded tool executor described in `docs/realtime-conversation.md`; expose `render_overlay(script, ttlSeconds?)` and `clear_overlay()` with the live canvas dimensions, transparency rules, bridge API, and scene-coordinate contract; retain chat-completions tool support for the legacy fallback; tear down on lane stop, cancellation, and expiry.
- [x] Add `overlays.script` profile settings (`enabled`, `maxScriptBytes`, `maximumFps`, `defaultTTLSeconds`, `maximumTTLSeconds`, `allowSceneData`); scripts are memory-only and never persisted.
- [x] Add a dev-only overlay script box to the control center (visible during a local camera test when script overlays are enabled) for acceptance without a model round-trip.
- [ ] Add a web-content crash watchdog (no fresh frame means the overlay disappears), memory caps, and an end-to-end acceptance test where an independent virtual-camera client sees the composed script pixels.
- [ ] Keep a hosted Chromium renderer (Electron/ElectronBun) as a swap-in option behind the same protocol if WebGPU/typegpu is required later.

### Agent camera and microphone tools

- [ ] Define the smallest useful tool set, such as scene snapshot requests, stage enablement, mute, gain, and supported hardware controls.
- [ ] Require explicit capabilities and user-visible state. An agent must not silently change hardware selection, privacy grants, recording, installation, or remote egress.
- [ ] Bound tool frequency, arguments, media exposure, and result sizes. Record only non-media audit events unless recording is explicitly enabled.

### Public repository readiness

- [ ] Rewrite the README for a public audience: concise product purpose, supported macOS versions, privacy and host-absent behavior, virtual-device installation and approval overview, pure-passthrough quick start, screenshots after the visual redesign, architecture links, local build/test commands, release downloads, known limitations, and support paths.
- [ ] Review the existing root MIT `LICENSE` for the intended copyright holder and year, then expose the same license information in About, the README, installer metadata, and release artifacts.
- [x] Add `CONTRIBUTING.md` with the repository layout, supported toolchain, setup/build/test commands, code style, real-time and media-privacy rules, system-component safety boundary, test and documentation expectations, issue/PR guidance, and a strict ban on committed credentials, signing material, or captured media.
- [ ] Before changing repository visibility, audit tracked files and Git history for secrets, signing identifiers/material, machine-specific paths, generated products, private media, and third-party license obligations. Keep local signing/configuration files ignored and document any required history cleanup before publishing.

### Distribution

- [ ] Produce a Developer ID-signed, hardened, notarized, and stapled production build. Add a step-by-step release guide that separates the operator's Apple Developer tasks from automated checks: enrollment/access, identifiers and capabilities, certificates and provisioning profiles, local notary credentials, archive/sign verification, notarization submission, stapling, and Gatekeeper assessment. Guide the operator interactively through each Apple portal or Keychain step without committing or printing credentials, team identifiers, or signing identities.
- [ ] Create a Developer ID Installer-signed, notarized, and stapled installer package for GitHub Releases while keeping the app and every nested component Developer ID Application-signed. It should install or upgrade only **AI Camera.app** in `/Applications`; package scripts must never activate the camera extension, copy or reload the HAL driver, change defaults, or hide an approval/reboot. Preserve the existing protected-transaction guarantees (strict nested identity checks, root-private same-volume staging, rollback, generation marker, and immutable destination) or provide and validate an equally strong installer transaction. Publish checksums, versioned release notes, and matching uninstall/repair instructions.
- [ ] Add a repeatable release-packaging command that fails closed on wrong versions, bundle/component identity mismatches, missing hardened runtime, debug entitlements, unsigned nested code, wrong Application-versus-Installer certificate class, failed notarization/stapling of the final distributed container, or a dirty/unreviewed release input. Keep Apple credentials in local Keychain/environment references only.
- [ ] Complete clean-machine installer, first-run approval, virtual-device publication, upgrade-in-place, rollback, repair, uninstall, reboot-boundary, and Gatekeeper acceptance. Confirm package execution itself performs no camera-extension activation and no HAL copy or Core Audio reload.
- [ ] Verify GitHub update-check behavior in production and confirm that development builds make no update requests.

## Completed milestones

### Foundation and media paths

- [x] Create the private repository, generated Xcode project, Swift core package, scripts, and CI-safe validation.
- [x] Include a tracked root MIT license.
- [x] Define versioned configuration and model-adapter protocols without fixed hardware, endpoint, team, or credential assumptions.
- [x] Implement bounded AVFoundation camera capture, inference sampling, Vision gestures, overlays, and the CoreMediaIO source/feeder extension.
- [x] Implement bounded physical microphone capture, ASR windows, agent routing, streamed speech mixing, and the duplex Core Audio HAL loopback device.

### Control center, hardening, and automatic lifecycle

- [x] Add the menu-bar control center, persistent virtual-device health/source rows, Settings, permission guidance, installation, repair, update, and removal flows.
- [x] Make new profiles pure passthrough and keep AI, conversation, transcription, mirroring, and overlays opt-in.
- [x] Resolve system defaults through loop-safe direct-hardware filtering and deterministic fallback warnings.
- [x] Publish bounded camera and microphone client demand and reconcile both hardware lanes independently.
- [x] Add idle-only camera and microphone tests with client priority, processed preview, bounded level meter, clean takeover boundaries, and per-lane stale-callback gates.
- [x] Add optional launch at login with `SMAppService.mainApp`.
- [x] Add fail-closed profile handling, strict feeder authorization, bounded real-time paths, protected signed installation, and build/update detection.
- [x] Replace explicit AVAudioEngine input-device assignment with exact-UID `AVCaptureAudioDataOutput` capture and a two-slot, size-capped processing handoff.

### Acceptance completed so far

- [x] Pass strict unit, build, script, installer-rendering, HAL harness, ASan/UBSan, and TSan validation.
- [x] Pass development-signed build-9 placeholder, live camera, stop/restart, simultaneous-client, microphone loopback, ASR/agent/TTS, and barge-in acceptance.
- [x] Install the strict-signed build-10 host and pass local camera/microphone test, simultaneous-test, stop-one-lane, live preview/meter, and inline Settings navigation checks.

## Non-negotiable constraints

- Camera and microphone lanes remain independent and start only for matching external demand or an explicit local test.
- Network inference never runs on capture, CoreMediaIO, HAL, or other real-time callbacks.
- All media and network queues remain bounded; stale work is replaced, dropped, expired, or cancelled.
- Raw camera and microphone media is memory-only unless the user explicitly enables recording.
- Remote egress remains fail-closed and requires configured privacy grants, approved destinations, and explicit AI stages.
- Secrets use environment-variable or Keychain references and are never committed to profiles, examples, logs, or documentation.
- Automatic reconciliation never requests permissions, installs components, changes system defaults, or hides required approval/reboot steps.
- Feeder signing, team, path, runtime, and PID-version authorization must not be weakened.
- System installation, extension activation, driver reload, and reboot checks remain manual and approval-gated.
