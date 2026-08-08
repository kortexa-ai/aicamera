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
- [ ] Feed processed frames to the extension and verify the virtual camera with AVFoundation.

## Phase 3 — Audio path

- [x] Capture a configurable microphone and build bounded ASR chunks.
- [x] Route transcripts and gesture events to the configured agent.
- [x] Fetch configurable TTS and mix it with microphone audio.
- [x] Add a loopback CoreAudio HAL plug-in that exposes the mix as a virtual microphone.
- [x] Verify the in-process property contract, clock, multi-client loopback, configuration changes, concurrent wrap, reset, sanitizers, and bounded atomic ring behavior.
- [ ] Verify installed-device microphone/TTS capture in an independent application after signing is configured.

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
- [ ] Complete signed device acceptance before declaring a distributable release.

## Constraints

- Network inference never runs on real-time capture/audio callbacks.
- Queues drop stale work instead of accumulating latency.
- Raw media is not recorded by default.
- Secrets are referenced by environment variable name or Keychain, never stored in the main configuration file.
- System installation tests are manual/opt-in because macOS can require approval and reboot.
