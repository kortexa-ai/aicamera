# Settings

A new installation uses pure passthrough. AI, transcription, overlays, and mirroring are off.
Configure the app in **Settings → General**, **AI**, and **Privacy**. Changes are validated and
saved atomically. Feature toggles apply immediately; Conversation and Transcription provider,
authentication, model, and language drafts apply only when saved. Changing an active configuration
restarts its processing with new immutable settings; media callbacks never wait for this work.

Settings import/export and custom endpoints are hidden for this product phase.

## General

Choose the camera and microphone, camera size and frame rate, mirroring, microphone gain, and
launch-at-login behavior. Only recognized direct local hardware is eligible. If System Default
resolves to an excluded input, the app warns and selects an eligible device. Device identifiers
are specific to each Mac.

Virtual-device installation and maintenance are separate from local testing. They can require
macOS approval. The host starts physical capture only for matching virtual-device demand or an
explicit local test; Talk can temporarily acquire the selected microphone for one utterance.

## Conversation

Choose **API key** or **Codex login** for public OpenAI Realtime, select the model and voice, then
use **Save & Enable**. Setup stays available while Conversation is off. The active authentication
label identifies the saved choice even while another option is being edited.

The API key is stored in macOS Keychain and shared with OpenAI Transcription. Removing that key
disables the features using it; an independent Codex login and local models do not depend on it.
Codex uses a separate login owned by AI Camera, with refresh and sign-out controls. Sign-out turns
off Conversation when that login is active. See [authentication boundaries](codex-login.md).
Realtime access and subscription coverage depend on the account; the app does not promise that
Realtime audio usage is included in a subscription.

**Test Connection** checks the saved credential and selected model without acquiring the microphone
or generating a spoken response. **Talk** in the menu popup sends one utterance from the selected
microphone and plays the reply through the current speakers/headphones. Stop, silence, and bounded
deadlines end the session. The public WebSocket transport uses 24 kHz mono PCM; host conversion
preserves duration at the audio device's rate. Raw camera frames are not sent by Conversation.

## Transcription and translation

Transcription works independently of Conversation. Choose **OpenAI** or **Local Whisper**, select
a model and language, then save. The active-provider label reflects the saved route; editing the
picker does not switch providers until saved. OpenAI requires an API key. Whisper runs in process
and needs neither a credential nor an audio endpoint.

Download Whisper Base (148 MB) or Small (190 MB) explicitly. Downloads have progress, cancellation,
integrity verification, and removal. Removing the selected active model disables its transcription
lane. Setup remains available while the feature is off.

Enable **Translate** after downloading the local HY-MT2 model and enabling Transcription. Select
the source and target languages. Translation processes finalized text outside media callbacks.
Disabling Transcription also disables translation and transcript display. During Talk, the Realtime
transcript replaces batch ASR, avoiding duplicate audio uploads; independent ASR resumes with new
capture windows after the turn. See [embedded model details](local-models.md).

## Vision and gestures

Vision setup remains available while processing is off. Download/select a local detector, then
enable **Object detection**. YOLOv3 Tiny and RF-DETR Medium/Large run through cached serial Core ML
workers. An unready model cannot be enabled. Removing the active detector disables its stage before
removing the asset. **Gestures** uses local Apple Vision without a model download or endpoint.

The group switch turns all vision processing off; turning it on enables gestures. Individual
switches show which detector and gesture processing are active. Camera frames stay in app memory.
Each inference stage has one active request and one replaceable pending frame; stale results are
discarded. First model loading does not block the main actor or camera rendering.

## Tools and overlays

**Tools** allows bounded Realtime `render_overlay` and `clear_overlay` calls when a camera lane and
the renderer are available. Generated three.js scripts use the bundled transparent renderer and
expire automatically. The manual script editor is only present in Debug builds.

**Overlays** controls camera annotations: transcript, agent response, status, detection boxes, and
gesture labels. Turn on the parent switch to see the selected annotations in the camera image.
Local camera testing shows the processed result without activating a system component.

## Privacy and stored settings

**Privacy** describes the enabled local processing and external data routes. Local inference
processes media in memory. OpenAI receives only the data required by enabled OpenAI features.
Model downloads are explicit network operations; they do not upload camera or microphone data.
The app has no recording feature.

The underlying schema-versioned file is stored at:

```text
~/Library/Application Support/AI Camera/profile.json
```

It contains credential references, not secret values. Invalid or newer-schema files are preserved
and block automatic capture until repaired or reset through the app. The schema retains older
endpoint metadata for compatibility, but loading a configuration disables unsupported conversation
and remote video stages. Legacy transcription is migrated to the configured OpenAI service when
its shared key exists, otherwise it is disabled. No custom-endpoint controls are offered.

Remote requests remain subject to HTTPS, an exact host allowlist, and an endpoint-specific grant
for every data class sent (`rawAudio`, `rawFrame`, `transcript`, `sceneMetadata`, `promptText`).
Missing grants fail closed. HTTP uses an ephemeral session without cookies or a URL cache and
rejects redirects. The default network policy permits only loopback; enabling an OpenAI feature
saves its explicit route and grants. `persistMedia` must remain false.
