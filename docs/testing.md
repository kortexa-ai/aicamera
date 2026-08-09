# Testing and diagnostics

## Safe validation

Run:

```sh
scripts/validate.sh
```

It performs:

1. Swift package unit tests;
2. property-list and entitlement linting;
3. strict C syntax checks for the HAL plug-in;
4. an unsigned Xcode build of all four targets;
5. bundle-ID, resource, embed-path, and exported-factory checks; and
6. an in-process HAL factory/IO harness for the exact property graph, malformed inputs, clock behavior, multi-client reads, sample-rate request coalescing, concurrent ring wrap, and reset behavior.

It does not request media permission, start inference services, install a driver, or submit a system-extension request.

For the slower HAL memory, undefined-behavior, numeric-cast, and concurrency checks, run:

```sh
scripts/validate-hal-sanitizers.sh
```

This builds temporary AddressSanitizer/UndefinedBehaviorSanitizer and ThreadSanitizer bundles, runs the same harness, and removes them. It does not install a driver. Leak detection is disabled because the macOS AddressSanitizer runtime does not support it.

## Unit coverage

The 50 core tests cover profile round trips and legacy migration, wake-phrase matching and capture-time expiry, nominal frame-rate matching, remote privacy grants, adapter normalization, WAV encoding/decoding, streamed-speech metadata, cumulative and buffer limits, redirect rejection, startup and active-body cancellation, per-modality stale results, result expiry, and latest-value mailbox replacement. App media orchestration and CoreMediaIO lifecycle still require the signed manual checks below.

## Manual device acceptance

Use a signed app installed in `/Applications`.

### Camera

1. Activate and approve the extension.
2. Start AI Camera with a hardware camera.
3. In QuickTime Player, create a movie recording and select **AI Camera**.
4. Confirm the processed picture, overlay alignment, frame continuity, and placeholder when the host stops.
5. Repeat with a second client and the configured format.
6. Deactivate the extension and confirm that the device disappears after the OS completes removal.

### Audio

1. Install the driver and reopen Audio MIDI Setup.
2. Confirm **AI Camera Microphone** has stereo input and output at 44.1 and 48 kHz.
3. Start the proxy and select **AI Camera Microphone** in QuickTime or another recorder.
4. Confirm microphone passthrough, complete-WAV speech, opt-in streaming PCM speech, barge-in, and silence when the host stops.
5. With transcription off, confirm that microphone passthrough and energy-based barge-in still work but no ASR request is sent.
6. Remove the driver and confirm that the device disappears after Core Audio reloads.

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
