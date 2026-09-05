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
2. Confirm Transcription offers OpenAI and Local Whisper, with setup available while disabled. Load a legacy remote ASR profile with the shared OpenAI key present and confirm it migrates to canonical OpenAI without deleting inert endpoint metadata. A saved Whisper profile must remain local across relaunch and must have no active ASR endpoint ID.
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

### OpenAI Realtime Talk (host only)

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

1. With both virtual devices idle, select a physical microphone in Settings, enable Conversation,
   select OpenAI, and save the model/voice using the existing masked API key. Choose speakers or
   headphones as the macOS output. No virtual-device installation or activation is required.
2. Press **Talk — one utterance**. Confirm the input is the selected microphone and the state
   passes from connecting to listening. Stay silent: after ten seconds of listening, the turn
   must report no speech, restore Talk, and release the microphone if Talk started its test.
3. Start another turn and say a short request. Confirm the transcript accumulates, listening
   closes after the utterance, the reply is audible once with no microphone monitoring, and its
   full final audio plays before Talk returns to idle. Do not record the utterance or output.
4. Press Stop during connection, listening, and playback. Confirm prompt release and no late
   audio, transcript, or tool side effects. Start another turn to verify recovery.
5. Start **Test microphone** before Talk. Stop or finish Talk and confirm the existing microphone
   test stays active. Then stop that test explicitly and confirm capture drains.
6. Leave independent transcription and Translate enabled during Talk. Confirm no separate batch
   ASR request starts during the turn or later uploads its partial audio window. Final captions
   may translate without delaying speech, and stale translations must not reach a later turn.
7. Enable Tools and start a local camera test. Request an overlay, then clear it. Confirm each
   tool executes once, the continuation waits for all results, and the spoken result follows.
   Stop the camera test and verify a later Talk cannot claim it rendered an overlay.
8. Test a rejected model/credential and network loss. Confirm a bounded error, capture release,
   and a usable retry. Never include secrets or captured media in logs or acceptance evidence.

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

After downloading Small, repeat the last command with `small-q5_1`. The harness checks the fixture's
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
