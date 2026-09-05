# AI Camera

AI Camera publishes native macOS **AI Camera** and **AI Camera Microphone** devices. After one-time device setup, selecting either virtual device in another app automatically starts only the matching physical camera or microphone. Closing the client releases that hardware again; there is no daily Start/Stop control.

A fresh profile uses the system-default hardware inputs and pure passthrough: no AI stages, transcription, overlays, or mirroring are enabled. Optional local or remote stages can add recognition, annotations, conversation, and generated speech. The SwiftUI menu-bar host owns capture and processing, the video output uses a CoreMediaIO camera system extension, and the audio output uses a Core Audio HAL loopback plug-in derived from Apple’s NullAudio sample.

## Features

- Independent, client-demanded camera and microphone activation with loop-safe system-default hardware selection. Only recognized direct-hardware inputs are eligible; virtual, aggregate, network, unknown-transport, and Continuity inputs are excluded. If the default is ineligible, the host warns and uses the first eligible physical input.
- Pure passthrough defaults; configurable physical inputs, resolution, frame rate, mirroring, overlays, gains, and AI stages remain optional.
- Idle-only local camera and microphone tests show the processed preview and a bounded live input meter. Real client demand cancels testing immediately; inline settings buttons open the matching in-app device controls.
- Optional launch at login so the menu-bar host is available before a virtual-device client opens.
- OpenAI Realtime through an API key or [separate Codex login](docs/codex-login.md), with one-utterance Talk, bounded host audio, and normal playback through speakers/headphones. Account access and subscription coverage of Realtime usage are not guaranteed.
- Independent transcription with OpenAI or embedded multilingual Whisper Base/Small, plus local HY-MT2 translation. Local weights have explicit downloads, progress, cancellation, integrity checks, and removal.
- In-process object detection with YOLOv3 Tiny or RF-DETR Medium/Large, plus Apple Vision hand gestures. Model loading and inference stay off the UI and capture callbacks.
- Detection boxes, gestures, transcripts, agent text, and status annotations, plus bounded transparent three.js overlays created through Realtime tools.
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

No model configuration is needed for passthrough. **Settings → AI** offers public OpenAI Realtime,
OpenAI or Local Whisper transcription, local translation, vision, gestures, and overlays. Setup for
Conversation, Transcription, and local vision is available while those features are off. **Privacy**
shows enabled data routes. Settings import/export and custom endpoints are hidden for now.

Settings are saved at `~/Library/Application Support/AI Camera/profile.json`. Loading older settings
preserves endpoint metadata but disables unsupported conversation and remote video routes.

## Documentation

- [Architecture and media flow](docs/architecture.md)
- [Profile and adapter configuration](docs/configuration.md)
- [Embedded model downloads and provenance](docs/local-models.md)
- [Separate Codex login and authentication boundaries](docs/codex-login.md)
- [Signing, installation, and removal](docs/installation.md)
- [Testing and diagnostics](docs/testing.md)
- [Latest validation record and signing boundary](VALIDATION.md)
- [Security and privacy](SECURITY.md)
- [Implementation plan and acceptance state](PLAN.md)

## Current validation boundary

Core tests, native synthetic/public-fixture checks, and the unsigned app, framework, camera-extension,
and audio-driver build are automated. The signed host has passed local camera/microphone testing,
normal Realtime playback, and native local-model validation; details are in [VALIDATION.md](VALIDATION.md).
System-extension activation and HAL installation are separate manual operations. Acceptance of the
current host's output in another call app remains deferred; no automated test installs components.

## License

Project code is available under the MIT License. The derived audio-driver files retain Apple’s separate permissive notice. See [`LICENSE`](LICENSE), [`NOTICE`](NOTICE), and [`docs/legal/APPLE_NULLAUDIO_LICENSE.txt`](docs/legal/APPLE_NULLAUDIO_LICENSE.txt).
