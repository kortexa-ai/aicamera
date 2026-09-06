# Local speech format regression

Issue: https://github.com/kortexa-ai/aicamera/issues/64

Extend the existing native PCM conversion fixture with 22.05 kHz system-speech input and include
the fixture in routine full validation. Verify duration, pitch, channel agreement, irregular-buffer
continuity, and final drain using generated signals held in memory. Preserve production converter
behavior and all installed app/device state. Translation quality and call routing remain separate
acceptance under issue 57.
