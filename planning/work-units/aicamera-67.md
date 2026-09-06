# Local addressed-speech probe

Issue: https://github.com/kortexa-ai/aicamera/issues/67

Use pinned LFM2-350M and LFM2.5-350M models with one frozen prompt and synthetic text cases to test
conservative addressee classification on CPU. Compare an explicit-invocation baseline and preserve per-case results.
Do not train, capture user media, change the running app, or connect classification to its input
gate. Record both errors and the limits of text-only evidence before considering a product feature.
