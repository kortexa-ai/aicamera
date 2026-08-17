# Architecture

## Data flow

```text
hardware camera ──AVCaptureVideoDataOutput──> render/overlay ──> preview
          │                                      │
          │ sampled latest frames                └──> CMIO sink queue (capacity 1)
          ├──> Apple Vision hand gestures                 │
          ├──> detector adapter                            v
          └──> VLM adapter                       camera system extension
                                                         │
                                                         └──> AI Camera source

hardware microphone ──AVCaptureAudioDataOutput──> two-slot copied PCM ──> bounded conversion queue
          ├──> 16 kHz mono windows ──> bounded ASR lane ──> wake gate ──> agent
          │                                                               │
          └──> microphone player ──┐                         WAV/PCM TTS ──┘
                                   ├──AVAudioEngine mixer<───────────────┘
                                   └──> HAL plug-in output ring
                                                │
                                                └──> AI Camera Microphone input
```

## Targets

| Target | Purpose |
|---|---|
| `AICameraCore` | Versioned profiles, validation, privacy gate, normalized events, adapter protocols, HTTP clients, WAV handling, and actor state. |
| `AICamera` | Menu-bar UI, independent AVFoundation capture lanes, Vision gestures, overlay rendering, pipeline coordination, virtual-device feeder, authorization, demand monitoring, and automatic lifecycle reconciliation. |
| `AICameraCameraExtension` | CoreMediaIO source and sink streams. It forwards one feeder frame at a time and supplies an animated placeholder when the host is absent. |
| `AICameraAudio` | Duplex Core Audio HAL plug-in with a bounded Float32 stereo loopback ring at 44.1 or 48 kHz. |

## Demand-driven lifecycle

```text
camera client ──CMIO source start/stop──> extension `aicd` snapshot + heartbeat ──┐
                                                                                 ├──> host reconciler
microphone client ──HAL ReadInput callbacks──> lock-free recent-reader count ─────┘
                                                                                        │
                                                ┌───────────────────────────────────────┴─────────┐
                                                v                                                 v
                                       physical camera lane                              physical microphone lane
```

The camera extension publishes a bounded timestamped snapshot as a read-only custom CoreMediaIO device property. Its `aicd` selector uses CoreMediaIO's `4cc_aicd_glob_0000` bridge and an `NSData` value, which the legacy C API exposes as raw bytes. Start and stop transitions notify the CoreMediaIO property cache after re-reading locked current state. While a source client is active, the existing placeholder timer refreshes the snapshot once per second. The host polls the property by the virtual camera's stable UID and rejects missing, malformed, future-dated, or older-than-two-second snapshots, so an extension crash or stale DAL cache cannot keep camera capture alive. The extension continues to provide its animated placeholder when the host is absent.

The HAL driver records demand only for actual `ReadInput` operations, not for every `StartIO`; an output-only client, including the host mix writer, therefore does not request the physical microphone. The real-time callback updates a fixed lock-free table and a conservative overflow marker. It never allocates, locks, logs, or performs IPC. Entries expire after one second and are cleared on stop/removal. The host reads the custom `aicc` count outside its real-time path.

The menu-bar host polls both signals every 250 ms in the common run-loop modes and publishes one combined demand snapshot only when either value changes. Camera and microphone controllers start and stop independently. A shared `PipelineCoordinator` exists only while at least one lane is active; per-lane gates reject stale preview, frame, utterance, and playback callbacks after that lane stops. Draining the final lane cancels inference, speech, and stale scene state. Automatic reconciliation never requests privacy access or starts installation. Those actions remain explicit in the UI.

Explicit local camera and microphone tests are ephemeral demand sources admitted only while both external client counts are zero. They use the normal capture, render, meter, and enabled inference paths, but do not start an unconsumed virtual-camera feeder or virtual-microphone output. Camera testing shows the processed preview. Microphone testing polls a one-slot normalized level snapshot at 10 Hz; peak calculation and snapshot storage run on the existing bounded audio processing queue, never on the HAL render callback or AVCapture sample callback. Any observed external demand cancels both tests and performs one serialized full coordinator teardown before client capture starts. This clean boundary prevents test-derived inference, transcripts, speech, or scene state from leaking into a client session.

If the host is absent, the installed camera keeps publishing its animated placeholder and the HAL input returns silence. Selecting a virtual device cannot launch an app that the user explicitly quit, which is why launch at login is offered as an opt-in setting.

## Real-time and backpressure rules

Capture callbacks do not wait for a network request.

- AVFoundation discards late video frames.
- Gesture work has one in-flight request.
- Each network stage has one in-flight frame and one replaceable pending frame.
- A frame is checked for age before and after inference.
- Results have independent frame ordering. A fast gesture cannot invalidate a detector result from another modality.
- The CoreMediaIO feeder queue has one frame. A full queue drops the new frame.
- The AVCapture audio delegate admits at most two copied, size-capped PCM buffers; microphone player buffers also have a fixed limit.
- ASR has one in-flight window and one bounded pending window. Always-listening mode keeps the latest pending window; wake mode preserves the immediate next window so a wake-only turn cannot lose its command.
- Streaming HTTP has cumulative, chunk-size, and buffered-chunk limits. The audio controller holds a fixed player queue and at most one awaited ingress chunk, so playback pressure reaches the network consumer without an unbounded closure queue.
- Stop, accepted turn replacement, and barge-in cancel network work and reset queued speech. A conversation remains active until its final audio buffer plays or is reset.

The app stores only the current scene state. It does not write frames or audio to disk. `privacy.persistMedia` is reserved for a future explicit recording feature and must remain `false` in the current schema.

## Video path

The host captures BGRA frames. `OverlayRenderer` aspect-fills and optionally mirrors them into the selected virtual output size. It draws the current `SceneSnapshot` and sends an IOSurface-backed sample to the extension sink. The extension forwards valid sink samples to its source clients. It publishes 640×480, 1280×720, and 1920×1080 at 15, 30, or 60 fps.

The sink fails closed to other writers. If the CMIO service can resolve the client, Security.framework validates the live host against the exact identifier, Apple generic anchor, extension-derived team, and no-`get-task-allow` requirement. Every authorization also takes two matching kernel code-signing snapshots through PID-version-bound `csops_audittoken`. These snapshots require the installed path, exact identifier and team, an allowed Apple validation category, hardened runtime and library validation, and no ad-hoc, debugged, invalid-page, or `get-task-allow` state. The accepted execution binding and `CMIOExtensionClient.clientID` are checked again at start. A bounded watchdog checks the binding while consumption waits, and every forwarded sample gets an immediate check. Stop or identity change clears or revokes the binding; authorization is never cached by numeric PID.

Apple Vision hand pose processing runs locally. Network frame JPEGs have a maximum edge of 1024 pixels. Stage age and rate settings are part of the profile.

## Audio path

The app selects Core Audio devices by stable UID. One engine captures the microphone. A second engine targets the configured loopback output. The host converts the microphone to stereo Float32 for the mix and separately to mono Float32 at 16 kHz for ASR windows.

TTS can return a complete PCM16 WAV. An `openAISpeech` endpoint can also opt into streamed mono PCM16 little-endian audio. The host converts either form to the mix format and applies bounded player admission. Barge-in cancels the active agent/TTS request and queued playback while a speech buffer is pending.

The HAL plug-in is not an inference component. It exposes the samples written to its output stream through its input stream. When no writer is active, readers receive silence. Only recent input reads contribute to microphone demand; opening the virtual device only for output does not acquire hardware input.

## Typed composition

AI Camera uses a typed topology rather than arbitrary executable plug-ins. A profile chooses endpoints for these roles:

- zero or one local hand-gesture stage;
- zero or more configured detector/VLM stage entries;
- optional ASR, agent, and TTS roles.

Every endpoint declares an adapter kind, URL, path override, model, timeout, auth reference, and adapter options. New service implementations are added by implementing a core protocol and registering the adapter in `AdapterFactory`.
