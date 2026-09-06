# Testing and diagnostics

## Safe validation

Run:

```sh
scripts/validate.sh
```

It performs:

1. Swift package unit tests;
2. Bash syntax checks plus non-executing AppleScript compilation and rendered privileged-shell syntax checks;
3. property-list and entitlement linting;
4. strict C syntax checks for the HAL plug-in;
5. an unsigned Xcode build of all four targets;
6. bundle-ID, resource, embed-path, and exported-factory checks; and
7. an in-process HAL factory/IO harness for the exact property graph, malformed inputs, clock behavior, actual input-reader demand, output-only exclusion, multi-client reads, sample-rate request coalescing, concurrent ring wrap, and reset behavior.

It does not request media permission, start inference services, install a driver, or submit a system-extension request.

For the slower HAL memory, undefined-behavior, numeric-cast, and concurrency checks, run:

```sh
scripts/validate-hal-sanitizers.sh
```

This builds temporary AddressSanitizer/UndefinedBehaviorSanitizer and ThreadSanitizer bundles, runs the same harness, and removes them. It does not install a driver. Leak detection is disabled because the macOS AddressSanitizer runtime does not support it.

## Unit coverage

The Swift tests cover pure-passthrough defaults, profile round trips and legacy migration, independent transcription validation, OpenAI transcription request construction, palm-relative rotation-independent gesture classification, wake-phrase matching and capture-time expiry, nominal frame-rate matching, loop-safe physical-input selection, local-test demand priority/cancellation, normalized microphone levels, the camera custom-property address and bounded snapshot codec, remote privacy grants, adapter normalization, WAV encoding/decoding, streamed-speech metadata, cumulative and buffer limits, redirect rejection, startup and active-body cancellation, per-modality stale results, result expiry, and latest-value mailbox replacement. App media orchestration, login registration, physical-device release, and live CoreMediaIO lifecycle remain signed, manual per-release checks. Signed results and the current automated boundary are recorded in [`VALIDATION.md`](../VALIDATION.md).

## Manual device acceptance

Use a signed app installed in `/Applications`.

### Local tests

1. Close every client of **AI Camera** and **AI Camera Microphone**. Confirm both test buttons are enabled.
2. Select **Test camera**. Confirm it becomes **Stop testing**, the resolved physical camera starts, and the processed image appears in the preview. Stop it and confirm capture and preview drain.
3. Select **Test microphone**. Confirm it becomes **Stop testing**, the resolved physical microphone starts, and the bounded input-level meter responds without opening a virtual input client. Stop it and confirm the meter resets to zero and capture drains.
4. Start both local tests together, stop either one, and confirm the other remains active without stale preview, meter, inference, or speech callbacks.
5. During either or both tests, open either virtual device in a client. Confirm both local tests cancel on the next demand observation and only externally requested lanes remain active. Confirm test starts are disabled until both client demands return to zero.
6. With Settings already open on another tab or section, select each inline source settings button. Confirm the General tab comes forward and scrolls to the matching Camera or Microphone controls.

### Camera

1. Install/approve the extension and launch the signed host. If an older extension is installed, use **Update** rather than removing it first.
2. Use a bounded native CoreMediaIO probe to resolve the virtual camera by UID. Confirm that global/main selector `aicd` exists, is read-only, returns 1–4096 raw `NSData` bytes, and decodes to a fresh idle count of zero. A property read itself must not start either stream.
3. With the host absent, use a bounded AVFoundation client to confirm animated placeholder frames, increasing timestamps, and changing in-memory hashes. Do not record frames.
4. With the host open but no camera client, confirm the physical camera is not held.
5. Open one bounded **AI Camera** source client. Confirm `aicd` changes `0 → 1`, physical capture starts automatically, frames become live at the negotiated format, and no manual Start action exists.
6. Close the client. Confirm `aicd` returns to zero, physical capture stops, and a later host-absent client still receives the placeholder.
7. Repeat start/stop and run two simultaneous clients. CoreMediaIO aggregates source-stream lifecycle, so confirm `aicd` stays at 1 until the final client closes and then returns to 0; it is not an exact client-cardinality counter.
8. Start only the authorized feeder sink and confirm camera demand remains zero. Exercise camera-only source use while the virtual microphone is idle and confirm no physical microphone acquisition.
9. In a controlled test, terminate or restart the extension while source demand is active. Confirm the host treats a missing device/property as idle or rejects the cached timestamp within two seconds, then resolves the new device object ID after restart.
10. Revoke camera permission while active. Confirm the host detects the authorization change and stops hardware capture without reopening the panel; the denied row must open Privacy settings instead of trying to re-prompt. Grant it in System Settings and confirm state refreshes when returning to the app.
11. Check extension logs for an authorized feeder, no binding revocation, and no start/stop or custom-property error.

### Audio

1. Install or update the driver and reopen Audio MIDI Setup. Confirm **AI Camera Microphone** has stereo input and output at 44.1 and 48 kHz.
2. With no reader, confirm the physical microphone is not held and virtual input is silent without a host writer.
3. Start only output IO on the virtual device. Confirm custom demand remains zero and physical microphone capture does not start.
4. Select **AI Camera Microphone** as an input in a bounded client. Confirm input reads make demand nonzero and physical microphone capture starts automatically.
5. Close the client. Confirm the demand entry clears/expires, capture stops, and readers receive silence after the writer stops.
6. Repeat with multiple readers and confirm capture remains active until the final reader closes. Exercise microphone-only use and confirm no physical camera acquisition.
7. Confirm microphone passthrough, complete-WAV speech, opt-in streaming PCM speech, and barge-in. With transcription off, confirm passthrough and energy-based barge-in still work but no ASR request is sent.
8. Revoke microphone permission while active and confirm capture stops. Test **Repair** when an installed bundle has not loaded.
9. Remove the driver and confirm that the device disappears after Core Audio reloads.

### Base mode and login

1. Remove or move aside the saved profile and let the app create a fresh one. Confirm System Default inputs, no video stages, conversation/transcription off, mirroring off, and overlays off.
2. With local endpoints observed or disabled, open each virtual device and confirm no inference or network request occurs. Confirm output contains the selected input without annotations, mirroring, or generated speech.
3. Change the system-default camera or microphone and confirm the next lane start resolves the new compatible hardware default without selecting either AI Camera virtual device as its own input.
4. Enable **Open AI Camera at login**, log out/in for the signed acceptance pass, and confirm the host becomes available without a visible main window. Disable the item and confirm its state remains off.
5. Replace the saved profile with a controlled invalid document. Confirm its file is preserved, both automatic lanes remain stopped, and Settings offers explicit import and reset choices. Restore a valid profile afterward.
6. Force one bounded transient camera and audio start failure while demand remains active. Confirm the panel reports attention required and **Retry** can recover without closing the client.
7. Quit the host explicitly and confirm documented host-absent behavior: animated camera placeholder and microphone silence. A client must not be claimed to relaunch the quit host.

### Conversation

1. Disable Conversation, enable Transcription, save an OpenAI API key, and confirm finalized speech appears as transcript without starting an agent turn. Confirm the key remains masked and is stored only in Keychain.
2. Confirm Transcription offers OpenAI and Local Whisper, with setup available while disabled. Load legacy remote ASR settings and confirm transcription is disabled while endpoint metadata and privacy grants remain unchanged, regardless of saved credentials. Choose OpenAI or Local Whisper explicitly to enable transcription. A saved Whisper configuration must remain local across relaunch and must have no active ASR endpoint ID.
3. Enable local translation and confirm it consumes the transcript while Conversation remains disabled.
4. Enable OpenAI Realtime while Transcription remains enabled. Confirm the Realtime transcript is displayed and no separate `/v1/audio/transcriptions` request is made during the active session.
5. Confirm a wake phrase and command in one final transcript starts one agent turn in the separate pipeline.
6. Speak the wake phrase alone, then a command in the next window. Confirm the capture-time window is honored even with ASR latency.
7. Confirm interim or unrelated ambient transcripts do not start a turn in wake mode.
8. Confirm a gesture starts a turn without arming or consuming the voice gate.
9. During streamed speech, barge in and confirm that the HTTP body and every queued audio buffer stop. Then start another turn and confirm no stale speech resumes.
10. Load a legacy profile without `activationMode` and confirm its intentional always-listening behavior before migrating it.

### Models

The current product target uses OpenAI and embedded local models. Kortexa services and compatible
Realtime endpoints are outside this acceptance pass. Existing imported metadata must remain inert
until a supported route is selected. Do not start remote services for this pass.

For built-in vision, download a model, confirm its readiness, and use a local camera test to verify
detections and gesture overlays. Test removal and cancellation without saving camera frames.
For translation, verify complete Unicode output and cancellation against synthetic text, then
confirm captions continue to update while Realtime speech plays. Test embedded Whisper with the
native and Settings procedures below. Dedicated Codex login requires separate authentication and
runtime acceptance.

### Settings migration without credential access

After `scripts/validate.sh`, run the actual settings controller against disposable synthetic files:

```sh
xcrun swiftc -parse-as-library -O \
  -F build/DerivedData-Validation/Build/Products/Debug -framework AICameraCore \
  -Xlinker -rpath -Xlinker "$PWD/build/DerivedData-Validation/Build/Products/Debug" \
  Sources/AICameraApp/ConfigurationController.swift scripts/validate-configuration-migration.swift \
  -o /tmp/aicamera-configuration-migration-validation
/tmp/aicamera-configuration-migration-validation
```

The harness covers startup, reload, hidden import, persistence, idempotence, explicit OpenAI setup,
Whisper relaunch, and preservation of invalid files. It links no credential resolver and never
opens media or network devices. The user's actual settings file is not used.

### OpenAI Realtime agent (host only)

Before listening acceptance, check conversion with a synthetic five-second tone. This uses the
production PCM conversion helper and opens no audio device or media file:

```sh
xcrun swiftc -parse-as-library -O Sources/AICameraApp/PCMBufferConverter.swift \
  scripts/validate-audio-conversion.swift -o /tmp/aicamera-audio-conversion-validation
/tmp/aicamera-audio-conversion-validation
```

The check requires exact duration (within one frame), continuous 997 Hz pitch/waveform, matching
stereo channels, and complete final draining at 44.1/48 kHz. It includes quarter-second Realtime
chunks, irregular short chunks, whole responses, and both planar-float and interleaved-integer capture
conversion. A successful tone check does not replace listening through the selected hardware.

Use the signed `/Applications/AI Camera.app` installed by `scripts/install-app.sh`. Do not use a
newly compiled credential-reading helper for each test: its changed identity can produce another
Keychain access prompt even while the login Keychain is unlocked. See `AGENTS.md`.

For unattended lifecycle checks, silence can verify the listening deadline, capture release,
retry, and Stop. A synthetic phrase played through a separately selected physical speaker is
only useful when the microphone actually detects it. A no-speech result does not establish a
speech-format or Realtime failure and cannot count as caption/tool acceptance. Leave system audio
defaults and volume unchanged, restore temporary in-app authentication selections, and stop both
local capture tests when finished. Do not enable credential prompts to force a standalone probe.

1. Select a physical microphone, enable Conversation, and save the existing model/voice and
   credential configuration. Choose speakers or headphones as the macOS output. Enabling
   Realtime alone must not activate its microphone egress.
2. Press **Start agent**, or hold a victory sign for about one second with Gestures enabled and
   the camera active. Confirm connecting then listening. The agent stays armed during silence;
   an actual utterance has a 30-second limit and a server response has a 120-second limit.
3. Say a short request. Input closes at VAD stop and remains closed while the reply plays.
   The final audio must drain before listening resumes in the same conversation. A follow-up
   must retain context. Do not record the utterance or output.
4. Use **Stop agent** during connection, listening, and playback. Confirm no late audio or tool
   side effects and that only agent-owned microphone demand is released. A live call or an
   independently started microphone test must continue using its own media demand.
5. Hold a fist to engage AI Camera's broader privacy mute: audio output stops, both caption
   tracks/script overlay clear, and the agent stops. Victory must not unmute it. Use **Unmute**
   explicitly before starting again. Repeated held poses must not retrigger; stale camera
   results must not start an agent after capture restarts.
6. Start the agent while a call already uses AI Camera. When the call selects AI Camera
   Microphone, replies must reach that output and the local speakers/headphones once, with no
   local microphone monitoring. Both reply outputs must finish before the next listening turn.
   Changing whether a call uses the virtual microphone stops the agent while the graph rebuilds;
   start it explicitly again after that routing change.
7. Keep Transcription and Translate enabled. Realtime owns ASR during its session; stopping it
   restores independent transcription with a fresh audio window. Caption translation must not
   delay speech. Enable Tools and request an overlay and a clear; each call executes once and
   the spoken continuation follows the tool results.
8. Test failed credentials, connection cancellation, and network/output loss. Confirm a visible
   error and usable retry. Stop or Mute must remain available. A stalled final playback is
   bounded to 125 seconds. Never include secrets or captured media in acceptance evidence.

Virtual-camera activation and device acceptance are a separate operator-authorized pass.

### Native local translation

Run `scripts/validate.sh` first to build the Debug frameworks. With the pinned HY-MT2 model already
downloaded through Settings, compile and run the synthetic native check from the repository root:

```sh
xcrun swiftc -parse-as-library -O \
  -F build/DerivedData-Validation/Build/Products/Debug \
  -framework AICameraCore -framework llama \
  -Xlinker -rpath -Xlinker "$PWD/build/DerivedData-Validation/Build/Products/Debug" \
  Sources/AICameraApp/BuiltinTranslationClient.swift \
  Sources/AICameraApp/BuiltinTranslationModelController.swift \
  scripts/validate-local-translation.swift \
  -o /tmp/aicamera-local-translation-validation
/tmp/aicamera-local-translation-validation
```

The harness checks late download completion after removal, new-download ownership, cached client
identity, synthetic Chinese/Japanese/Arabic output, cancellation and recovery, independent engine
teardown, cold/warm latency, and peak resident memory. It uses no microphone, camera, network, or
Keychain credential. Pass `--lifecycle-only` to omit inference and use disposable fixtures without
the model. The default automated suite separately verifies Unicode token boundaries and byte/text
limits without downloading or loading weights.

The model client stays cached across microphone/camera pipeline restarts. This reduces repeated
model setup at the cost of retaining the loaded model while the app runs. Removal releases the
cache; an existing pipeline retains its own reference until it stops.

### Native local Whisper

Run `scripts/validate.sh` first. Download Whisper Base and HY-MT2 through Settings. Fetch only the
pinned public upstream fixture (this procedure never captures microphone audio):

```sh
curl --fail --location \
  https://raw.githubusercontent.com/ggml-org/whisper.cpp/v1.8.6/samples/jfk.wav \
  -o /tmp/aicamera-whisper-jfk.wav
xcrun clang -std=c11 -Wall -Wextra -Werror \
  -F build/DerivedData-Validation/Build/Products/Debug \
  -c Sources/AICameraApp/WhisperBridge.c -o /tmp/aicamera-whisper-bridge.o
xcrun swiftc -parse-as-library -O \
  -F build/DerivedData-Validation/Build/Products/Debug \
  -framework AICameraCore -framework llama -framework whisper \
  -Xlinker -rpath -Xlinker "$PWD/build/DerivedData-Validation/Build/Products/Debug" \
  -import-objc-header Sources/AICameraApp/WhisperBridge.h \
  Sources/AICameraApp/BuiltinWhisperClient.swift \
  Sources/AICameraApp/BuiltinWhisperModelController.swift \
  Sources/AICameraApp/BuiltinTranslationClient.swift \
  Sources/AICameraApp/BuiltinTranslationModelController.swift \
  scripts/validate-local-whisper.swift /tmp/aicamera-whisper-bridge.o \
  -o /tmp/aicamera-local-whisper-validation
/tmp/aicamera-local-whisper-validation /tmp/aicamera-whisper-jfk.wav base
```

After downloading Small, repeat the last command with `small-q5_1`. On an M4 Pro/Max/Ultra or M5
Mac, download Large and repeat with `large-v3-q5_0`. Large uses the full Large v3 architecture with
Q5 weights (1,081,140,203 bytes), not Turbo. All artifacts have pinned revisions, lengths, and SHA-256.
The harness checks the fixture's
SHA-256 before use, then verifies English/auto recognition, silence, cancellation, recovery, cached
client identity, coexistence with translation, latency, and peak resident memory. It never reads
Keychain or downloads a model implicitly. The automated suite covers WAV bounds, old profile
defaults, local endpoint exclusion, verified download success/failure/cancellation, and partial-file
cleanup without native weights.

In the signed installed app, also verify:

1. With Transcription off, choose Local Whisper. The OpenAI key controls disappear. Download progress,
   Cancel, retry, readiness, size, and Remove must match the selected model. Cancelling or removing
   must not let an old completion mark the model ready later.
2. Save Base, change a draft, switch Settings tabs and return. The draft persists and the active
   provider status remains truthful. Save Small and confirm the selected model persists on relaunch.
3. In Privacy, confirm Whisper is local. Its saved profile has no active ASR endpoint ID. OpenAI
   credentials and inert endpoint definitions survive switching providers.
4. With Conversation off, run a local microphone test and speak. Confirm local transcripts and optional
   translations appear without an ASR network request. Stop and verify hardware release without recording.
5. Remove a model downloaded for this test, confirm the active lane is disabled, then download and
   enable it again. Do not remove pre-existing user weights solely for acceptance.

### Local detector runtime

The native detector check uses the three already-downloaded model artifacts and two public photos.
It validates the exact fixture hashes before inference. It neither opens capture nor changes model
weights; removal uses an empty disposable directory.

```sh
curl -fL --max-filesize 5242880 \
  https://raw.githubusercontent.com/pjreddie/darknet/master/data/dog.jpg \
  -o /tmp/aicamera-vision-darknet-dog.jpg
curl -fL --max-filesize 5242880 https://media.roboflow.com/dog.jpg \
  -o /tmp/aicamera-vision-dog.jpg
xcrun swiftc -parse-as-library -O \
  -F build/DerivedData-Validation/Build/Products/Debug -framework AICameraCore \
  -Xlinker -rpath -Xlinker "$PWD/build/DerivedData-Validation/Build/Products/Debug" \
  Sources/AICameraApp/BuiltinVisionModelController.swift scripts/validate-local-vision.swift \
  -o /tmp/aicamera-local-vision-validation
/tmp/aicamera-local-vision-validation /tmp/aicamera-vision-darknet-dog.jpg /tmp/aicamera-vision-dog.jpg
```

The check covers object labels, normalized finite bounds, cached client reuse, first/warm inference,
main-actor responsiveness, cancellation/recovery, and cache removal. YOLO Tiny's close-up misses are
reported separately from the shared standard-fixture checks. These photos are narrow correctness
fixtures, not an accuracy benchmark. Follow with a local camera test to check live overlays and
gestures, then stop the test and verify that capture returns to idle.

### Codex login

After `scripts/validate.sh`, the following native check uses the installed CLI with a disposable,
empty Codex home. It checks initialization, device-code response validation, cancellation notification,
empty-account logout, helper restart, and overlapping startup/shutdown. It neither opens a browser nor completes a login, reads
desktop credentials, or requests inference:

```sh
xcrun swiftc -parse-as-library -O \
  -F build/DerivedData-Validation/Build/Products/Debug -framework AICameraCore \
  -Xlinker -rpath -Xlinker "$PWD/build/DerivedData-Validation/Build/Products/Debug" \
  Sources/AICameraApp/CodexAppServer.swift scripts/validate-codex-auth.swift \
  -o /tmp/aicamera-codex-auth-validation
/tmp/aicamera-codex-auth-validation
```

In the signed installed app:

1. With Conversation off, choose Codex login. Verify its setup is accessible, account status loads,
   and Save cannot enable a login that is incomplete. Changing the draft must not change the active
   authentication choice or erase the saved OpenAI API key.
2. Start a login, cancel it, and confirm a later completion cannot mark it signed in. Start again
   and let the user complete the official browser ceremony. Verify the account appears and no token
   value is exposed in the UI or logs.
3. Use Test Connection and confirm no capture starts. Cancel and change the selected model during
   a test; a late result must not update the new draft. Save Codex, perform a bounded Realtime turn,
   and verify actual speech separately from account sign-in. Verify the Privacy statement describes
   the selected credential source accurately.
4. Refresh and run another turn. Sign out; verify Conversation stops, the dedicated account clears,
   and the normal desktop Codex session remains available. Switch explicitly to the saved API key
   and confirm it still works. Do not claim subscription billing from a successful socket handshake.

### Product identity and Settings lifecycle

1. Confirm Finder, `/Applications`, Dock, App Switcher, Login Items, and the popup header use the same full-color production icon.
2. Confirm the menu-bar item uses the matching monochrome lens-and-sparkle template at standard and Retina scale in light and dark menu bars.
3. With only the menu-bar popup open, confirm AI Camera is absent from the Dock and App Switcher. Open Settings and confirm it appears in both. Close Settings and confirm it returns to accessory-only behavior.
4. Open Settings and press **Command-Q**. Confirm Settings closes, AI Camera remains active in the menu bar, and a compact reminder appears for three seconds with a working **Quit** button. Confirm the menu-bar control center's deliberate **Quit** action still terminates immediately.

## Logs and errors

Pipeline and lifecycle errors appear in the menu-bar panel. CoreMediaIO extension diagnostics are available in Console under subsystem `ai.kortexa.aicamera.camera-extension`. Driver load failures are reported by `coreaudiod`.

Useful non-destructive checks:

```sh
systemextensionsctl list | grep ai.kortexa.aicamera
system_profiler SPAudioDataType | grep -A8 'AI Camera Microphone'
plutil -p '/Applications/AI Camera.app/Contents/Info.plist'
```

Do not use broad process-kill or system-directory cleanup commands for diagnosis.

## Settings acceptance for the OpenAI/local product

Use the signed installed host. General, AI, and Privacy are the only Settings tabs. Verify:

- Conversation and Transcription drafts survive tab switches and do not change the active route
  until saved. Setup remains available with either feature off.
- Vision setup/downloads remain visible with the group off. Group Off disables its stages;
  individual controls show actual state after re-enabling. No custom endpoint or transfer UI appears.
- Privacy matches enabled local models and the selected saved OpenAI authentication route.
- Release camera testing shows the preview without the manual script editor. Stop returns to idle.

Settings import/export is intentionally hidden; `ProfileTransfer` tests cover only the retained
serialization capability. They do not establish a user-facing transfer flow.

## Synthetic overlay runtime and public tools

After `scripts/validate.sh`, compile the actual host renderer against the freshly built framework:

```sh
xcrun swiftc -parse-as-library -O \
  -F build/DerivedData-Validation/Build/Products/Debug -framework AICameraCore \
  -Xlinker -rpath -Xlinker "$PWD/build/DerivedData-Validation/Build/Products/Debug" \
  Sources/AICameraApp/OverlayScriptRenderer.swift scripts/validate-overlay-runtime.swift \
  -o /tmp/aicamera-overlay-runtime-validation
/tmp/aicamera-overlay-runtime-validation "$PWD/Resources/Overlay/overlay.html"
```

The runtime check uses generated geometry, validates actual pixel colors, and saves no images.
It needs the macOS GUI session for WebKit, but no camera, microphone, network, or credential.

The optional public tool check uses synthetic instructions and receives PCM without playing or
saving it. It returns a tool result, requests continuation only after the first response completes,
and then requests Clear. It uses an already-provided `OPENAI_API_KEY` in memory when available;
otherwise its single Keychain read forbids interaction using both the legacy process-level switch
and the modern authentication context. The modern context alone did not suppress a legacy item ACL
dialog on this Mac; the probe uses the deprecated legacy guards deliberately until those items
move to a backend that honors the modern context. These controls change no item ACL or saved setting. `codex` reads only AI Camera's separate
login and does not refresh or sign in. An inaccessible/expired credential fails explicitly.

```sh
xcrun swiftc -parse-as-library -O \
  -F build/DerivedData-Validation/Build/Products/Debug -framework AICameraCore \
  -Xlinker -rpath -Xlinker "$PWD/build/DerivedData-Validation/Build/Products/Debug" \
  Sources/AICameraApp/OverlayScriptRenderer.swift \
  Sources/AICameraApp/RealtimeConversationSession.swift scripts/validate-realtime-tools.swift \
  -o /tmp/aicamera-realtime-tool-validation
/tmp/aicamera-realtime-tool-validation "$PWD/Resources/Overlay/overlay.html" api-key
# Optional, only after completing the separate login in the installed app:
/tmp/aicamera-realtime-tool-validation "$PWD/Resources/Overlay/overlay.html" codex
```

This proves synthetic tool-to-pixel behavior only when it passes. Live microphone invocation,
translated captions, and another participant's camera view remain distinct acceptance checks.

## Native Realtime caption scheduling

After full validation, compile the coordinator with its actual capture type dependencies and the
local translation implementation. The harness never constructs the capture or driver controllers:

```sh
xcrun swiftc -parse-as-library -O \
  -F build/DerivedData-Validation/Build/Products/Debug -framework AICameraCore -framework llama \
  -Xlinker -rpath -Xlinker "$PWD/build/DerivedData-Validation/Build/Products/Debug" \
  Sources/AICameraApp/PipelineCoordinator.swift \
  Sources/AICameraApp/AudioPipelineController.swift Sources/AICameraApp/PCMBufferConverter.swift \
  Sources/AICameraApp/SpeechOutputMonitor.swift \
  Sources/AICameraApp/DeviceDiscovery.swift Sources/AICameraApp/AudioDriverManager.swift \
  Sources/AICameraShared/VirtualCameraConstants.swift Sources/AICameraShared/MediaDemandState.swift \
  Sources/AICameraApp/BuiltinTranslationClient.swift \
  Sources/AICameraApp/BuiltinTranslationModelController.swift scripts/validate-realtime-captions.swift \
  -o /tmp/aicamera-realtime-caption-validation
/tmp/aicamera-realtime-caption-validation
```

Use `--controlled-only` to skip real HY-MT2 inference. Controlled completions intentionally ignore
cancellation to verify late-result rejection, one active/latest pending translation, partial/final
handling, new-turn isolation, and Stop. It also switches the live target from Chinese to Spanish
while an older request is pending, verifies the next request's target and stale-result rejection,
then turns translation off while retaining original captions. These controlled checks run in
the full validation script. Talk-only cancellation is checked with the coordinator still
active: neither the active translation nor its pending replacement may publish. Normal completion
must still publish its final translation, a later turn must work, and canceled event consumers must
not create caption work. All four combinations of Show transcript and Show agent
response are checked, along with interleaved sources and independent translated finals. The real-model
pass publishes synthetic English sentences as Chinese user and AI captions through the coordinator. No media, network, or credentials are accessed.

### Camera publication recovery and Whisper tier acceptance

- Confirm Base, Small, and Large each show a distinct description on an M4 Pro/Max/Ultra or M5 Mac.
  Earlier chips, base M4, and unknown hardware offer Base and Small only. Unsupported saved Large
  choices cannot download or start an inference client; Settings offers Base as an unsaved draft.
- Whisper and translation use the same Local model row layout: named green check and trash when
  ready, Download when absent, progress and Cancel during a download, and retry with error text.
  Removing the selected active Whisper model must still disable transcription and translation.
- An enabled extension with no camera must show all of its recovery message in the compact popup.
  A reboot instruction is reserved for an explicit pending-reboot state. In General Settings,
  Open Camera Extensions leads to the system-managed Media Extensions controls.
- For an enabled camera absent from both the app and QuickTime, inspect registration and launchd
  logs before changing system state. A replacement can be accepted by SystemExtensions while its
  CoreMediaIO job fails to start during removal of the old job. Approval and device publication
  are separate checks. With operator authorization, use the normal extension update or system
  off/on controls, then verify publication in a fresh camera client. Never delete OS-managed
  extension directories or automatically reboot as part of validation.

### Model selector and caption presentation acceptance

- Whisper uses a Size segmented selector with Base/Small and Large on eligible hardware.
  Vision uses the same Size → description/download size → Model status/actions layout with
  Tiny/Medium/Large. Its description names YOLOv3 or RF-DETR and explains the tier benefit.
- Provider text says Whisper. All local model status rows say Model. Descriptions include
  download size in GB; selected names and removal/download behavior remain unchanged.
- Show gesture labels appears once, in Overlays. Gestures remains a processing toggle under
  Vision & Gestures. Object detection and Show detection boxes remain independently controllable.
- In a camera preview, confirm the upper-left label says only AI Camera. Translated/original
  transcript captions occupy the bottom center with an inset from the edge, including long
  captions at smaller frame sizes. Existing single-line truncation remains unchanged. AI-response placement remains separate.


## AI Camera privacy mute

With Gestures enabled and the camera active, hold a closed fist for about one second. The menu
must show **Microphone muted · captions hidden**. The physical microphone capture lane stops,
AI Camera Microphone output is silenced, Realtime stops, and both speaker captions and the current
script overlay clear. Camera output and gesture observations continue. Repeated held fists must
not toggle the state. Use **Unmute** in the menu or the Microphone settings switch to resume;
restarting the host, changing configuration, or a new client must not unmute it.

Select **AI Camera Microphone** in the receiving app to protect its call audio. Zoom, Teams, Meet,
Discord, Twitch, and X Spaces can each select another source; AI Camera cannot mute a physical
microphone used directly by another app. Their internal mute switches are not detected by this
implementation. Audio/video already delivered to another app cannot be retracted.

Run the deterministic native coordinator harness after `scripts/validate.sh`:

```sh
xcrun swiftc -parse-as-library -O \
  -F build/DerivedData-Validation/Build/Products/Debug -framework AICameraCore \
  -Xlinker -rpath -Xlinker "$PWD/build/DerivedData-Validation/Build/Products/Debug" \
  Sources/AICameraApp/PipelineCoordinator.swift \
  Sources/AICameraApp/AudioPipelineController.swift Sources/AICameraApp/PCMBufferConverter.swift \
  Sources/AICameraApp/SpeechOutputMonitor.swift \
  Sources/AICameraApp/DeviceDiscovery.swift Sources/AICameraApp/AudioDriverManager.swift \
  Sources/AICameraShared/VirtualCameraConstants.swift Sources/AICameraShared/MediaDemandState.swift \
  scripts/validate-caption-privacy.swift -o /tmp/aicamera-caption-privacy-validation
/tmp/aicamera-caption-privacy-validation
```

Fake model completions intentionally ignore cancellation. Tests cover visible/pending speech,
muted admission, translation and transcription finishing after mute/unmute, fresh-caption recovery,
and the real coordinator's held-fist control callback. No capture, credentials, model weights,
network, or component installation is used. Core tests also cover callback-generation filtering,
late scene writes, restored mute, confidence/dwell, direct victory-to-fist transition, conflicts,
neutral rearming, and stale/out-of-order frames. A live call audio/gesture check remains manual;
these synthetic checks do not claim acceptance inside every receiving app.


## Native model shutdown

Quit must stop media admission and cancel model work before cached Whisper/HY-MT2 contexts are
released. The app defers AppKit termination until that release completes; late requests to retained
clients must fail with cancellation. A new process creates fresh clients normally. Saved privacy
mute preferences do not change just because the app quits.

The native harness uses the production termination delegate and model controllers, retaining their
owners through normal process exit. It loads the pinned public JFK fixture above and synthetic
translation text. It never starts camera/microphone capture, accesses credentials, or installs
components. Build the Whisper bridge with the command in the local Whisper section, then:

```sh
xcrun swiftc -parse-as-library -O \
  -F build/DerivedData-Validation/Build/Products/Debug \
  -framework AICameraCore -framework llama -framework whisper \
  -Xlinker -rpath -Xlinker "$PWD/build/DerivedData-Validation/Build/Products/Debug" \
  -import-objc-header Sources/AICameraApp/WhisperBridge.h \
  Sources/AICameraApp/AppLifecycleCoordinator.swift \
  Sources/AICameraApp/BuiltinWhisperClient.swift Sources/AICameraApp/BuiltinWhisperModelController.swift \
  Sources/AICameraApp/BuiltinTranslationClient.swift Sources/AICameraApp/BuiltinTranslationModelController.swift \
  scripts/validate-model-shutdown.swift /tmp/aicamera-whisper-bridge.o \
  -o /tmp/aicamera-model-shutdown-validation
/tmp/aicamera-model-shutdown-validation /tmp/aicamera-whisper-jfk.wav
/tmp/aicamera-model-shutdown-validation /tmp/aicamera-whisper-jfk.wav --during-load
```

Both processes must print `SHUTDOWN PASSED` and exit normally with code 0. The second quits while
initial loading/inference is in progress; the first warms both engines before cancelling new work.
Neither accepts a forced kill as success. An installed-host Quit/relaunch check separately verifies
SwiftUI's delegate wiring. UI Quit is posted as an AppKit event so the calling Swift task can return
before the [termination modal loop](https://developer.apple.com/documentation/appkit/nsapplication/terminatereply/terminatelater)
waits for asynchronous cleanup.


## Synthetic Realtime activation and reply output

The activation fixture also covers pausing agent input during listening and during a response,
discarding an unfinished utterance, rejecting late input/VAD events, preserving the current reply
and tool continuation, and resuming without admitting samples captured before the new turn.
`AgentListeningPolicyTests` covers one-question behavior and migration of existing configurations.

For manual listening acceptance, start an agent question while another app uses AI Camera
Microphone. Pause agent input during the answer: the answer and call microphone must continue.
After it finishes, speak to the other person; the agent must remain paused. Press Control–Option–Space
or Ask again and ask a second question. Repeat in One question at a time mode, including a pause
mid-question (the incomplete input is discarded), quick pause/resume changes, and the existing full
privacy Mute. The source-release test does not substitute for this live acceptance.

After full validation, exercise the production WebSocket session with an in-memory socket. The
fixture preserves the public session URL validation and supplies synthetic credentials to the fake
socket only; it makes no network or Keychain requests:

```sh
xcrun swiftc -parse-as-library -O \
  -F build/DerivedData-Validation/Build/Products/Debug -framework AICameraCore \
  -Xlinker -rpath -Xlinker "$PWD/build/DerivedData-Validation/Build/Products/Debug" \
  Sources/AICameraApp/RealtimeConversationSession.swift scripts/validate-realtime-activation.swift \
  -o /tmp/aicamera-realtime-activation-validation
/tmp/aicamera-realtime-activation-validation
xcrun swiftc -parse-as-library -O Sources/AICameraApp/SpeechOutputMonitor.swift \
  scripts/validate-speech-monitor.swift -o /tmp/aicamera-speech-monitor-validation
/tmp/aicamera-speech-monitor-validation
```

Demand tests cover call/agent ownership, privacy mute with video retained, required authorization,
and explicit restart on microphone routing changes. Session checks cover closed/unarmed input,
timestamps before each arm, multiple turns without
reconnecting, input closure during response/playback, explicit rearming, tool continuation,
duplicate/late audio and tool events, and cancellation while connecting. Core tests cover continuous
idle, fixed utterance/response limits, playback gating, and closed-session denial. The monitor check
renders generated PCM offline at 44.1/48 kHz for gain and mute/reset silence, then sends 100 ms of
zeros to the current physical output to verify its real playback-completion callback. It does not
capture input, record media, alter device defaults, or require a listener.

The wire lifecycle follows [OpenAI's WebSocket audio guidance](https://developers.openai.com/api/docs/guides/realtime-conversations#handling-audio-with-websockets).
These checks do not replace live provider/call acceptance of a gesture-started conversation.


## Agent status in the outgoing camera

After the full validation, run the synthetic compositor harness:

```sh
xcrun swiftc -parse-as-library -O \
  -F build/DerivedData-Validation/Build/Products/Debug -framework AICameraCore \
  -Xlinker -rpath -Xlinker "$PWD/build/DerivedData-Validation/Build/Products/Debug" \
  Sources/AICameraApp/OverlayRenderer.swift Sources/AICameraApp/AgentStatusRenderer.swift \
  Sources/AICameraApp/AgentCardRenderer.swift \
  scripts/validate-agent-overlay.swift -o /tmp/aicamera-agent-overlay-validation
/tmp/aicamera-agent-overlay-validation
```

It checks all agent states in actual composited pixel buffers, the clear top margin, the status
toggle, and deterministic animated geometry. Its PNGs contain only generated solid backgrounds.
The caption-privacy harness also routes synthetic victory → fist through the real coordinator with
Realtime enabled, checking exactly one start and mute without a popup, capture, or credentials.

For manual acceptance, use QuickTime New Movie Recording with AI Camera selected. Keep the floating
title bar visible; confirm both top overlays remain readable. Hold victory until the progress ring
fills, then expect Connecting → Listening. Ask a question and check Thinking → Speaking → Listening.
Use the menu error when the orb says Agent unavailable. Hold a fist and verify Muted, cleared
captions, and silenced AI Camera Microphone. Explicitly Unmute in the menu before the next start.
Do not press QuickTime Record or save captured media for this check.


## Independent camera-extension versions

`scripts/validate.sh` executes `validate-install-versions.py` against the rendered protected installer.
Twenty temporary-plist cases exercise the actual source, staged, and final metadata guards: different
valid host/component versions, same-version compatibility, invalid/missing versions, altered staged
or final versions, and incorrect identities. Only bounded read/check fragments execute; no signing,
privileged transaction, process shutdown, app replacement, or system-component request occurs.
The check also requires explicit camera-extension build and marketing settings in `project.yml`.

For a signed host-only update, record the enabled camera extension and its version before installing.
Verify source and installed host signatures/versions and the protected host-generation marker.
Separately verify the embedded extension version, signature, and CodeDirectory hash. The host version
may advance while the camera extension stays unchanged. The enabled extension registration must
remain unchanged and the menu must show Camera Ready, without an extension Update action. Confirm
that an independent client can still select the virtual camera. Do not activate/deactivate a component
as part of this check. A real component change still requires a component build-version increment
and separate operator-approved replacement acceptance.

## Quick toolbar and standalone windows

Use the signed installed host; leave the camera extension and HAL driver unchanged.

1. Launch to the menu bar with no standalone window. Confirm the compact popup has five quick
   controls, a dot with a descriptive tooltip/VoiceOver label, and Preview left / About + Quit right.
2. Open Preview, resize it, then open Settings and About. Repeat the footer actions and confirm
   one window per kind. Close them in different orders: the Dock icon must remain until the last
   standalone window closes. Reopen each kind and repeat. Command-Q closes a window, not the host; its three-second reminder uses the canonical app icon.
3. Opening Preview must not acquire either input. Start camera/microphone tests explicitly. Closing
   Preview must release those test inputs. When QuickTime uses the virtual devices, Preview shows
   the same processed video and disables local tests; closing Preview must leave the call running.
4. During a synthetic caption/gesture sequence, toggle Transcribe/Translate/Gestures and confirm
   configuration stays enabled. Translate alone must still work; both caption switches off must stop
   independent ASR. Gesture Off/On must require a new full gesture hold. Object detection continues.
5. With another app focused and the popup closed, Control–Option–M mutes/unmutes AI Camera and
   Control–Option–A starts/stops the agent. Holding a shortcut must toggle once. Mute clears all
   captions and agent audio; unmuting never automatically starts a conversation.
6. Verify readiness-dot states: green ready/idle, red active capture, yellow when idle setup needs
   attention. Check status details remain available through hover and accessibility.

`scripts/validate-quick-controls.swift` exercises the real coordinator with cancellation-insensitive
synthetic ASR/translation clients; `scripts/validate-global-shortcuts.swift` exercises native hotkey
registration and synthetic Carbon events without capturing keyboard input. Unit tests cover runtime
caption/gesture generations, dependency policy, and stale scene writes across actor hops.

## Notes and information cards

The full validation runs `validate-agent-tools.swift` with a temporary notebook and generated
solid-color frames. It checks note-controller state, every card style/position at 1280×720 and
640×480, cached pixels, expiry, clearing, and space reserved for answer/translation captions.
It does not start AppModel, a camera, microphone, network session, or credential read. To retain
synthetic PNGs for visual review after building the validation framework:

```sh
xcrun swiftc -parse-as-library -O \
  -F build/DerivedData-Validation/Build/Products/Debug -framework AICameraCore \
  -Xlinker -rpath -Xlinker "$PWD/build/DerivedData-Validation/Build/Products/Debug" \
  Sources/AICameraApp/AgentNotesController.swift Sources/AICameraApp/OverlayRenderer.swift \
  Sources/AICameraApp/AgentCardRenderer.swift Sources/AICameraApp/AgentStatusRenderer.swift \
  scripts/validate-agent-tools.swift -o /tmp/aicamera-agent-tools-validation
/tmp/aicamera-agent-tools-validation /tmp/aicamera-synthetic-cards
```

Core tests cover persistent note identity, corrupt-file preservation, capacity and Unicode limits,
strict tool schemas/arguments, asynchronous function results arriving after response completion,
duplicate calls, per-question round/call limits, silent-wait completion, and card lifetime.

For manual acceptance, use an explicitly disposable note. Save it by voice, find it in Notes,
edit it, and ask the agent to find it again. Saving must not publish a card. Ask separately to show
its contents, then clear the card; the saved note must remain. Verify expiry, Tools off, and privacy
mute in the actual virtual camera. In one-question mode, ask for a note or card, keep talking to
another person, and confirm the agent waits for Ask again. Ask it to go to sleep and confirm the
call's microphone continues. Run synthetic checks first; live speech/model judgment still needs
its own acceptance and must not be inferred from these fixtures.

For an optional public-provider contract check, compile the existing Realtime tool probe with the
production session and script renderer, then select `assistant` mode. Use the model already
configured in the app; the example uses `gpt-realtime`:

```sh
xcrun swiftc -parse-as-library -O \
  -F build/DerivedData-Validation/Build/Products/Debug -framework AICameraCore \
  -Xlinker -rpath -Xlinker "$PWD/build/DerivedData-Validation/Build/Products/Debug" \
  Sources/AICameraApp/RealtimeConversationSession.swift Sources/AICameraApp/OverlayScriptRenderer.swift \
  scripts/validate-realtime-tools.swift -o /tmp/aicamera-realtime-tools-validation
/tmp/aicamera-realtime-tools-validation Resources/Overlay/overlay.html codex gpt-realtime assistant
```

This 45-second bounded probe advertises the production tool catalog/instructions, requests an
automatically chosen synthetic note/card sequence, and checks the wait/sleep schemas explicitly.
It creates only a temporary synthetic notebook, discards received audio, captures no media, and
never plays a response. Both `codex` and `api-key` reads forbid Keychain interaction. An unavailable
credential stops the check; do not retry with UI enabled during unattended work. This verifies a
provider contract, not real-world addressed-speech recognition or installed-app behavior.

The native card fixture also checks presentation layout. Synthetic camera quadrants are composited
above a generated background in every corner, with mirroring both off and on, at 1280×720 and
640×480. It compares corresponding camera pixels to catch vertical flips, stretching, or crop
errors. Missing graphics and expired layout with still-fresh scene pixels must both reproduce the
full-camera baseline immediately. Core tests cover geometry limits, caption margins, strict layout
arguments, lifetime, and independent card clearing.
The same fixture verifies that object/gesture annotations stay within the inset and that a card
requested on the camera's side moves away without changing any camera pixels.

For installed acceptance, ask the agent to draw a scene, then put the camera in the lower-right
corner. Verify it in an independent virtual-camera client, keep speaking to a friend with agent
input paused, and use Reset view. Confirm native captions and call audio continue. Repeat Clear,
expiry, and Tools off. This check is distinct from the synthetic compositor fixture and requires
an installed candidate; no system-extension update should be needed for the host-only change.
