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

The 72 Swift tests cover pure-passthrough defaults, profile round trips and legacy migration, wake-phrase matching and capture-time expiry, nominal frame-rate matching, loop-safe physical-input selection, local-test demand priority/cancellation, normalized microphone levels, the camera custom-property address and bounded snapshot codec, remote privacy grants, adapter normalization, WAV encoding/decoding, streamed-speech metadata, cumulative and buffer limits, redirect rejection, startup and active-body cancellation, per-modality stale results, result expiry, and latest-value mailbox replacement. App media orchestration, login registration, physical-device release, and live CoreMediaIO lifecycle remain signed, manual per-release checks. Signed results and the current automated boundary are recorded in [`VALIDATION.md`](../VALIDATION.md).

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
5. Replace the saved profile with a controlled invalid document. Confirm its text is preserved, both automatic lanes remain stopped, and the panel directs the user to repair and validate it. Restore a valid profile afterward.
6. Force one bounded transient camera and audio start failure while demand remains active. Confirm the panel reports attention required and **Retry** can recover without closing the client.
7. Quit the host explicitly and confirm documented host-absent behavior: animated camera placeholder and microphone silence. A client must not be claimed to relaunch the quit host.

### Conversation

1. Confirm a wake phrase and command in one final transcript starts one agent turn.
2. Speak the wake phrase alone, then a command in the next window. Confirm the capture-time window is honored even with ASR latency.
3. Confirm interim or unrelated ambient transcripts do not start a turn in wake mode.
4. Confirm a gesture starts a turn without arming or consuming the voice gate.
5. During streamed speech, barge in and confirm that the HTTP body and every queued audio buffer stop. Then start another turn and confirm no stale speech resumes.
6. Load a legacy profile without `activationMode` and confirm its intentional always-listening behavior before migrating it.

### Models

Use a profile with the services you intend to test. Check each real changed route, not only a health endpoint:

- submit one JPEG to the configured detector;
- submit one 16 kHz PCM window to ASR;
- send one chat turn;
- send one VLM frame if enabled;
- request one complete PCM16 WAV speech response;
- when `streamingPCM` is enabled, request raw mono PCM16, verify its sample-rate metadata, first nonzero virtual-microphone samples, bounded completion, and cancellation.

Start local services through their project service manager. Do not start duplicate or GPU-heavy services without checking current workloads and VRAM.

## Logs and errors

Pipeline and lifecycle errors appear in the menu-bar panel. CoreMediaIO extension diagnostics are available in Console under subsystem `ai.kortexa.aicamera.camera-extension`. Driver load failures are reported by `coreaudiod`.

Useful non-destructive checks:

```sh
systemextensionsctl list | grep ai.kortexa.aicamera
system_profiler SPAudioDataType | grep -A8 'AI Camera Microphone'
plutil -p '/Applications/AI Camera.app/Contents/Info.plist'
```

Do not use broad process-kill or system-directory cleanup commands for diagnosis.
