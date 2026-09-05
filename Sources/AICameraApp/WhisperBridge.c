#include "WhisperBridge.h"
#include <whisper/whisper.h>
#include <stdlib.h>
#include <string.h>

struct AICameraWhisperContext { struct whisper_context *value; };
struct Cancellation { AICameraWhisperAbort callback; void *user_data; };

AICameraWhisperContext *AICameraWhisperLoad(const char *model_path) {
    if (model_path == NULL) return NULL;
    struct whisper_context_params params = whisper_context_default_params();
    params.use_gpu = true;
    struct whisper_context *value = whisper_init_from_file_with_params(model_path, params);
    if (value == NULL) return NULL;
    AICameraWhisperContext *context = malloc(sizeof(*context));
    if (context == NULL) { whisper_free(value); return NULL; }
    context->value = value;
    return context;
}

void AICameraWhisperFree(AICameraWhisperContext *context) {
    if (context == NULL) return;
    whisper_free(context->value);
    free(context);
}

bool AICameraWhisperSupportsLanguage(const char *language) {
    return language != NULL && (strcmp(language, "auto") == 0 || whisper_lang_id(language) >= 0);
}

static bool can_begin_encoder(struct whisper_context *context, struct whisper_state *state, void *user_data) {
    (void) context; (void) state;
    const struct Cancellation *cancellation = user_data;
    return cancellation->callback == NULL || !cancellation->callback(cancellation->user_data);
}

int32_t AICameraWhisperTranscribe(AICameraWhisperContext *context, const float *samples, int32_t count,
                                const char *language, int32_t threads, AICameraWhisperAbort abort, void *user_data) {
    if (context == NULL || samples == NULL || count < 1600 || count > 480000 ||
        threads < 1 || threads > 8 || !AICameraWhisperSupportsLanguage(language)) return -1;
    struct whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.n_threads = threads;
    params.language = language;
    params.translate = false;
    params.no_context = true;
    params.no_timestamps = true;
    params.single_segment = true;
    params.print_special = false;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;
    params.suppress_blank = true;
    params.suppress_nst = true;
    params.temperature = 0;
    params.temperature_inc = 0;
    params.greedy.best_of = 1;
    params.abort_callback = abort;
    params.abort_callback_user_data = user_data;
    struct Cancellation cancellation = { abort, user_data };
    params.encoder_begin_callback = can_begin_encoder;
    params.encoder_begin_callback_user_data = &cancellation;
    return whisper_full(context->value, params, samples, count);
}

int32_t AICameraWhisperSegmentCount(AICameraWhisperContext *context) {
    return context == NULL ? 0 : whisper_full_n_segments(context->value);
}

const char *AICameraWhisperSegmentText(AICameraWhisperContext *context, int32_t index) {
    if (context == NULL || index < 0 || index >= whisper_full_n_segments(context->value)) return NULL;
    return whisper_full_get_segment_text(context->value, index);
}

float AICameraWhisperNoSpeechProbability(AICameraWhisperContext *context, int32_t index) {
    if (context == NULL || index < 0 || index >= whisper_full_n_segments(context->value)) return 1;
    return whisper_full_get_segment_no_speech_prob(context->value, index);
}
