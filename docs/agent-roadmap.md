# A useful companion during a call

AI Camera should help the person using it remember something, understand an answer, or explain
an idea without making them leave the conversation. The camera feed is a shared canvas. A small
visual can answer a question while the people keep talking.

## Start with attention and control

The user starts the agent, asks a question, and returns to their conversation. Agent input must
stay separate from the microphone sent to the call. Pausing the agent's listening must preserve
an answer or tool operation already in progress. A one-question mode should wait for an explicit
Ask again action after each question; the existing continuous mode remains available.

Use a visible input state and a direct shortcut as the authority. A later small local model can
help recognize addressed speech, but an uncertain classification must never open a user-closed
input gate. Background speech, conversation with another person, or a television should not
trigger acknowledgements. This needs real conversational evaluation, not just a clever prompt.
The first [offline LFM2/LFM2.5-350M probe](addressed-speech-probe.md) also failed basic JSON
input-reading controls, so its classifier counts are inconclusive. The inference setup needs
qualification before further feature work; no automatic classifier is wired into the app.

## Useful tools in a small vocabulary

These are design targets, not a claim that every tool is available. Advertise only implemented
tools whose capabilities are available in the current session.

The current host implementation provides `save_note`, `list_notes`, `delete_note`, `show_card`,
`clear_cards`, `render_overlay`, `clear_overlay`, `wait_for_user`, `sleep_agent`, `get_camera_state`,
`set_translation`, `set_camera_layout`, `calculate`, `render_face_effect`, `start_timer`, and the opt-in
`get_weather_forecast`. Notes and
calculation require enabled Tools; visual tools also require an active camera,
and translation control requires configured caption translation. Independent input pause and
one-question mode are available on `main`. U.S. weather forecasts use the public NWS service with
explicit approximate-location permission; see [weather forecasts](weather-forecasts.md). Market
quotes and worldwide weather, spoken translation,
external image/slide assets and richer face tracking remain planned capabilities.
The [spoken-translation design](spoken-translation-design.md) defines the separate interpreter
input and audio-output work before exposing a voice-translation tool.
Quiet native countdowns share the transient card slot and need no model work after starting.
Requested face effects now use a bounded local 2D anchor; see [face effects](face-effects.md).
The current presentation mode uses the existing generated three.js scene with a bounded camera inset.

| Job | Tool family | Example |
| --- | --- | --- |
| Remember | Save, find, edit, delete a local note | “Remember to send Maya the draft tomorrow.” |
| Make an answer readable | Show and clear a small information card | A definition, three key points, or a number with units |
| Make an idea memorable | Render and clear a bounded three.js scene | A little orbiting solar system explaining an eclipse |
| Check current facts | Weather, market quote, and later sourced web lookup | A forecast with its place/date, or a quote with currency and market timestamp |
| Control the call's presentation | Translation state/language, camera layout, slide/image | “Put the chart full screen and me in the bottom-right corner.” |
| Finish without chatter | Wait silently, pause listening, end the agent session | “Go to sleep.” |
| Keep a discussion moving | Timer, agenda, small checklist, decision card | “Give us a quiet two-minute timer.” |
| Explain accurately | Bounded calculation, conversion, comparison | “Show the monthly cost for those two options.” |

Keep state-changing actions explicit and reversible. A note is saved only when requested; the
app does not silently turn a call into a transcript archive. Saving a note does not publish it.
Showing its contents in the camera requires a separate request. The user can inspect and remove
notes locally. Spoken interaction and enabled captions are still part of the outgoing call.

Current facts need actual lookup results. The model's general knowledge is not a current weather
or stock-price feed. Data tools return a source, retrieval time, relevant measurement/market time,
units, and any delay or geographic limitations. Unsupported or unavailable lookups return a clear
failure. Selecting data providers includes checking their licensing, commercial-use terms, access
requirements, coverage, and operational limits. Do not scrape an undocumented endpoint into the
product just to make a demo appear live.

## Visual language

- Prefer one compact, readable card for a useful answer. Use a title, the essential fact, and a
  short source/time footer when applicable. Leave the person's face and caption area clear.
- Offer charming illustrations when they help: a sunny character, a tiny raincloud, a miniature
  globe, an animated clock, a little rocket for a milestone, or a plant growing with a progress bar.
- Keep facts legible even if an animation fails. The model can choose the expression; the host owns
  safe bounds, duration, placement, clearing, and media composition.
- Rich visuals use the existing bundled three.js runtime. Scripts cannot fetch external assets,
  record media, write files, or create their own renderer. Simple cards use a deterministic native
  renderer so text does not depend on the model implementing typography correctly.
- Requested face-following graphics use the local single-face anchor and hide when tracking is
  lost. Keep fixed scenes distinct, and do not promise hair-aware placement, occlusion, or a dense
  3D mesh. Real movement and lighting still need acceptance.
- A presentation layout should retain an easy return to the full camera, preserve camera aspect
  ratio, and place the original video above the slide in the actual virtual-camera output.

## Realtime instructions

Realtime provides session instructions and function tools. The host already sends both through
`session.update`. Keep a short product prompt, then add only the relevant tool/renderer contract.
The user's configured tone can supplement this contract without claiming unsupported capabilities.

Suggested product prompt:

> You are AI Camera, a helpful companion for the person using this camera during a live call.
> Keep spoken answers brief, usually one sentence. Let the people keep talking. Respond to requests
> addressed to you; use the available silent-wait tool for background or unrelated conversation.
> Ask one short question when a required detail is missing. Use a small information card when a
> visual answer would help; use tasteful three.js illustrations when requested or useful. Keep
> faces, captions, and status clear. Save only notes the user asks you to remember, and do not
> display saved notes unless asked. For current facts, use an available lookup and preserve its
> source, time, and units; say when no current source is available. Use only the provided tools.
> Confirm actions only after a successful tool result. Respect pause, mute, and disabled features.
> Stop your session when the user clearly asks you to go to sleep.

The shipped prompt must name a wait, note, information, lookup, or sleep tool only when that tool
is in the actual session list. Tool results and saved text are data, not instructions that can
override this contract. Do not add ritual confirmation dialogs to an explicit request to show a
card or save a note; clarify only a meaningful ambiguity.

Official guidance supports [session tools and function results](https://developers.openai.com/api/docs/guides/realtime-conversations#function-calling)
and recommends clear [instructions, tool availability, and silent waiting](https://developers.openai.com/api/docs/guides/realtime-models-prompting).
Use the installed user's working model selection; this roadmap does not require a model migration.

## Implementation order

1. Separate agent listening from call audio, with explicit pause/resume and one-question mode.
2. Bound multi-step tool sequences and keep tool work out of the ordered media-event consumer.
3. Add requested local notes and readable information cards; refine the prompt against fixtures.
4. Add a grounded current-information provider, then prove lookup → visual → short reply end to end.
5. Extend live translation controls, sleep, and presentation composition under [#57](https://github.com/kortexa-ai/aicamera/issues/57).
6. Add face anchors and playful effects under [#45](https://github.com/kortexa-ai/aicamera/issues/45).
7. Evaluate smarter addressed-speech detection and richer tools only against real user benefit.

Each increment needs deterministic invalid-input, stale-result, cancellation, timing, and privacy
checks plus a synthetic camera/audio fixture. Live hardware or account acceptance is recorded
separately. The stable published release and working system components remain available while
new host behavior is tested. Current implementation evidence is tracked in
[#58](https://github.com/kortexa-ai/aicamera/issues/58).
