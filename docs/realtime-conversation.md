# Realtime conversation and local camera tools

The current product target is OpenAI Realtime with an API key or a dedicated Codex login, plus
embedded local transcription, translation, and video processing. Compatible services, api.server,
and Hermes are outside this phase. Virtual-camera component activation/acceptance is deferred.

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
Agent off, Connecting, Listening, Thinking, Speaking, Muted, or Agent unavailable. A victory/fist
hold shows progress; uncertain poses ask for a clearer hand. The orb and title follow Overlays →
Show Status. Connection failures also leave their details in the AI Camera menu. The native status
layer is independent of model-generated overlays and is never included in clean inference frames.

Hand confidence averages the required usable landmarks, so a single partly hidden folded joint
does not veto an otherwise clear pose. Activation still requires 80% aggregate confidence, a
continuous 0.8-second hold, fresh observations, and release before repeating the same control.
Hand inference uses its own bounded queue so image preparation cannot delay it.

One server conversation retains context across utterances. Input closes during response generation
and playback, then rearms only after both reply outputs drain. There is no idle listening timeout;
an utterance is bounded to 30 seconds, a response to 120 seconds, and final playback to 125 seconds.
Stop agent, fist mute, teardown, failure, and configuration/routing changes cancel the session and
reject late work. Stop releases only agent-owned microphone demand. Changing a call's microphone
routing rebuilds the media graph and requires explicitly starting the agent again.

Hold a fist to mute audio, stop the agent, and clear captions. Unmute explicitly in AI Camera;
victory cannot silently unmute. Receiving apps' own mute buttons are not currently synchronized.

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
is active. Continuation disables further tools for that response.

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
