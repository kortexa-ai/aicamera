# AI Camera

AI Camera is a configurable native macOS audio/video proxy. It captures one hardware camera and microphone, applies local or remote AI stages, draws live annotations, mixes generated speech with the microphone, and publishes the result as **AI Camera** and **AI Camera Microphone** devices.

The application is a SwiftUI menu-bar control center. The video output uses a CoreMediaIO camera system extension. The audio output uses a Core Audio HAL loopback plug-in derived from Apple’s NullAudio sample.

## Features

- Configurable physical camera, microphone, resolution, frame rate, gains, and virtual audio destination.
- Bounded gesture, object-detection, VLM, ASR, agent, and TTS stages with an ASR toggle and an independent transcription lane.
- OpenAI-compatible chat, vision, transcription, and speech adapters.
- Kortexa `/detect` and raw-PCM `/transcribe/pcm` adapters.
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

`validate.sh` runs unit tests, validates metadata, compiles the HAL driver, and makes an unsigned four-target Xcode build. It does **not** install or activate system software.

An unsigned development build is also available with:

```sh
scripts/build.sh
scripts/run.sh
```

For a signed build, copy `Config/Local.example.xcconfig` to the ignored `Config/Local.xcconfig`, select a valid team, add the required capabilities to its profiles, and run:

```sh
SIGNING=1 scripts/build.sh
scripts/install-app.sh
```

The app must be in `/Applications` before macOS can activate its camera system extension. Installation can show standard macOS authorization and approval dialogs.

## First use

1. Open **AI Camera** from `/Applications`.
2. In the menu-bar panel, install the audio driver and activate the camera extension.
3. Approve the extension in System Settings if macOS asks. A reboot can be necessary.
4. Give AI Camera camera and microphone permission.
5. Open Settings, select physical inputs, and choose **AI Camera Microphone** as the mixed output.
6. Configure a JSON profile or select the optional **Kortexa local** preset.
7. Select **AI Camera** and **AI Camera Microphone** in the client application, then start the proxy.

The profile is stored at `~/Library/Application Support/AI Camera/profile.json`. The full editor is in Settings. Checked examples are in [`Examples/`](Examples/). New and checked-in profiles use a configurable leading wake phrase. Schema-1 profiles that omit `activationMode` keep their prior always-listening behavior; select current modes in Profile JSON.

## Documentation

- [Architecture and media flow](docs/architecture.md)
- [Profile and adapter configuration](docs/configuration.md)
- [Signing, installation, and removal](docs/installation.md)
- [Testing and diagnostics](docs/testing.md)
- [Latest validation record and signing boundary](VALIDATION.md)
- [Security and privacy](SECURITY.md)
- [Implementation plan and acceptance state](PLAN.md)

## Current validation boundary

The core tests and unsigned app, framework, camera-extension, and audio-driver build are automated. System-extension activation and HAL installation are deliberately manual because they modify the operating system and can require a registered signing profile, administrator authorization, user approval, and a reboot.

## License

Project code is available under the MIT License. The derived audio-driver files retain Apple’s separate permissive notice. See [`LICENSE`](LICENSE), [`NOTICE`](NOTICE), and [`docs/legal/APPLE_NULLAUDIO_LICENSE.txt`](docs/legal/APPLE_NULLAUDIO_LICENSE.txt).
