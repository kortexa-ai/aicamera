# Realtime conversation and local camera tools

Status: design approved; implementation pending.

## Goals

AICamera will add an explicitly activated Realtime conversation path while retaining the existing
ASR → agent → TTS pipeline as a selectable fallback. The first local model tools render and clear
a transparent JavaScript/three.js overlay on the published camera frame.

The Realtime path must work with:

1. The documented OpenAI Realtime WebRTC endpoint.
2. An OpenAI-compatible WebRTC endpoint such as `api.server`.
3. An explicitly experimental ChatGPT/Codex subscription provider based on GooeyPi's proven but
   private Quicksilver protocol.

No provider may send microphone audio until the user explicitly arms one utterance.

## Provider dialects

### Canonical OpenAI

- Signal with multipart `POST https://api.openai.com/v1/realtime/calls`.
- Send the gathered SDP offer plus the bounded standard Realtime session object.
- Authenticate with a separate OpenAI API key stored in Keychain.
- Use the `oai-events` WebRTC data channel and standard function-call events.

### Compatible endpoint

- Signal with multipart `POST <base>/v1/realtime/calls`.
- Use the same standard session, SDP, data-channel, tool-call, and tool-result contract.
- Allow HTTPS public endpoints and HTTP only for loopback/private development endpoints under the
  existing endpoint policy.
- Store the bearer credential in Keychain or resolve it from an environment secret reference.
- `api.server` forwards any structurally valid bounded client-declared function tool. It does not
  execute tools. AICamera recognizes and executes only its own tool names.

### Experimental ChatGPT/Codex subscription

GooeyPi's subscription voice implementation was reverted from its current main branch, but its
historical implementation proves the following flow:

- OAuth authorization-code + PKCE through `auth.openai.com`, with refresh tokens.
- Signal with JSON to the private ChatGPT Codex Realtime route rather than `api.openai.com`.
- Use the Quicksilver/AVAS headers and fixed live model/voice expected by that service.
- Receive `delegation.created` rather than standard function calls; return bounded delegation
  context events.

This is an undocumented protocol and can change independently. The Settings UI must label it
**Experimental ChatGPT subscription**, isolate its wire adapter from the canonical adapter, and
store access/refresh tokens in macOS Keychain. AICamera must not read `~/.codex` or `~/.prime`
credential files. The OAuth implementation can follow the proven flow only after confirming the
client identity and product use are acceptable.

## User activation and state machine

The initial UX is one-shot click-to-talk with VAD and Stop:

```text
idle
  → connecting (microphone egress closed)
  → ready/muted
  → listening (user pressed Talk; egress gate open)
  → responding (VAD speech_stopped; egress gate closed)
  → ready/muted or idle after a short bounded timeout
```

Rules:

- **Talk** arms exactly one utterance.
- The outgoing audio track is disabled before connection and whenever the gate is closed.
- Server VAD `speech_started` confirms listening; `speech_stopped` closes the egress gate.
- A no-speech deadline and maximum-utterance deadline close the gate fail-closed.
- **Stop**, camera/microphone lane teardown, external-client takeover, endpoint change, and app
  termination close the gate first, invalidate the generation, stop queued speech, and close the
  peer if cancellation is not supported by the compatible endpoint.
- A visible state must distinguish connected/muted, transmitting, and responding.
- A short muted idle session can preserve latency and conversation context. It must release the
  self-hosted server's call lease after the bounded idle timeout.

Track disabling is not the sole software invariant. A generation-checked egress gate controls
whether captured samples may reach the sender, and tests must prove that stale callbacks cannot
reopen a stopped session.

## Native WebRTC and audio routing

Chromium supplies GooeyPi's WebRTC implementation. AICamera needs a native macOS framework. The
qualified candidate is LiveKit's Apache-2.0 `LiveKitWebRTC` XCFramework, which supports macOS
arm64/x86_64 and exposes:

- native peer connection, SDP, RTP, and data-channel APIs;
- `RTCAudioTrack.addRenderer` with `AVAudioPCMBuffer` callbacks for decoded remote audio;
- audio-device playout controls so remote audio can be routed into AICamera rather than played a
  second time by WebRTC.

Input can initially use WebRTC's microphone source with its local track disabled outside the
explicit gate. Output must use the remote audio renderer and copy bounded PCM into the existing
`SpeechPlaybackEvent.beginPCM/pcm/finishPCM` path. This keeps model speech in the current virtual
microphone mixer and preserves its one-second ingress and four-buffer bounds. The renderer callback
must only copy/admit data; it must never wait on UI or network work.

A spike must prove on macOS before full integration:

1. Standard signaling against canonical OpenAI and `api.server`.
2. Muted connection sends no microphone content.
3. One-shot unmute plus server VAD.
4. Remote PCM renderer format and bounded conversion into the existing mixer.
5. Stop/close releases capture, playout, the peer, and the server call lease.
6. Standard function call → local result → response continuation.

## Normalized host boundary

Provider-specific adapters emit one host contract:

```swift
enum RealtimeEvent {
    case connected
    case speechStarted
    case speechStopped
    case inputTranscript(String, final: Bool)
    case outputTranscript(String, final: Bool)
    case outputPCM(AVAudioPCMBuffer)
    case toolCall(id: String, name: String, argumentsJSON: Data)
    case responseFinished
    case failed(RealtimeFailure)
}
```

The exact type can differ, but Core must not import AppKit/WebKit. `PipelineCoordinator` owns the
session generation, fallback policy, transcript/scene updates, tool budgets, and response state.
`AppModel` owns the MainActor callback that invokes `OverlayScriptRenderer`.

Canonical and compatible adapters map standard function events. The experimental Codex adapter
maps bounded `delegation.created` JSON into the same tool call and maps the result back to delegation
context events.

## Overlay tools

The standard providers declare two client-owned function tools:

```text
render_overlay(script: string, ttlSeconds?: number)
clear_overlay()
```

The live tool description and system instructions provide host-owned facts:

- canvas width and height (currently 640 × 360);
- transparent background and premultiplied-alpha output;
- coordinate origin, orientation, output scaling, and camera mirror state;
- available `THREE` and `window.AICamera` APIs;
- `AICamera.onFrame(dt)` lifecycle;
- optional bounded scene data and its normalized coordinate/timestamp contract;
- no network, external assets, persistence, recording, or DOM/UI outside the canvas;
- one active script, replacement behavior, default TTL, maximum TTL, and script byte limit.

The model does not choose canvas dimensions. The host validates UTF-8 bytes, finite TTL, known tool
name, exact JSON argument types, maximum calls/rounds, current camera capability, and conversation
generation. Tool output returns only bounded success metadata or a bounded error.

The model does not receive raw camera frames through Realtime by default. Scene-aware overlays use
the existing clean inference summary and optional `AICamera.sceneData`. Generated overlays never
feed back into inference.

## Script sandbox prerequisite

Before model-triggered scripts ship, the app must prove subresource egress is blocked. The current
WebKit content-rule compiler fails on this SDK and cannot be the only control. Add and test a strict
CSP that blocks connections, remote media, frames, fonts, objects, workers, and navigation while
allowing only the bundled three.js/bridge and the required indirect evaluation. Keep the navigation
delegate and non-persistent data store as defense in depth.

Also enforce script TTL, fresh-frame expiry, web-content crash recovery, bounded frame rate, and
memory/CPU watchdog behavior. Remove or development-gate file diagnostics before release.

## Configuration and secrets

Add a Realtime section to Settings with:

- enabled and preferred/fallback mode;
- provider: OpenAI, compatible, or experimental ChatGPT subscription;
- base URL for compatible endpoints;
- model and voice where the provider permits them;
- Keychain credential action or environment secret reference;
- OAuth sign-in/sign-out for the experimental provider;
- connection/tool probe that does not enable microphone capture.

Profiles contain only endpoint metadata and secret references. API keys, bearer tokens, access
tokens, and refresh tokens never enter profile JSON, logs, tool output, or model context.

## Fallback policy

The legacy transcription, chat-completions agent, and speech clients remain intact.

- Setup failure before microphone transmission can fall back for the next explicitly armed
  utterance.
- Disconnect before any response side effect can retry within a small fixed budget.
- Disconnect after audio, text, or a tool side effect must not replay that turn through the legacy
  pipeline; report the failure and use fallback only for the next utterance.
- Realtime and legacy response generation must never run concurrently.
- Gesture and future vision-driven behavior can continue using the legacy path independently.

## Validation

Automated tests must cover configuration migration, secret isolation, SDP and event byte bounds,
redirect rejection, ICE/data-channel deadlines, egress gating, VAD timeouts, stale generations,
remote PCM bounds, Stop/teardown, unknown tools, malformed arguments, tool result continuation,
Codex delegation normalization, and deterministic fallback without duplicate side effects.

Acceptance order:

1. Microphone-free standard tool probe against `api.server`.
2. One-shot audio and overlay tool against `api.server`.
3. Explicit paid/API-key test against canonical OpenAI Realtime.
4. Separately labelled experimental ChatGPT subscription test.
5. Independent virtual-camera and virtual-microphone clients confirm composed video and model audio.
