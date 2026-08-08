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

hardware microphone ──AVAudioEngine tap──> bounded conversion queue
          ├──> 16 kHz mono utterance windows ──> ASR ──> agent ──> TTS
          │                                                        │
          └──> microphone player ──┐                               │
                                   ├──AVAudioEngine mixer<─────────┘
                                   └──> HAL plug-in output ring
                                                │
                                                └──> AI Camera Audio input
```

## Targets

| Target | Purpose |
|---|---|
| `AICameraCore` | Versioned profiles, validation, privacy gate, normalized events, adapter protocols, HTTP clients, WAV handling, and actor state. |
| `AICamera` | Menu-bar UI, AVFoundation capture, Vision gestures, overlay rendering, pipeline coordination, virtual-device feeder, authorization, and lifecycle controls. |
| `AICameraCameraExtension` | CoreMediaIO source and sink streams. It forwards one feeder frame at a time and supplies an animated placeholder when the host is absent. |
| `AICameraAudio` | Duplex Core Audio HAL plug-in with a bounded Float32 stereo loopback ring at 44.1 or 48 kHz. |

## Real-time and backpressure rules

Capture callbacks do not wait for a network request.

- AVFoundation discards late video frames.
- Gesture work has one in-flight request.
- Each network stage has one in-flight frame and one replaceable pending frame.
- A frame is checked for age before and after inference.
- Results have independent frame ordering. A fast gesture cannot invalidate a detector result from another modality.
- The CoreMediaIO feeder queue has one frame. A full queue drops the new frame.
- Microphone and speech player-node queues have fixed limits. New stale buffers are dropped instead of accumulating latency.
- Stop cancels conversation, expiry, and stage tasks.

The app stores only the current scene state. It does not write frames or audio to disk. `privacy.persistMedia` is reserved for a future explicit recording feature and must remain `false` in the current schema.

## Video path

The host captures BGRA frames. `OverlayRenderer` aspect-fills and optionally mirrors them into the selected virtual output size. It draws the current `SceneSnapshot` and sends an IOSurface-backed sample to the extension sink. The extension forwards valid sink samples to its source clients. It publishes 640×480, 1280×720, and 1920×1080 at 15, 30, or 60 fps.

Apple Vision hand pose processing runs locally. Network frame JPEGs have a maximum edge of 1024 pixels. Stage age and rate settings are part of the profile.

## Audio path

The app selects Core Audio devices by stable UID. One engine captures the microphone. A second engine targets the configured loopback output. The host converts the microphone to stereo Float32 for the mix and separately to mono Float32 at 16 kHz for ASR windows.

TTS must return PCM16 WAV. The host converts it to the mix format and schedules it with a bounded queue. Barge-in cancels the active agent/TTS turn only while a speech buffer is pending.

The HAL plug-in is not an inference component. It exposes the samples written to its output stream through its input stream. When no writer is active, readers receive silence.

## Typed composition

AI Camera uses a typed topology rather than arbitrary executable plug-ins. A profile chooses endpoints for these roles:

- zero or one local hand-gesture stage;
- zero or more configured detector/VLM stage entries;
- optional ASR, agent, and TTS roles.

Every endpoint declares an adapter kind, URL, path override, model, timeout, auth reference, and adapter options. New service implementations are added by implementing a core protocol and registering the adapter in `AdapterFactory`.
