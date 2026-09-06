# Settings

A new installation uses pure passthrough. AI, transcription, overlays, and mirroring are off.
Configure the app in **Settings → General**, **AI**, and **Privacy**. Changes are validated and
saved atomically. Feature toggles apply immediately; Conversation and Transcription provider,
authentication, model, and language drafts apply only when saved. Changing an active configuration
restarts its processing with new immutable settings; media callbacks never wait for this work.

Settings import/export and custom endpoints are hidden for this product phase.

## Quick controls and windows

The menu toolbar pauses **Transcribe**, **Translate**, and **Gestures** without changing their
saved enable switches, models, or languages. These quick states are remembered across launches.
A feature must first be enabled in Settings. With Translate on, translation uses transcription
even if original-language captions are paused; translated captions take precedence. With both
caption controls off, independent ASR stops. Pausing gestures disables recognition, labels, and
gesture actions without stopping a running agent or camera feed.

**Agent** starts or stops the live conversation; it always starts off after launch. **Mute**
silences AI Camera Microphone, stops the agent, and hides all speech captions. Unmute is explicit
and never restarts the agent. Mute protects a call's audio when it uses AI Camera Microphone.
Global **Control–Option–A** toggles the agent and **Control–Option–M** toggles mute while other
apps have focus. These use registered hotkeys without requesting keyboard-monitoring permission.
If registration fails, the menu reports the unavailable shortcut; the toolbar still works.

The cog at the top right opens Settings; the footer uses plain text actions. The header dot is yellow when setup needs attention, green when ready, and red while the camera
or microphone is active. Hover or VoiceOver gives its meaning; device rows retain setup details.

**Preview** in the footer opens one reusable, resizable window with a larger processed camera
view flush with the top and side edges, with local test buttons below it. Opening it does not start capture. Closing it ends local tests;
external call demand and separately activated agent demand continue. **About** opens a small
product/version window. Settings, Preview, and About keep the Dock icon visible until the last
standalone window closes. Command-Q closes a standalone window; Quit in the menu stops the app.

## General

Choose the camera and microphone, camera size and frame rate, mirroring, microphone gain, and
launch-at-login behavior. Only recognized direct local hardware is eligible. If System Default
resolves to an excluded input, the app warns and selects an eligible device. Device identifiers
are specific to each Mac.

Virtual-device installation and maintenance are separate from local testing. They can require
macOS approval. The host starts physical capture only for matching virtual-device demand or an
explicit local test; activating the agent can independently acquire the selected microphone.

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
or generating a spoken response. **Agent** in the menu toolbar starts a conversation using the selected
microphone and plays replies through speakers/headphones and AI Camera Microphone when a call
uses it. The session stays active between replies until stopped or muted. The public WebSocket transport uses 24 kHz mono PCM; host conversion
preserves duration at the audio device's rate. Raw camera frames are not sent by Conversation.

## Transcription and translation

Transcription works independently of Conversation. Choose **OpenAI** or **Whisper**, select
a model and language, then save. The active-provider label reflects the saved route; editing the
picker does not switch providers until saved. OpenAI requires an API key. Whisper runs in process
and needs neither a credential nor an audio endpoint.

Choose the Base, Small, or hardware-supported Large size and explicitly download its model.
Each size describes its accuracy/speed tradeoff and download size. Downloads have progress, cancellation,
integrity verification, and removal. Removing the selected active model disables its transcription
lane. Setup remains available while the feature is off.

Enable **Translate** after downloading the local HY-MT2 model and enabling Transcription. Select
the source and target languages. Translation processes finalized text outside media callbacks.
Disabling Transcription in Settings also disables translation and transcript display. The quick
Transcribe control is separate and leaves Translate available. During an agent conversation, the Realtime
transcript replaces batch ASR, avoiding duplicate audio uploads; independent ASR resumes with new
capture windows after the conversation stops. See [embedded model details](local-models.md).

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
endpoint metadata for compatibility, but loading a configuration disables unsupported conversation,
transcription, and remote video stages. Migration does not read credentials, select a different
service, or add privacy grants. Select OpenAI or Local Whisper explicitly in AI before enabling
transcription again. Supported OpenAI routes, local Whisper, and independent Realtime translation
remain unchanged. No custom-endpoint controls are offered.

Remote requests remain subject to HTTPS, an exact host allowlist, and an endpoint-specific grant
for every data class sent (`rawAudio`, `rawFrame`, `transcript`, `sceneMetadata`, `promptText`).
Missing grants fail closed. HTTP uses an ephemeral session without cookies or a URL cache and
rejects redirects. The default network policy permits only loopback; enabling an OpenAI feature
saves its explicit route and grants. `persistMedia` must remain false.
