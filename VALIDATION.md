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

- `/Applications/AI Camera.app` was installed and strict signature verification passed. It predates the final playback-lifetime fixes and must be replaced before the next human check.
- The HAL driver is installed at `/Library/Audio/Plug-Ins/HAL/AICameraAudioDriver.driver`. It publishes the duplex **AI Camera Microphone** device with UID `ai.kortexa.aicamera.audio.device` at 48 kHz. Independent clients captured non-silent microphone loopback, concurrent reads, and silence after proxy stop.
- The camera extension was activated during this pass. The corrected replacement is now `terminated waiting to uninstall on reboot`; no reboot was performed.
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

- Install the latest development-signed app build and run one short audible Yeti/HyperX check.
- After explicit reboot approval, complete the pending camera-extension replacement and run the bounded native AVFoundation canary for placeholder, live frames, stop/start, increasing timestamps, and multiple clients.
- Complete Developer ID signing, notarization, clean-machine upgrade/rollback, and uninstall checks.

These checks can change system state, request authorization, interrupt audio, or require a reboot. They remain manual and approval-gated.
