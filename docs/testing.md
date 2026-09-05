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
2. Confirm the Transcription card identifies OpenAI as its provider and offers no custom or embedded provider before those implementations are complete. Load a legacy loopback ASR profile with the shared OpenAI key present, relaunch, and confirm the active transcription endpoint migrates to canonical OpenAI without deleting the inert legacy endpoint definition.
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
confirm captions continue to update while Realtime speech plays. Embedded Whisper and dedicated
Codex login remain pending until their download/authentication and runtime paths are implemented.

### OpenAI Realtime Talk (host only)

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
