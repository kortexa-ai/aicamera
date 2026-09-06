# Companion acceptance and return to 0.2.0

Use this sequence when preparing a signed host build with the new listening and companion tools.
It keeps the working camera extension and audio driver in place and separates synthetic evidence
from actual spoken and call-client acceptance.

## Prepare a reversible host update

1. Run `scripts/validate.sh`, then `scripts/validate-release-settings.sh`. Record the source commit
   and results in the owning issue. The second fixture compiles the pinned public 0.2.0 core and
   uses disposable synthetic settings; it neither fetches code nor reads installed/user settings.
2. Retain the verified [0.2.0 installer](https://github.com/kortexa-ai/aicamera/releases/tag/v0.2.0)
   and its checksum. Before installation, keep a private copy of the existing
   `~/Library/Application Support/AI Camera/profile.json` if present. Treat it as settings data:
   it can contain device identifiers and credential references. Keep this backup out of issues and
   the repository. A new notebook is separate and must not be removed to roll back the app.
3. Give the candidate an independent host build number and verify its signed source. Host-only
   changes retain the camera-extension and HAL versions. Use `scripts/install-app.sh` and its exact
   protected transaction; verify the installed signature, host version, and generation marker.
   Ordinary host installation does not require component activation or an uninstaller.
4. Confirm the installed About version before testing. Use the same consistently signed installed
   app for account-backed voice checks. Standalone helpers can have different Keychain access and
   are not a substitute for that acceptance.

This is a preparation procedure, not a command to install a build during an unattended test.
See [installation](installation.md) for the normal signed installer and system-component boundary.

## Test the call first

Select **AI Camera** as the camera in an independent client such as QuickTime. Select **AI Camera
Microphone** when checking audio sent through the virtual microphone. Camera selection alone does
not select its audio source. Use headphones for the spoken checks where possible.

Keep the first checks focused on the established behavior:

- The normal camera and configured translated captions remain readable; Preview and the independent
  client show the same outgoing composition.
- Start the agent with the existing control or gesture and ask a short question. The existing
  Conversation listening mode still resumes after an answer.
- During an answer or tool operation, use **Pause listening** or **Control–Option–L**. Continue
  talking to the other person. The current answer/work must finish, call audio must remain live,
  and the agent must not start responding to the side conversation. Pausing an unfinished input
  discards that input, so perform this check after the question has been accepted.
- Select **One question at a time** in Settings → AI → Conversation → Listening. Ask a question,
  then keep talking. The agent stays paused after the answer. **Ask again** deliberately admits a
  fresh question; older audio must not be replayed.
- Test full AI Camera privacy mute separately. It stops AI Camera audio/captions and the agent;
  unmute begins with fresh state. A receiving app's own mute button is not synchronized with this
  control; the cross-application requirement remains tracked in issue 51.

If these fail, resolve them before evaluating new visuals or adding spoken translation.

## Try small explicit tool requests

Enable Tools for these requests. Use synthetic note content and a public place for weather.

| Request | Expected observation |
| --- | --- |
| “Remember: synthetic check—send the outline Friday.” | A local note appears in Notes; saving alone does not display it in the camera |
| “Show that note.” | A readable card appears; Reset view clears the card without deleting the note |
| “Forget that note.” | Only the requested note is removed; the agent reports success after the tool succeeds |
| “Show the annual difference between 19.99 and 17.50 per month.” | Calculation gives 29.88, with the provided units/assumptions retained |
| “Give us a quiet ten-second timer.” | Native countdown, a five-second finished state, then clear; no spoken completion |
| “Translate the captions into Spanish.” | The configured local translation changes language live; old-language completions do not return |
| “Put a little sun above my head.” | Requested local face effect follows one clear face and hides on lost/ambiguous tracking |
| “Show three colorful bars full screen, with me in the bottom-right fifth.” | Generated scene behind an aspect-preserving live camera inset; Reset view restores the normal camera |
| “Go to sleep.” | Agent input/output stops while independently enabled call features keep working |

For weather, explicitly enable **Weather forecasts** under Tools first. Ask for a U.S. public place
and units, for example a Seattle forecast in Fahrenheit. The answer/card should identify NWS,
place, forecast period, units, and issuance time. An unavailable lookup must produce a clear failure,
not invented weather. A decorative sun alone is not evidence of a forecast.

Check Clear/Reset, privacy mute, tool disable, and camera shutdown while a card, timer, or face effect
is visible. For face effects, test movement and lighting as well as loss/reacquisition. Synthetic
portrait and WebKit tests establish alignment and cleanup, not real-person tracking quality.
Spoken translation, external image/slide loading, and market quotes are not available tools yet.

## Settings compatibility with 0.2.0

The optional compatibility fixture uses public release commit
`080cf1958c82956df716b65d8f2474eb9c8b4f68` and the current validated core. It checks:

- Public 0.2.0 default settings load with current defaults; agent listening remains Conversation
  and weather remains off.
- Current defaults and the optional one-question setting load in 0.2.0. Old code ignores the new
  listening option, so its behavior returns to the older conversation controls.
- The new `approximateLocation` weather grant is not understood by 0.2.0. Its reader rejects the
  settings and preserves the file. Disabling only Tools leaves this saved grant present.
- Explicitly turning **Weather forecasts** off removes the grant and restores 0.2.0 readability,
  while retaining other synthetic settings. The allowed weather hostname can remain harmlessly
  in the allowlist without a grant.

These are reader/writer checks against real versioned code. They do not perform or prove a signed
package downgrade, account access, or independent-client acceptance.

## Return to the stable host if needed

If the candidate is usable, turn **Weather forecasts** off before returning to 0.2.0. Quit AI Camera
before replacing its host bundle or restoring a settings file. Reinstall the retained signed
0.2.0 package through the normal installer and verify About/signature/generation. Keep the working
camera extension and audio driver installed; a host rollback does not need their removal.

If the candidate cannot open its settings, preserve its current settings file privately and restore
the pre-update copy while the app is closed. Do not reset or delete the notebook to fix configuration
compatibility. If no backup exists, use the newer host to disable Weather forecasts before retrying
the older host, or inspect the saved configuration privately before making a targeted repair.

Report a failed acceptance with the host version, source commit, exact control/request, expected
and observed behavior, and whether the independent client selected AI Camera Microphone. Keep raw
camera/microphone media, notebook contents, device identifiers, and credentials out of public reports.


## Local spoken translation

The **Voice** toolbar toggle starts off on launch and after a microphone/route shutdown. Select
**AI Camera Microphone** in the independent calling client first. Enable Whisper and translation
in Settings, download their models, and choose a language with an installed Mac voice. The Voice
control's help explains any missing requirement. This does not download or use a personal voice.

With headphones and the client recording only explicitly synthetic speech:

1. Turn Voice on and say a short fixed sentence. The client should receive your original microphone
   plus delayed translated speech. The original becomes quieter while the translation plays, then
   returns to its normal level. The app does not play translation through your local speakers.
2. Turn both caption toggles off: speech translation should continue without captions appearing.
   Pause the agent's listening or stop the agent: independently enabled Voice should continue.
3. Ask the agent a question. Its answer should interrupt translation, with no overlapping synthetic
   speakers. Voice resumes using newly captured speech after the answer drains, not old sentences.
4. Turn Voice off mid-sentence, change the translation language, and test mute/unmute. Old-language
   or pre-mute audio must not return. Full AI Camera mute stops original, translated, and agent audio.
5. Change the call's microphone or close the client. Voice should turn off and require explicit
   activation after a new route starts. A slow/failed translator should explain why Voice stopped
   while the original microphone continues. Calling-app mute detection remains tracked separately.

The native fixture uses an offline AVAudioEngine and fake transcription/translation completions,
so it needs no media permissions or installed models. Its optional `--system-voice` run synthesizes
two fixed English/Spanish sentences into memory, with no speaker playback or audio files. These
checks establish routing, format, bounded work, and cancellation; human bilingual review still
needs to assess latency, names, numbers, negation, and translation quality during a real call.
