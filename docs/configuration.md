# Configuration

AI Camera reads one schema-versioned JSON profile from:

```text
~/Library/Application Support/AI Camera/profile.json
```

Settings exposes the profile as individual controls and validates and atomically saves each change. **Reload** restores the last valid profile from disk. Import and export remain available for moving a complete profile. A valid change stops the currently active lanes and then reconciles current client demand with new controller snapshots.

A new profile is operational without model or hardware configuration. It uses system-default inputs with mirroring, overlays, video stages, conversation, and transcription disabled. This is the pure-passthrough base mode. If an existing profile is corrupt, too new, or invalid, the app preserves its file and blocks automatic camera and microphone capture until the user imports a valid profile or explicitly resets to defaults; it never silently runs the in-memory default instead. Start with [`Examples/kortexa-local.json`](../Examples/kortexa-local.json) only when AI processing is wanted. The Smarty preset is an example, not a runtime requirement.

## Import and export

Use **Settings → AI → Import…** or **Export…** to move a profile between
installations. Imports are limited to 1 MiB and must pass the same schema, endpoint, privacy,
and credential-reference validation as the active profile before they replace it. A rejected
import leaves the active profile unchanged.

Ordinary exports contain environment-variable or Keychain account references only. AI Camera
does not read or copy the referenced secret values during export; move those secrets separately
using the destination system's secure credential setup. Exported files are written with
owner-only permissions.

[`Examples/openai.json`](../Examples/openai.json) remains an importable compatibility example and
contains no credential value. The separate ASR, agent, vision, detection, and TTS choices currently
use services verified as running on Smarty. Realtime voice can instead use canonical OpenAI or a
custom OpenAI-compatible endpoint. Broader hosted and custom provider configuration is tracked
separately. The **Smarty Preset** button is available only in development builds, though its checked
example remains available for profile import.

## Capture

| Key | Meaning |
|---|---|
| `videoDeviceID` | Optional AVFoundation device unique ID. Omit it to use the compatible system-preferred physical camera. Software and Continuity cameras are excluded. If the system default is excluded, the app warns and uses the first compatible physical camera. |
| `audioDeviceID` | Optional Core Audio device UID. Omit it to use the system-default physical input. Software loopbacks and wired or wireless Continuity microphones are excluded. If the system default is excluded, the app warns and uses the first physical microphone. |
| `width`, `height`, `framesPerSecond` | Render and virtual-camera format. The extension publishes 640×480, 1280×720, and 1920×1080 at 15, 30, or 60 fps. |
| `mirrorVideo` | Mirror the rendered output and gesture coordinates. |
| `audioSampleRate` | Host mix rate. Use 44100 or 48000 for the bundled driver. |
| `audioChannels` | Capture profile channel request. The bundled virtual device is stereo. |
| `virtualAudioOutputDeviceID` | Core Audio output UID for the mix. Omitted values fall back to the bundled `ai.kortexa.aicamera.audio.device`; advanced profiles can name another duplex loopback device. |
| `microphoneGain`, `speechGain` | Nonnegative mixer gains. |

Stable IDs are discovered in the UI. Do not copy IDs from another Mac.

## Automatic lifecycle

The profile does not contain a manual running flag. The camera extension reports active source clients and the HAL driver reports recent input readers. The host polls these bounded signals and reconciles camera and microphone capture independently. No enabled AI stage means no model request is made. When the last relevant client closes, the host stops that physical input; when both lanes are idle it also cancels and releases the shared pipeline coordinator.

Configuration changes are applied by stopping current lanes, replacing the immutable controller snapshots, and reconciling current demand. Capture never waits for this work on a real-time callback.

## Endpoint adapters

| Adapter | Default route | Data sent |
|---|---|---|
| `openAIChat` | `/v1/chat/completions` | system/user prompt, transcript, optional scene metadata |
| `openAIVision` | `/v1/chat/completions` | JPEG frame and prompt |
| `openAITranscription` | `/v1/audio/transcriptions` | PCM16 WAV |
| `openAISpeech` | `/v1/audio/speech` | response text, voice, and speech format request |
| `openAIRealtime` | `/v1/realtime/calls` | realtime session options and live conversation media |
| `kortexaDetection` | `/detect` | multipart JPEG and confidence/model fields |
| `kortexaPCMTranscription` | `/transcribe/pcm?sample_rate=16000` | raw signed PCM16 mono bytes |

`path` replaces the compatible default route. `model` is sent only by adapters that use it. Common options are `temperature`, `max_tokens`, and `confidence`. Unknown option values remain inert unless an adapter reads them.

Chat, vision, and transcription responses use complete JSON or multipart HTTP requests. Speech defaults to a complete PCM16 RIFF/WAV response. For an endpoint that supports the Kortexa raw-audio contract, set `options.streamingPCM` to `true`. The speech adapter then sends `response_format: "pcm"` and `stream_format: "audio"` and consumes mono PCM16 little-endian bytes as they arrive. This option is endpoint-specific and is not a generic OpenAI API guarantee.

For streamed PCM, `x-sample-rate` on the response takes precedence over numeric `options.pcmSampleRate`; otherwise the adapter uses 24000 Hz. The accepted range is 8000 through 192000 Hz. A transport without streaming support falls back to complete WAV. Production transport still rejects redirects and cookies, caps the cumulative body at 32 MiB, splits chunks to a fixed size, and fails instead of dropping data when its bounded stream buffer fills.

## Authentication

The Kortexa API key field appears under the development-only Smarty controls, beside
the features that use it. The key authenticates HTTPS AI requests routed by `api.kortexa.ai` to
Smarty. Pure passthrough, local Apple Vision gesture detection, virtual-device maintenance, and
login-item management do not need it. The value is stored under Keychain service
`ai.kortexa.aicamera`, account `kortexa-api`; the profile stores only that account reference.

`auth.kind` is one of:

- `none`
- `bearerEnvironment`
- `apiKeyEnvironment`
- `bearerKeychain`
- `apiKeyKeychain`

`reference` is an environment-variable name or a Keychain account name, never the secret itself. `header` and `prefix` are configurable. For example:

```json
"auth": {
  "kind": "bearerEnvironment",
  "reference": "AICAMERA_API_KEY",
  "header": "Authorization",
  "prefix": "Bearer "
}
```

For an advanced imported endpoint, add a secret without putting it in shell history:

```sh
security add-generic-password -U \
  -s ai.kortexa.aicamera \
  -a my-endpoint-account \
  -w
```

## Video stages

Each stage has a stable `id`, `kind`, enable switch, optional endpoint, maximum request rate, maximum accepted frame age, prompt, and options.

- `handGesture` uses Apple Vision locally and needs no endpoint.
- `objectDetection` normally requires a `kortexaDetection` endpoint. A local stage instead sets `options.provider` to `builtin` and `options.model` to `yolov3-tiny`, `rfdetr-medium`, or `rfdetr-large`; it needs no endpoint.
- `visionLanguage` requires an `openAIVision` endpoint.

A stage keeps at most one in-flight request and one replaceable pending frame. Slow results that exceed `maximumFrameAgeMilliseconds` are discarded.

Local object-detection weights are explicit downloads. The app verifies pinned SHA-256 hashes, compiles the selected Core ML package once, and stores only the compiled model in the user's Application Support directory. RF-DETR Medium is the default recommendation; Large is the higher-accuracy option for M4 Pro / M3 Max-class hardware and above. The generic macOS Core ML packages and provenance are published at [`kortexa-ai/rf-detr-coreml`](https://huggingface.co/kortexa-ai/rf-detr-coreml). Removing a model disables its active stage before deleting the compiled asset.

## Transcription and conversation

Transcription is an independent AI feature. It can remain enabled when Conversation is disabled,
and finalized microphone windows are then sent to the selected ASR endpoint for transcript display
and optional local translation. Settings configures OpenAI first, uses `gpt-transcribe` by default,
and stores the shared OpenAI API key in Keychain. Disabling Transcription also disables translation
and transcript display; it does not affect microphone passthrough.

Normal Settings currently exposes OpenAI only. Embedded Whisper is tracked separately and will not
appear as a provider until its weights can be downloaded, verified, inspected, and removed with the
same local-model lifecycle used by the embedded vision and translation models. Custom transcription
endpoints remain a profile-level compatibility capability and are not offered in the product UI yet.

Conversation selects realtime, agent, and speech endpoint IDs. Settings offers mutually exclusive
**Separate ASR + agent + TTS**, **OpenAI Realtime**, and **Compatible Realtime** voice pipelines.
Saving either Realtime choice disables transcription-driven replies and gesture-driven legacy
replies, preventing the separate response path from running concurrently. Independent Transcription
may remain enabled; while a Realtime session is active, its transcript is reused and batch ASR is
suppressed so the same audio is not uploaded twice.
Set `realtimeEnabled` and `realtimeEndpointID` to use an `openAIRealtime` endpoint. Signaling uses the
endpoint's HTTP(S) base URL and `POST /v1/realtime/calls`. Existing profiles default realtime to
disabled when these keys are absent.

Canonical OpenAI and each compatible host use distinct Keychain account references so changing a
base URL cannot silently send one provider's saved bearer token to another provider.

The legacy transcription, agent, and speech roles remain valid as fallback paths and can coexist with realtime. These roles can be omitted independently. `transcriptionEnabled` controls ASR independently of `conversation.enabled`, without disabling microphone passthrough or barge-in. `utteranceSeconds` controls fixed 16 kHz ASR windows from 0.5 through 30 seconds. The current speech gate rejects all-silence windows; it is not a full VAD.

`activationMode` is `wakePhrase` or `alwaysListening`. Checked-in profiles use `wakePhrase`. In that mode, `respondToFinalTranscripts` allows only accepted final ASR text to reach the agent: a leading, case-insensitive `wakePhrase` either prefixes a command or arms the next speech-bearing utterance for `wakeWindowSeconds` (1 through 30). The phrase must contain at least one letter or number and is limited to 128 characters. The deadline uses each utterance's monotonic capture time, so ASR latency cannot extend or shorten the physical window. Fixed ASR windows can still split a phrase at a boundary; bounded overlap is deferred.

Schema-1 profiles that omit `activationMode` retain their former always-listening behavior. If `transcriptionEnabled` is omitted, it is true only when the legacy profile has a transcription endpoint. Settings exposes conversation, ASR, agent-reply, activation-mode, wake-phrase, and bounded wake-window controls.

One ASR request and one pending window are bounded independently from the agent/TTS turn, so ambient transcription cannot cancel an active response. Always-listening mode replaces the pending window with the latest one. Wake mode preserves the first pending window so a command immediately after a wake-only window is not overwritten by later speech. `respondToGestures` sends an edge-triggered gesture description directly to the agent without consuming the voice gate. `gestureCooldownSeconds` limits repeated gesture turns. `bargeIn` stops the active TTS/agent turn and queued speech when microphone energy is detected during playback, even if that speech does not contain the wake phrase.

## Privacy

The default `localOnly` mode permits only `localhost`, `127.0.0.1`, and IPv6 loopback. A non-loopback URL must:

1. use HTTPS;
2. use `allowListed` mode;
3. have an exact host in `allowedHosts`; and
4. have an exact endpoint grant for every data class the adapter sends.

Data classes are `rawAudio`, `rawFrame`, `transcript`, `sceneMetadata`, and `promptText`. A missing grant fails closed before the request is built. Production HTTP uses an ephemeral session with no cookie or URL cache. Redirects are rejected so a permitted endpoint cannot forward media to another host; configure the final canonical URL directly.

`persistMedia` must remain `false`. The current app has no media persistence implementation.
