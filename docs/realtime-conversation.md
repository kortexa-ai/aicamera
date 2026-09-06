# Realtime conversation and local camera tools

The current product target is OpenAI Realtime with an API key or a dedicated Codex login, plus
embedded local transcription, translation, and video processing. Custom service integrations are
outside this phase. The host publishes its composed output through the small camera extension.

## Public OpenAI transport

The host depends on the `RealtimeConversationClient` protocol in `AICameraCore`. Its native
implementation connects directly to `wss://api.openai.com/v1/realtime?model=…`. Credentials are
resolved from Keychain or an environment reference. They never enter profile JSON or the
session/model context. The host waits for `session.updated` before arming input.

Microphone capture stays in the existing AVCapture pipeline. Its selected hardware samples are
converted in memory to 24 kHz mono PCM16; the software gate admits them only after Talk arms the
current turn. The public WebSocket protocol carries audio and control events in one ordered
stream. Output PCM enters the host's existing bounded player. This removes a second microphone
capture path and makes device selection and microphone gating independent of a WebRTC audio
module. The previous native module could not bind the selected input reliably on this Mac.

Redirects are rejected, individual received messages are capped at 256 KiB, and outbound work is
limited to 64 messages / 512 KiB with at most one second of microphone PCM including the in-flight
send. At most two capture chunks may wait for admission. Overflow and connection deadlines close
the turn. Network sends never wait inside capture callbacks.

See the [OpenAI WebSocket guide](https://developers.openai.com/api/docs/guides/realtime-websocket)
and [Realtime conversation guide](https://developers.openai.com/api/docs/guides/realtime-conversations).

## Deliberate conversation activation

Hold a victory sign for about one second with Gestures enabled, or choose **Start agent** in
AI Camera's menu. Both use the same host conversation path while QuickTime or another app consumes
the virtual camera. The popup's local Test camera and Test microphone controls are independent.
Activation starts the selected physical microphone when needed; receiving-app microphone demand
continues independently. A call selecting **AI Camera Microphone** receives the mixed microphone
and agent reply, and the agent reply also plays locally without microphone monitoring.

The outgoing image shows an animated status orb below the top-right client-title-bar margin:
Agent off, Connecting, Listening, Not listening, Thinking, Speaking, Muted, or Agent unavailable. A victory/fist
hold shows progress; uncertain poses ask for a clearer hand. The orb and title follow Overlays →
Show Status. Connection failures also leave their details in the AI Camera menu. The native status
layer is independent of model-generated overlays and is never included in clean inference frames.

Hand confidence averages the required usable landmarks, so a single partly hidden folded joint
does not veto an otherwise clear pose. Activation still requires 80% aggregate confidence, a
continuous 0.8-second hold, fresh observations, and release before repeating the same control.
Compact four-finger flexion takes priority over thumb–index contact: a thumb tucked against the
index finger is still a closed fist. Pinches outside that compact fist shape remain pinches.
Hand inference uses its own bounded queue so image preparation cannot delay it.

One server conversation retains context across utterances. Input closes during response generation
and playback, then rearms only after both reply outputs drain. There is no idle listening timeout;
an utterance is bounded to 30 seconds, a response to 120 seconds, and final playback to 125 seconds.
Stop agent, fist mute, teardown, failure, and configuration/routing changes cancel the session and
reject late work. Stop releases only agent-owned microphone demand. Changing a call's microphone
routing rebuilds the media graph and requires explicitly starting the agent again.

Hold a fist to mute audio, stop the agent, and clear captions. Unmute explicitly in AI Camera;
victory cannot silently unmute. Receiving apps' own mute buttons are not currently synchronized.

### Keep talking to the other people on the call

**Pause listening** in the popup, or **Control–Option–L**, closes only the agent's input.
An answer or tool operation already in progress continues, and the call's microphone stays live.
Pausing before a question has finished discards that incomplete input. **Ask again** resumes
listening once the current answer has drained. Audio captured before resuming is rejected.

Settings → AI → Conversation → **Listening** offers **Conversation** (the existing automatic
rearm behavior) and **One question at a time**. The latter closes agent input when your question
ends and waits for Ask again after answering. The outgoing status orb then says **Not listening**.
The agent session retains its context. Configured independent transcription resumes while the
agent is paused after its reply; it may still use OpenAI if that is your selected transcription
provider. Agent input pause is separate from AI Camera's audio/caption privacy mute.

Control–Option–L uses L for listening and leaves the macOS
[input-language shortcut](https://support.apple.com/en-au/guide/mac-help/mchlp1406/mac) available.
The listening shortcut is available without monitoring general keyboard input. If another app
owns it, the popup reports the conflict and its listening button remains available. These host
changes have synthetic transport coverage; installed UI/voice acceptance is a separate check.

Independent transcription and legacy response generation pause during Realtime. Partial ASR
windows and resampler state are discarded at each transition, so audio from a Realtime turn cannot
be uploaded later in a batch transcription request. Translation of
final captions has one active task and one replaceable pending value; it does not hold the event
consumer while PCM and Stop events arrive. Transcript deltas accumulate within bounded captions.
Explicit Stop and failure cancel pending caption translations even when the camera pipeline stays
active. Normal completion lets final translation finish. New turns and pipeline shutdown reject
retired work, and canceled event consumers cannot admit more captions.

## Bounded audio and event ownership

PCM and `response.done` arrive on the same ordered WebSocket stream, so completing a response
needs no guessed RTP tail delay. The host drains its bounded playback queue before releasing the
Talk-owned test. Large PCM messages are split into at most one-second player inputs without losing
their final samples. Generation checks reject stale transport, translation, and playback completions.
Only the host player emits audio; it cannot attach duplicate renderers to one remote track.

Tool outputs use the same serialized send queue. The host returns all function results before
requesting continuation on `response.done`; it must not start a second response while the first
is active. A user question permits at most eight unique calls and three tool-bearing responses.
The final continuation disables tools. Local tool tasks execute in order outside the media-event
consumer, so a note write cannot hold up arriving audio or Stop. Failure, Stop, and a new session
invalidate pending effects and continuations. An already completed requested note remains saved.

## Notes, cards, and quiet responses

With **Tools** enabled, `save_note`, `list_notes`, and `delete_note` operate on a local notebook.
Optional `id` on save edits an existing note; deletion requires an exact UUID. Lookups return at
most five matching notes, newest first. The **Notes** footer button opens a window for writing,
editing, searching, and deleting without starting the agent or camera.

Only requested note text is saved, at `~/Library/Application Support/AI Camera/Notes/notes.json`.
There are at most 100 notes of 2,000 UTF-8 bytes each. Writes are atomic and the file is owner-only.
An unreadable notebook is preserved instead of silently replaced. It is ordinary local storage,
not an encrypted vault. A requested note lookup returns matching text to the active Realtime
conversation; the notebook is not automatically included when connecting. Saving a note and
showing it to other people are separate actions. Existing spoken/transcribed content still follows
the user's caption settings.

`show_card` displays one short plain-text card in the outgoing camera; `clear_cards` removes it.
Styles are information, sticky, or metric, with four corner positions and a 1–300 second lifetime
(30 seconds by default). A new card replaces the old one. The host reserves status/caption space,
limits text, and caches its rasterized pixels. Cards and three.js illustrations can coexist.
Visual tools require an active camera and enabled Tools. Privacy mute and disabling Tools clear
the card; clean inference images never include it. An extremely small frame with no available
caption-free space can omit a card rather than cover captions.

The session always offers `wait_for_user` and `sleep_agent`. Wait suppresses remaining response
audio and continuation for unrelated conversation; it does not override the user's listening
mode. Sleep stops the agent session while independent call media and enabled features continue.
The explicit input gate remains the authority; a prompt is not a reliable mute mechanism.

Try “Remember to send Maya the draft,” “Show three short points about this idea,” or “Go to sleep.”
The opt-in `get_weather_forecast` tool provides sourced U.S. NWS forecasts; see
[weather forecasts](weather-forecasts.md). Current observations, worldwide weather, and market prices
are not available through this provider. Instructions
require the agent to say when it cannot verify current facts and to report tool success honestly.

## Requested face effects

`render_face_effect` activates a bounded local face anchor for an explicitly requested
face-following graphic. It requires enabled Tools, an active camera, and full-camera layout.
A successful call waits for one clear face; tracking loss hides the graphic. Clear, expiry, normal
overlay replacement, privacy mute, and camera shutdown stop or hide the effect. Landmarks stay
local and are not added to the Realtime conversation. See [face effects](face-effects.md).

## Quiet on-camera countdowns

With Tools and an active camera, ask for a countdown such as “Give us two minutes to discuss
this.” `start_timer` accepts 1–3600 whole seconds and an optional short label. A native card shows
minutes and seconds, then “Time’s up” for five seconds before disappearing. The host owns the
elapsed-time clock; no model request, sound, or notification fires at completion.

The countdown shares the information-card slot. A new card or timer replaces it; `clear_cards`
or **Reset view** cancels it. Privacy mute, disabling Tools, or camera shutdown clears it too.
Pausing agent input leaves it running while you keep talking. This is a transient visual during
an active camera session, not a saved reminder or an alarm that runs after sleep, quit, or restart.
An optional label is visible to everyone who can see the camera output.

## Local arithmetic

With Tools enabled, `calculate` checks a decimal expression before the agent states or displays a
computed result. It accepts numbers, parentheses, and `+`, `-`, `*`, `/`. For a percentage, use an
explicit expression such as `200 * 15 / 100`. The tool does not evaluate code, access files, look
up prices, or infer units. It works without a camera; displaying a result still requires one.

The parser limits input to 512 UTF-8 bytes, 64 operations, 16 nesting levels, and 12 fractional
digits per literal. Magnitude cannot exceed 10^24 at any step. Each operation rounds to at most
12 decimal places and the result reports whether rounding occurred. Division by zero, invalid
syntax, excessive precision, and out-of-range intermediate values produce a clear error. The
response retains the expression and a decimal string instead of converting the result to a
binary floating-point number.

This verifies arithmetic, not its assumptions. The agent must preserve the user's units, explain
any material rounding, and use a current source when an input depends on a price or exchange
rate. For example, `(19.99 - 17.50) * 12` gives `29.88`; a card can label that as an annual difference
only when the two provided prices are monthly and use the same currency.

## Live caption translation controls

With Tools enabled, `get_camera_state` reports current translation configuration/on-off state,
model readiness, source/target language, privacy mute, and requested agent listening. It exposes
no endpoint, credential, notebook, or captured media. `set_translation` is available when caption
translation is configured. Its optional `enabled` boolean operates the same quick control as the
toolbar, and its optional `targetLanguage` changes the saved target in Settings. At least one
change is required. Supported targets come from the same language catalog as the Settings picker.

“Translate into Spanish” can set both `enabled: true` and `targetLanguage: "es"`; “Turn translation
off” changes only the quick control. Changing a selected language alone leaves the on/off state
alone. Enabling requires a ready model. These tools neither download/enable an unconfigured
feature nor unmute AI Camera. Their output is captions, not spoken translation.

The remaining voice-output work has a separate [spoken-translation design](spoken-translation-design.md)
covering original/translated audio, independent agent input, local monitoring, and output ownership.

Source/target language changes from Settings or the agent reuse the live media graph and keep
the Realtime session connected. The runtime caption generation changes immediately, retires
older translated results, and keeps one active/latest-pending translation worker. Every other
configuration change keeps the existing media-restart path. New captions use the new language;
the previous displayed caption is cleared rather than retranslated from stored speech.

## Local overlay tools

The session advertises `render_overlay` and `clear_overlay` only when Tools is enabled and an
active camera renderer exists. The executor checks those capabilities again before side effects.
Unknown tools, unknown argument fields, malformed JSON, non-string scripts, non-numeric/boolean
TTLs, and out-of-range TTLs are rejected. Script and argument byte limits are separate. Omitted
TTL uses the configured default. The transport admits at most eight unique tool calls per turn.

The host owns the 640 × 360 transparent canvas, mirror description, available THREE/AICamera APIs,
TTL, script size, replacement behavior, and scene-data permission. Scripts cannot choose another
canvas or fetch external assets. The existing CSP, navigation restrictions, non-persistent WebKit
store, TTL, fresh-frame expiry, and crash handling remain required. Tools receive no raw frames.

## Presentation and camera inset

After `render_overlay` has produced a scene, `set_camera_layout` with `mode: "inset"` uses that
scene as a full-frame presentation and places the live camera above it. The default is lower-right
at one fifth of the frame **width**, with height preserving aspect ratio. Position accepts the
four card-corner names; width fraction is 0.15–0.5, constrained further when needed to reserve
status and caption space. The result reports the effective width fraction. Layout lifetime is
1–300 seconds, default 30. Very small output sizes without usable caption-free space are rejected.

The executor waits at most three seconds for an existing renderer frame before accepting inset
mode. Capture never waits. If a scene frame becomes stale/missing, or the layout expires, the
compositor immediately shows the normal camera. Expiration suppresses even a still-fresh scene
until the cleanup task clears it, preventing a full-frame graphic from hiding the restored camera.
Returning scene frames may restore a still-live inset; graphics are always below the live camera.
Object boxes and gesture labels follow the camera transform and are clipped to its inset. A card
on the same side moves to the opposite side so it cannot cover the live camera.

`set_camera_layout` with only `mode: "camera"`, or **Reset view** in the popup while an inset is
requested, clears generated graphics/cards and restores the full camera. Saved notes and native
captions remain. `clear_overlay` also restores full camera while retaining a separate card.
Privacy mute and Tools/camera shutdown retire the layout. Clean inference frames remain full-size
camera images with no scene, inset, cards, or status labels.

This provides generated-scene presentation. Loading arbitrary external image URLs or a slide deck
is not implemented, and the camera inset does not perform face tracking.

## Dedicated Codex login

The installed official Codex CLI owns an isolated device-login, refresh, and sign-out lifecycle
for AI Camera. It uses a separate home and Keychain item; the desktop agent's login is not copied
or rotated. The app reads the current access token only into memory for public Realtime. It never
falls back to a saved API key when Codex is selected. See [authentication details](codex-login.md).

Dedicated sign-in, managed refresh, silent session acceptance, and user-heard responses with normal
playback have passed in the signed host. This is observed account behavior, not evidence that
Realtime audio is covered by a subscription. Real-account sign-out was not forced during acceptance
because that would discard the user's completed login; the bounded logout path is implemented and
its disposable-home lifecycle was tested.

## Overlay runtime and acceptance

The renderer now validates fixed-size generation-tagged frames before decoding, acknowledges one
frame at a time, and clears old pixels immediately on replacement. A fresh document releases the
previous script's globals and timers. Clear/expiry remove pending output. Script logs remain bounded
in memory. See [the renderer contract](overlay-script-renderer.md).

Core policies, signed native Talk, selected microphone ownership, Stop/no-speech handling, normal
playback, local model inference, and Settings have recorded evidence in [VALIDATION.md](../VALIDATION.md).
Synthetic runtime/tool probes cover the remaining operations without recording user media. Final
live translated-caption and voice-invoked tool checks must be distinguished from synthetic tests.
Virtual-camera component activation and current external-client acceptance remain deferred.

The standalone public tool probe requests a synthetic response, returns `function_call_output`,
and waits for `response.done` before asking for continuation, following OpenAI's
[Realtime conversation contract](https://developers.openai.com/api/docs/guides/realtime-conversations).
No microphone audio is supplied; received PCM is validated in memory and is not played or saved.
