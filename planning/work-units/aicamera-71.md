# Catalyst-compatible camera formats

Issue: https://github.com/kortexa-ai/aicamera/issues/71

WhatsApp for Mac and other Catalyst apps build their capture graph with the iOS pipeline, which
rejects a 32BGRA camera format before requesting a frame (`BWMultiStreamCameraSourceNode`
`-12780`), leaving a black view. Native clients accept either format. The extension now publishes
420v source formats with one continuous 1–60 fps range and converts BGRA feeder and placeholder
frames with a VideoToolbox pixel-transfer session, scaling to the client's active format. The
feeder sink keeps its BGRA 15/30/60 contract, so the host is unchanged. Source and sink negotiate
independently; the former source lockout while the feeder runs is gone.

Camera extension component version 46 (0.1.1). Host release 0.2.1 carries it with unchanged
HAL driver 12. Validation: `scripts/validate.sh`, the native client probe in `build/diagnostics`,
QuickTime, and WhatsApp for Mac through the same log capture that found the failure.
