# Validation record

Date: 2026-08-09
Machine: `snappy`, Apple Silicon, macOS

## Safe automated validation

- `scripts/validate.sh`: passed after the final source changes.
- `swift test`: 50 tests, 0 failures.
- The unsigned Xcode Debug build passed for the app, dynamic core framework, CoreMediaIO system extension, and Core Audio HAL driver.
- The Apple Development-signed Debug build passed. The app, framework, extension, and driver passed strict nested signature verification.
- Bundle identifiers, embedded paths, resources, exported HAL factory symbol, property lists, and entitlements passed the project checks.
- The strict C11 HAL build and non-installing loopback harness passed property validation, clock and restart behavior, independent clients, timeline gaps, concurrent ring wrap, reset, and coalesced 44.1/48 kHz changes.
- AddressSanitizer, UndefinedBehaviorSanitizer, float-cast-overflow, ThreadSanitizer, and the separate property-size/canary run passed earlier in this acceptance cycle.
- The driver install, driver removal, and app install AppleScript programs compiled without execution.
- Streaming transport tests cover redirect rejection, cumulative and buffer limits, startup cancellation, active-body cancellation, sample-rate validation, and complete-WAV fallback.

Safe validation does not request media access, start inference services, install a driver, or submit a system-extension request.

## Development-signed device acceptance

- The published build at commit `cfc08f2` was installed at `/Applications/AI Camera.app` after the approved reboot, and strict nested signature verification passed. It is build 1 and predates the build-2 sink-authorization correction described below.
- The HAL driver is installed at `/Library/Audio/Plug-Ins/HAL/AICameraAudioDriver.driver`. It publishes the duplex **AI Camera Microphone** device with UID `ai.kortexa.aicamera.audio.device` at 48 kHz. Independent clients captured non-silent microphone loopback, concurrent reads, and silence after proxy stop.
- The camera extension is now `activated enabled`. A native AVFoundation canary discovered **AI Camera** by its stable UUID, captured 12 animated 1920×1080 placeholder frames, observed 12 distinct in-memory hashes and strictly increasing presentation timestamps, and wrote no media to disk. Repeated source start/stop capture also passed.
- The first host-feeder attempt exposed one fail-closed compatibility defect: CoreMediaIO reported the valid unsandboxed host signing ID as `unknown`, so build 1 correctly rejected the sink but could not publish live frames. Build 2 now validates the live client PID against a cached Security requirement containing the Apple anchor, exact host identifier, and the extension's own signing-team OU. A sandboxed Apple Development-signed probe accepted the installed host and rejected an unrelated signed app and a missing PID. Build 2 has not yet replaced the active extension.
- The local ASR, Qwen agent, and TTS routes each passed their changed request path. The ASR service used the pinned MLX 0.31.1 runtime and accepted both WAV and raw PCM requests.

## Silent end-to-end speech acceptance

The final speech checks did not use speakers or human input. A bounded synthesized command was sent directly to BlackHole 2ch, microphone passthrough gain was temporarily zero, and an independent client captured **AI Camera Microphone** only in memory.

- ASR → agent → opt-in streaming PCM TTS completed in a development-signed build.
- A complete short response produced a non-silent virtual-microphone capture with -2.51 dBFS peak and a 0.22-second active interval.
- A longer streamed response crossed repeated bounded player admissions without an overflow reset.
- A second test injected a short non-speech barge signal after the first output samples. Speech stopped after a 0.20-second active interval, and the capture was exactly silent 500 ms after speech began. Only one agent/TTS turn ran; the barge signal did not create another turn.
- Playback acknowledgements now keep the producing turn active through the final audio buffer. Turn replacement, barge-in, and stop send an explicit playback reset, which also cancels an active streamed body.
- No raw media was written to disk. All in-memory media buffers were cleared after metrics were computed.

After acceptance, AI Camera and the ASR/TTS/agent services were stopped. The default input was restored to **Yeti Stereo Microphone**, the default output to **HyperX Virtual Surround Sound**, and the profile to wake-phrase mode with normal microphone gain.

## Remaining manual acceptance

- Install build 2, select the explicit camera-extension **Update** action, and complete bounded native AVFoundation acceptance for live frames, host stop/start, and multiple clients. Placeholder and timestamp acceptance already pass.
- Run one short audible Yeti/HyperX check with the latest development-signed app build.
- Complete Developer ID signing, notarization, clean-machine upgrade/rollback, and uninstall checks.

These checks can change system state, request authorization, interrupt audio, or require a reboot. They remain manual and approval-gated.
