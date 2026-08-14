# AICamera implementation plan

AICamera is a configurable macOS audio/video proxy. The host captures a physical camera and microphone, runs bounded local and remote AI stages, renders overlays, mixes TTS, and publishes virtual camera and microphone devices.

## Phase 1 — Foundation

- [x] Create the private `kortexa-ai/aicamera` Sparta repository.
- [x] Add a generated Xcode project, Swift core package, scripts, and CI-safe validation.
- [x] Define a versioned configuration model with no fixed endpoint or hardware assumptions.
- [x] Add model adapter protocols and OpenAI-compatible/custom HTTP implementations.

## Phase 2 — Video path

- [x] Capture a configurable AVFoundation camera.
- [x] Add bounded frame sampling for VLM, object detection, and hand gestures.
- [x] Render agent annotations and overlays without blocking capture.
- [x] Add a CoreMediaIO camera system extension with source and feeder sink streams.
- [x] Feed processed frames to the extension and verify placeholder, live, stop/restart, and simultaneous-client output with bounded AVFoundation canaries.

## Phase 3 — Audio path

- [x] Capture a configurable microphone and build bounded ASR chunks.
- [x] Route transcripts and gesture events to the configured agent.
- [x] Fetch configurable TTS and mix it with microphone audio.
- [x] Add a loopback CoreAudio HAL plug-in that exposes the mix as a virtual microphone.
- [x] Verify the in-process property contract, clock, multi-client loopback, configuration changes, concurrent wrap, reset, sanitizers, and bounded atomic ring behavior.
- [x] Verify installed-device microphone and streamed-TTS loopback in an independent in-memory client with a development-signed build.

## Phase 4 — Control center and lifecycle

- [x] Add a SwiftUI menu-bar control center with preview, start/stop, source selection, status, and configuration.
- [x] Install/register and uninstall/unregister the camera extension from the app.
- [x] Install and uninstall the bundled audio driver with a standard macOS authorization prompt.
- [x] Add permission guidance and diagnostics without assuming a developer team or local service layout.

## Phase 5 — Hardening and documentation

- [x] Add unit tests for configuration, backpressure, adapters, event routing, and overlay state.
- [x] Add safe bundle, app-launch, redirect-policy, and configured model-adapter smoke checks; keep device loading opt-in.
- [x] Document development signing, install/uninstall, privacy, model composition, and troubleshooting.
- [x] Complete the safe production-readiness audit and publish the reviewed implementation to private `main`.
- [x] Complete development-signed device acceptance; keep Developer ID, notarization, and clean-machine checks as the distribution boundary.

## Current signed acceptance pass

- [x] Install the development-signed app, activate the virtual camera, and load the HAL microphone.
- [x] Verify non-silent microphone loopback in independent audio clients and silence after proxy stop.
- [x] Normalize ready-state wording, fix Settings navigation, and show identical install status on the main and Privacy pages.
- [x] Correct nominal 29.97/30 fps matching and the host's reversed CoreMediaIO sink-stream selection.
- [x] Reboot, activate the corrected camera extension, and verify its native animated placeholder with a bounded in-memory AVFoundation canary.
- [x] Install and activate build 9 with PID-version-bound live-code authorization, then pass live, stop/placeholder, restart, and simultaneous-client frame acceptance.
- [x] Protect the signed Release installer with exact Apple-anchor, same-team, and no-debug checks before and after root-private staging, `shlock` serialization, rollback traps, and final inode/`uchg` verification.
- [x] Complete silent ASR toggle, wake-phrase, agent, bounded streamed-TTS mixing, and barge-in acceptance with a development-signed build.
- [x] Install build 9, restore the normal wake-phrase profile, and restore Yeti input and HyperX output defaults.
- [ ] Repeat the short audible Yeti/HyperX human check for the final notarized distribution candidate.
- [ ] Let the operator reboot once to remove retired camera-extension generations; active build 9 is not blocked.

## Phase 6 — EVERYTHING!!! MWAHAHAHA!!!

### Natural interaction and audio

- [x] Remove manual agent prompting in favor of configurable wake-phrase and gesture activation.
- [x] Preserve always-listening profile compatibility while making wake-phrase mode the default for new and checked-in profiles.
- [ ] Expose activation mode and wake-window controls in Settings; they are currently Profile JSON options.
- [x] Stream TTS into a bounded playback queue for low first-audio latency; cancellation and barge-in stop network and queued audio immediately.
- [ ] Show speaker-labelled user transcripts and agent responses in one bounded conversation view and overlay.
- [ ] Let the agent choose a voice only from a configured local allowlist, with a deterministic fallback.

### AI-generated camera composition

- [ ] Define bounded structured overlay instructions for text, shapes, boxes, and locally rasterized SVG.
- [ ] Reject scripts, external resources, oversized SVG, excessive element counts, and stale overlay work.
- [ ] Run an end-to-end `snappy` agent test that adds random annotations to source frames and verify the composed pixels in an independent virtual-camera client.
- [ ] Continue sending clean pre-overlay frames to inference so generated content cannot recursively contaminate vision input.

### Agent camera and microphone tools

- [ ] Define the smallest useful camera/microphone tool set, such as scene snapshot requests, stage enablement, mute, gain, and supported hardware controls.
- [ ] Require explicit capabilities and user-visible state; never let an agent silently change hardware selection, privacy grants, recording, installation, or remote egress.
- [ ] Bound tool frequency, arguments, media exposure, and result sizes, and record non-media audit events without recording raw media.

### Distribution

- [ ] Complete Developer ID signing, notarization, clean-machine installation, upgrade/rollback, and uninstall acceptance.

## Constraints

- Network inference never runs on real-time capture/audio callbacks.
- Queues stay bounded: frame and ambient work replace or drop stale items, while streamed speech applies bounded backpressure.
- Raw media is not recorded by default.
- Secrets are referenced by environment variable name or Keychain, never stored in the main configuration file.
- System installation tests are manual/opt-in because macOS can require approval and reboot.
