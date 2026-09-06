# Local spoken translation

Issue: https://github.com/kortexa-ai/aicamera/issues/57

Implement a session-only Voice control using the existing physical-microphone Whisper/HY-MT path
and installed macOS buffer synthesis. Keep caption visibility, agent input listening, and spoken
translation separate. An agent answer owns speech output until it drains; then translation resumes
from fresh capture. Global privacy mute and output/source changes retire pending work.

The local increment includes bounded text/PCM synthesis and a single active/pending queue, typed
microphone-only segments, output ownership, gain ramps and a final output limiter, manual Off,
readiness help, and native offline acceptance. No settings-schema or system-component changes.

Validation uses `scripts/validate.sh` (including native synthetic voice routing) and the optional
`validate-spoken-translation.swift --system-voice` fixture for installed voice synthesis without
playback. See `docs/companion-acceptance.md` for independent-client and bilingual acceptance.
Follow-ups in #57 include the spoken-translation agent tool, separate remote translation client,
explicit local voice preview, and external presentation assets. These are not implied by the local
toolbar implementation. Public release and installed build details belong in the owning issue.
