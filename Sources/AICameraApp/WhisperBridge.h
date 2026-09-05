#ifndef AICAMERA_WHISPER_BRIDGE_H
#define AICAMERA_WHISPER_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

// Keep whisper/ggml declarations out of Swift: llama embeds a different ggml version.
typedef struct AICameraWhisperContext AICameraWhisperContext;
typedef bool (*AICameraWhisperAbort)(void *user_data);

AICameraWhisperContext *AICameraWhisperLoad(const char *model_path);
void AICameraWhisperFree(AICameraWhisperContext *context);
bool AICameraWhisperSupportsLanguage(const char *language);
int32_t AICameraWhisperTranscribe(AICameraWhisperContext *context, const float *samples, int32_t count,
                                const char *language, int32_t threads, AICameraWhisperAbort abort, void *user_data);
int32_t AICameraWhisperSegmentCount(AICameraWhisperContext *context);
const char *AICameraWhisperSegmentText(AICameraWhisperContext *context, int32_t index);
float AICameraWhisperNoSpeechProbability(AICameraWhisperContext *context, int32_t index);

#endif
