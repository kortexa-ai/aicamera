# Configuration

AI Camera reads one schema-versioned JSON profile from:

```text
~/Library/Application Support/AI Camera/profile.json
```

Edit it in the Settings window. **Apply JSON** validates and atomically saves it. **Reload from disk** discards unsaved editor text. Device selections in the menu-bar panel also update this file.

Start with [`Examples/kortexa-local.json`](../Examples/kortexa-local.json) or [`Examples/remote-openai-compatible.json`](../Examples/remote-openai-compatible.json). The local preset is an example only. No service address, model, hardware ID, or credential is a runtime requirement.

## Capture

| Key | Meaning |
|---|---|
| `videoDeviceID` | Optional AVFoundation device unique ID. Omit it to use the first hardware camera. |
| `audioDeviceID` | Optional Core Audio device UID. Omit it to use the current system input. |
| `width`, `height`, `framesPerSecond` | Render and virtual-camera format. The extension publishes 640×480, 1280×720, and 1920×1080 at 15, 30, or 60 fps. |
| `mirrorVideo` | Mirror the rendered output and gesture coordinates. |
| `audioSampleRate` | Host mix rate. Use 44100 or 48000 for the bundled driver. |
| `audioChannels` | Capture profile channel request. The bundled virtual device is stereo. |
| `virtualAudioOutputDeviceID` | Core Audio output UID for the mix. The bundled value is `ai.kortexa.aicamera.audio.device`; another duplex loopback device can be selected. |
| `microphoneGain`, `speechGain` | Nonnegative mixer gains. |

Stable IDs are discovered in the UI. Do not copy IDs from another Mac.

## Endpoint adapters

| Adapter | Default route | Data sent |
|---|---|---|
| `openAIChat` | `/v1/chat/completions` | system/user prompt, transcript, optional scene metadata |
| `openAIVision` | `/v1/chat/completions` | JPEG frame and prompt |
| `openAITranscription` | `/v1/audio/transcriptions` | PCM16 WAV |
| `openAISpeech` | `/v1/audio/speech` | response text, voice, and WAV request |
| `kortexaDetection` | `/detect` | multipart JPEG and confidence/model fields |
| `kortexaPCMTranscription` | `/transcribe/pcm?sample_rate=16000` | raw signed PCM16 mono bytes |

`path` replaces the compatible default route. `model` is sent only by adapters that use it. Common options are `temperature`, `max_tokens`, and `confidence`. Unknown option values remain inert unless an adapter reads them.

OpenAI-compatible clients currently use non-streaming JSON/HTTP requests. TTS responses must be PCM16 RIFF/WAV.

## Authentication

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

The Keychain service name is `ai.kortexa.aicamera`. Add a secret without putting it in shell history:

```sh
security add-generic-password -U \
  -s ai.kortexa.aicamera \
  -a my-endpoint-account \
  -w
```

## Video stages

Each stage has a stable `id`, `kind`, enable switch, optional endpoint, maximum request rate, maximum accepted frame age, prompt, and options.

- `handGesture` uses Apple Vision locally and needs no endpoint.
- `objectDetection` requires a `kortexaDetection` endpoint.
- `visionLanguage` requires an `openAIVision` endpoint.

A stage keeps at most one in-flight request and one replaceable pending frame. Slow results that exceed `maximumFrameAgeMilliseconds` are discarded.

## Conversation

The optional conversation selects transcription, agent, and speech endpoint IDs. These roles can be omitted independently. `utteranceSeconds` controls fixed 16 kHz ASR windows. The current speech gate rejects all-silence windows; it is not a full VAD.

`respondToFinalTranscripts` routes ASR text to the agent. `respondToGestures` sends an edge-triggered gesture description to the agent. `gestureCooldownSeconds` limits repeated gesture turns. `bargeIn` stops an active TTS/agent turn when microphone energy is detected during speech output.

## Privacy

The default `localOnly` mode permits only `localhost`, `127.0.0.1`, and IPv6 loopback. A non-loopback URL must:

1. use HTTPS;
2. use `allowListed` mode;
3. have an exact host in `allowedHosts`; and
4. have an exact endpoint grant for every data class the adapter sends.

Data classes are `rawAudio`, `rawFrame`, `transcript`, `sceneMetadata`, and `promptText`. A missing grant fails closed before the request is built. Production HTTP uses an ephemeral session with no cookie or URL cache. Redirects are rejected so a permitted endpoint cannot forward media to another host; configure the final canonical URL directly.

`persistMedia` must remain `false`. The current app has no media persistence implementation.
