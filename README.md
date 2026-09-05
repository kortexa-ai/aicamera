# AI Camera

AI Camera publishes native macOS **AI Camera** and **AI Camera Microphone** devices. After one-time device setup, selecting either virtual device in another app automatically starts only the matching physical camera or microphone. Closing the client releases that hardware again; there is no daily Start/Stop control.

A fresh profile uses the system-default hardware inputs and pure passthrough: no AI stages, transcription, overlays, or mirroring are enabled. Optional local or remote stages can add recognition, annotations, conversation, and generated speech. The SwiftUI menu-bar host owns capture and processing, the video output uses a CoreMediaIO camera system extension, and the audio output uses a Core Audio HAL loopback plug-in derived from Apple’s NullAudio sample.

## Features

- Independent, client-demanded camera and microphone activation with loop-safe system-default hardware selection. Only recognized direct-hardware inputs are eligible; virtual, aggregate, network, unknown-transport, and Continuity inputs are excluded. If the default is ineligible, the host warns and uses the first eligible physical input.
- Pure passthrough defaults; configurable physical inputs, resolution, frame rate, mirroring, overlays, gains, and AI stages remain optional.
- Idle-only local camera and microphone tests show the processed preview and a bounded live input meter. Real client demand cancels testing immediately; inline settings buttons open the matching in-app device controls.
- Optional launch at login so the menu-bar host is available before a virtual-device client opens.
- Bounded gesture, object-detection, VLM, ASR, agent, and TTS stages with an ASR toggle and an independent transcription lane. Local detection offers lightweight YOLOv3 Tiny plus downloadable Apache-2.0 RF-DETR Medium and Large Core ML models.
- OpenAI Realtime conversation through a saved API key and the host's selected microphone.
- Independent transcription with OpenAI or embedded multilingual Whisper Base/Small, plus optional local HY-MT2 translation. Local weights have explicit downloads, progress, cancellation, integrity checks, and removal.
- Hand gesture recognition with Apple Vision. Gesture events can trigger an agent response.
- Detection boxes, gestures, transcripts, agent text, and status overlays.
- Wake-phrase or gesture activation without a manual Ask button.
- Microphone forwarding, bounded opt-in streaming PCM TTS with WAV fallback, and immediate barge-in cancellation.
- Install, activate, deactivate, and remove controls for both virtual devices.
- Local-only network policy by default. Remote use needs an HTTPS host allowlist and exact per-data grants.
- No raw media recording by default. Profiles contain secret references, not secret values.

## Requirements

- macOS 14 or newer.
- Xcode 15 or newer. Xcode 16 is recommended.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen).
- An Apple development team and provisioning profiles with the System Extension capability for camera activation.

## Build and test

```sh
scripts/bootstrap.sh
scripts/validate.sh
```

`validate.sh` runs unit tests, validates metadata and installer syntax, compiles and exercises the HAL driver, and makes an unsigned four-target Xcode build. It does **not** install or activate system software.

An unsigned development build is also available with:

```sh
scripts/build.sh
scripts/run.sh
```

For signed work, copy `Config/Local.example.xcconfig` to the ignored `Config/Local.xcconfig`, select a valid team, and add the required capabilities to its profiles. For a signed non-installing build, run:

```sh
SIGNING=1 scripts/build.sh
```

To build and install the signed Release configuration through the protected installer, run:

```sh
scripts/install-app.sh
```

The app must be in `/Applications` before macOS can activate its camera system extension. The installer verifies exact host and extension identity before and after root-private staging, serializes concurrent installs, rolls back catchable failures, and verifies the final inode and `uchg` protection. Installation can show standard macOS authorization and approval dialogs.

## First use

1. Open **AI Camera** from `/Applications`.
2. In the menu-bar panel, install the camera, microphone, or both. The components are independent. Installation can show normal macOS approval or administrator dialogs; an extension approval or reboot can be necessary.
3. Select **Allow** for only the hardware permissions that the installed devices need. A denied permission row opens the matching System Settings privacy pane.
4. Leave the physical input set to **System Default**, or select a specific device in Settings. If that default is not an eligible direct-hardware input, AI Camera warns and falls back to an eligible physical input; select an explicit device if that fallback is not the one you want.
5. While both virtual devices are idle, optionally use **Test camera** for the processed preview or **Test microphone** for the live input meter. Either test becomes **Stop testing**; opening either virtual device in another app cancels both tests and gives the client priority.
6. Use the small settings button beside either resolved input to open its controls under **Settings → General**. Optionally enable **Open AI Camera at login** there.
7. Select **AI Camera** or **AI Camera Microphone** in another app. The matching lane starts and stops automatically.

No model configuration is needed for passthrough. To add AI, enable stages or conversation in Settings or apply one of the checked examples in [`Examples/`](Examples/). The profile is stored at `~/Library/Application Support/AI Camera/profile.json`. Existing schema-1 profiles retain their compatibility behavior, including always-listening activation when `activationMode` is absent.

Profiles can be imported or exported under **Settings → AI**. Transfers contain only
environment-variable or Keychain references; they never copy secret values. The checked
[`Examples/openai.json`](Examples/openai.json) profile uses an `OPENAI_API_KEY` reference and can
be imported directly.

## Documentation

- [Architecture and media flow](docs/architecture.md)
- [Profile and adapter configuration](docs/configuration.md)
- [Embedded model downloads and provenance](docs/local-models.md)
- [Signing, installation, and removal](docs/installation.md)
- [Testing and diagnostics](docs/testing.md)
- [Latest validation record and signing boundary](VALIDATION.md)
- [Security and privacy](SECURITY.md)
- [Implementation plan and acceptance state](PLAN.md)

## Current validation boundary

The core tests and unsigned app, framework, camera-extension, and audio-driver build are automated. System-extension activation and HAL installation are deliberately manual because they modify the operating system and can require a registered signing profile, administrator authorization, user approval, and a reboot. Development-signed build 9 passed the prior bounded native placeholder/live, stop/restart, and simultaneous-client camera acceptance. Build 10 adds automatic demand, pure-passthrough defaults, independent lanes, update detection, and login-item controls; its automated non-installing validation is recorded in [`VALIDATION.md`](VALIDATION.md), while signed device-demand acceptance remains manual.

## License

Project code is available under the MIT License. The derived audio-driver files retain Apple’s separate permissive notice. See [`LICENSE`](LICENSE), [`NOTICE`](NOTICE), and [`docs/legal/APPLE_NULLAUDIO_LICENSE.txt`](docs/legal/APPLE_NULLAUDIO_LICENSE.txt).
