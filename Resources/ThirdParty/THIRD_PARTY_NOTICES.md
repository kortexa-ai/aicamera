# Third-party notices

AI Camera's original code is MIT licensed. Each third-party component retains its own license.

## Included in the application

- **llama.cpp / GGML**, release b10709: MIT, Georgi Gerganov and contributors.
  Source: https://github.com/ggml-org/llama.cpp. See `LLAMA_CPP_LICENSE.txt`.
- **whisper.cpp / GGML**, release v1.8.6: MIT, Georgi Gerganov and contributors.
  Source: https://github.com/ggml-org/whisper.cpp. See `WHISPER_CPP_LICENSE.txt`.
- **three.js**, r185: MIT, three.js authors. Source: https://github.com/mrdoob/three.js.
  Its full notice is retained beside the overlay runtime in `THREE_LICENSE.txt`.
- **Apple NullAudio sample code**: Apple's permissive sample-code license. The derived HAL
  driver retains the full `APPLE_NULLAUDIO_LICENSE.txt` notice in its own resources.

## Optional model downloads

Model weights are downloaded only when requested; they are not included in the installer.
Their downloads are pinned and checked by SHA-256. These are third-party models, without
endorsement of AI Camera by their authors.

- **OpenAI Whisper**, converted by whisper.cpp: MIT.
  https://huggingface.co/ggerganov/whisper.cpp/tree/5359861c739e955e79d9a303bcbc70fb988958b1
  https://github.com/openai/whisper/blob/main/LICENSE
- **Tencent Hy-MT2 1.8B**, Q4_K_M conversion: Apache 2.0. See `HY_MT2_LICENSE.txt`.
  https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/tree/1cd5208700acedef4ef93019b6cfc148b8522d45
- **Roboflow RF-DETR Medium / Large**, Core ML exports: Apache 2.0. See `RF_DETR_LICENSE.txt`.
  The exports convert the upstream weights to FP16 Core ML; the model card documents that change.
  https://huggingface.co/kortexa-ai/rf-detr-coreml/tree/893b757bc958fab3af1c4dcc96c5d0244f782d35
- **YOLOv3 Tiny**, Apple's Core ML conversion of Darknet: Darknet is public domain under its
  YOLO license. See `YOLO_LICENSE.txt` and https://developer.apple.com/machine-learning/models/.
  This is the original YOLOv3 model, not an Ultralytics YOLO distribution.

Apple frameworks are supplied by macOS. OpenAI services and Codex CLI are separate products;
their access, billing, account policies, and availability are governed by their respective terms.
