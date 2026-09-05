# Embedded models

Local transcription, translation, detection, and gestures run in the macOS host. Model downloads
are explicit network requests for public weights. They do not send microphone audio, camera frames,
transcripts, or credentials. Inference uses memory-only inputs; AI Camera does not record media.

## Whisper transcription

Choose **Settings → AI → Transcription → Local Whisper**. Base is the lower-memory, faster choice;
Small uses more compute and offers a larger multilingual model. Auto-detect is available, but choosing
a known language avoids detection overhead and can help short utterances. Download a model before
saving and enabling the local provider. The readiness row reports its installed file size.

| Model | Exact download bytes | SHA-256 |
|---|---:|---|
| `ggml-base.bin` | 147951465 | `60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe` |
| `ggml-small-q5_1.bin` | 190085487 | `ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb` |

Both artifacts come from [ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp/tree/5359861c739e955e79d9a303bcbc70fb988958b1),
pinned to revision `5359861c739e955e79d9a303bcbc70fb988958b1`. The upstream model card identifies
the converted Whisper models as MIT licensed.

The embedded runtime is the official [whisper.cpp v1.8.6 release](https://github.com/ggml-org/whisper.cpp/releases/tag/v1.8.6).
Swift Package Manager downloads `whisper-v1.8.6-xcframework.zip`, whose checksum is
`654f6534b1d109cf1f53c3ac94de14d1aedbc08600bf9743e2b331c1619a863f`.
Its MIT notice is included in the app and in
[`WHISPER_CPP_LICENSE.txt`](../Resources/ThirdParty/WHISPER_CPP_LICENSE.txt).
A narrow C bridge isolates the runtime's GGML headers from the separate llama.cpp framework used
for translation; both engines are exercised in the same process by the native acceptance harness.

The host supplies bounded 16 kHz mono PCM16 windows. Whisper accepts 0.1–30 seconds, rejects invalid
input, skips near-zero silence, and bounds transcript bytes. The pipeline keeps one active request
and a bounded pending window. Model loading and inference run on the client actor, outside capture
callbacks. Each selected model client is cached across pipeline restarts. Loading cannot be aborted
inside the runtime; cancellation is checked immediately afterward. Inference has native abort hooks.
Removing weights releases the cache, while an already-running pipeline owns its reference until it
stops. Fixed windows can split speech at boundaries; the app does not claim streaming ASR or full VAD.

## Download and storage lifecycle

Whisper, HY-MT2, and vision weights use one streamed downloader. It writes a private temporary file,
checks declared and received size limits, computes SHA-256 as bytes arrive, and installs only after
verification. Progress is throttled to ten updates per second. Failed and cancelled downloads remove
their partial files. Redirects must stay on HTTPS without URL credentials. Model downloads use no
cookie storage or response cache.

Whisper and HY-MT2 weights live in `~/Library/Application Support/AI Camera/Models/`. They are not
bundled in the app or tracked by Git. **Remove** deletes the selected artifact; removing an active
model first disables that feature. Cancellation and removal invalidate download ownership so a late
completion cannot restore deleted weights. Vision weights are compiled to Core ML before becoming
ready. Core ML compilation cannot be interrupted; cancellation waits for compilation to finish,
then discards the result. The UI reports this final cleanup instead of permitting overlapping jobs.

HY-MT2 uses the pinned llama.cpp package and Q4_K_M artifact recorded in
`BuiltinTranslationModelController.swift`. RF-DETR uses the pinned Core ML artifacts recorded in
`BuiltinVisionModelController.swift`. Their existing license notices ship in `Resources/ThirdParty`.
See [native validation procedures](testing.md#native-local-whisper) and
[measured results](../VALIDATION.md) for the tested hardware and performance limits.
