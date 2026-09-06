# AI Camera

**Your camera, with a little AI.**

Live captions, translation, gestures, and a voice agent in the camera feed you share with other
people. AI Camera is a native macOS menu-bar app that provides **AI Camera** and
**AI Camera Microphone** as virtual devices for your call or recording app.

[Download 0.2.0 early alpha](https://github.com/kortexa-ai/aicamera/releases/tag/v0.2.0) ·
[Website](https://kortexa-ai.github.io/aicamera/) ·
[Install or remove](docs/installation.md) ·
[Report an issue](https://github.com/kortexa-ai/aicamera/issues)

> **Early alpha:** expect rough edges. Start with a nonessential call. Keep these
> [recovery and manual cleanup instructions](docs/installation.md#manual-cleanup) handy.

## What it does

- **Captions and translation:** Whisper transcription and local translation appear directly in
  your outgoing video. Translation currently replaces the original-language caption.
- **A voice agent on your call:** activate OpenAI Realtime with the Agent button, a held victory
  gesture, or Control–Option–A. Replies play locally and through AI Camera Microphone when selected.
- **Quick controls:** mute, captions, translation, agent, and gestures in the menu-bar toolbar.
  Control–Option–M toggles AI Camera mute; holding a fist also mutes audio and speech captions.
- **Optional vision and overlays:** local object detection, gesture labels, and animated graphics
  created through the agent's overlay tools.
- **A quiet native app:** a separate Preview window for local camera/microphone tests, Settings,
  and optional launch at login. Physical capture follows client demand and explicit local tests.

## Get started

1. Download and open the signed `AICamera-0.2.0.pkg`, then follow macOS Installer.
2. Open **AI Camera** from Applications and click its icon in the menu bar.
3. Install the virtual camera and, optionally, virtual microphone from the app. Follow the
   macOS permission and Media Extension prompts. A system-component change can require a restart.
4. Select **AI Camera** and **AI Camera Microphone** in your call app.
5. Enable the features you want in **Settings → AI**. Local models download only when requested.

A new installation is plain passthrough with AI features off. No account or model is needed for
passthrough. Use **Preview** in the footer to test locally while the virtual devices are idle.
The installer upgrades the host in place and preserves settings, models, login, and installed devices.

## Requirements and limits

- macOS **14 or newer**. The app includes Apple Silicon and Intel binaries; alpha runtime
  acceptance has been performed on Apple Silicon, and Intel remains untested.
- A directly connected camera/microphone. Continuity cameras, aggregate devices, and other virtual
  inputs are currently excluded to prevent feedback loops.
- Local AI performance depends on your Mac. Whisper offers Base, Small, and Large; Large is shown
  only on supported M4 Pro/Max/Ultra and M5 hardware. Optional models require separate disk space.
- OpenAI features need an API key or a separate Codex login. Codex login also requires the Codex CLI.
  **Use Codex login at your own risk:** Realtime works in our testing, but OpenAI approval of this
  use is unconfirmed, and we do not know how OpenAI may respond or whether usage is covered.
- Muting inside another call app does **not** reliably hide AI Camera captions. Use AI Camera's
  own **Mute** control as well. Its audio mute protects the call when AI Camera Microphone is selected.
- Translation may occasionally return no text. There is one caption language at a time. Gestures
  depend on lighting and hand position; the toolbar provides a direct alternative.
- Camera compatibility and system-extension approval vary between apps/macOS versions. QuickTime
  has been exercised; broad conferencing-app and clean-machine coverage remains alpha follow-up work.

## Privacy

Camera/microphone buffers stay in memory; AI Camera does not record raw media. Local Whisper,
translation, detection, and gestures process on your Mac. Model downloads fetch weights, not your
media. Enabling OpenAI transcription or conversation sends microphone audio to OpenAI; Realtime
conversation does not send camera frames in the supported configuration. See **Settings → Privacy**
and [the privacy documentation](SECURITY.md) for active data routes.

## Build from source

Building requires Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and macOS 14+.

```sh
scripts/bootstrap.sh
scripts/validate.sh
```

Validation runs unit tests and an unsigned app/framework/extension/audio-driver build. It never
installs or activates system software. Signed device development requires your own Apple team and
profiles in the ignored `Config/Local.xcconfig`; see [contributing](CONTRIBUTING.md) and
[signing and installation](docs/installation.md#building-and-signing).

## Documentation

- [Settings and quick controls](docs/configuration.md)
- [Installation, repair, and manual cleanup](docs/installation.md)
- [Local models and download provenance](docs/local-models.md)
- [Codex authentication boundaries](docs/codex-login.md)
- [Architecture](docs/architecture.md) and [security/privacy](SECURITY.md)
- [Tests and diagnostics](docs/testing.md) and [validation evidence](VALIDATION.md)
- [Release process](docs/release.md) and [0.2.0 release notes](docs/releases/0.2.0.md)

## License

Original AI Camera code is [MIT licensed](LICENSE), copyright Kortexa.
Bundled code and optional model downloads retain their respective licenses; see
[NOTICE](NOTICE) and [third-party notices](Resources/ThirdParty/THIRD_PARTY_NOTICES.md).
