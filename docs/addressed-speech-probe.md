# Can a small model identify speech addressed to the agent?

The model-and-runner setup failed simple JSON input-reading controls. This experiment is therefore
inconclusive about addressed-speech capability. Neither tested setup is ready to control listening.
Keep explicit Pause listening and One question as the user controls. They let a person ask the
agent something, then talk to a friend while the answer finishes. A classifier must never reopen
a user-closed input gate.

## Method

The probe uses 60 hand-authored synthetic text cases, one frozen prompt, and the public
[LiquidAI LFM2-350M GGUF](https://huggingface.co/LiquidAI/LFM2-350M-GGUF/tree/8fdc9d526b7ed346b19257551b05816c7912ecc2)
and [LFM2.5-350M GGUF](https://huggingface.co/LiquidAI/LFM2.5-350M-GGUF/tree/9969000761ce34de907bf20017cbfc3d52d6eaf9)
Q8_0 models. There is no training, prompt search, real transcript, microphone access, or remote
inference. The existing llama.cpp completion binary runs each case in a separate CPU process with
two threads, a 2,048-token context, eight output tokens, greedy sampling, and a three-label grammar.
Each process has a 30-second deadline; the whole case loop has a 600-second deadline.

The model sees only the latest user text and an optional previous agent utterance. It does not see
the expected label, case group, or identifier. The prompt and corpus were frozen before the first
classifier inference. A separate constant-word canary checked the runner and output format.
After the first run, the same test was run once on the newer model linked by Liquid AI's model
card. Only model selection and its recorded identity changed; the inputs and decoding did not.
The ChatML input relies on the tokenizer to add BOS; a second BOS is not inserted.

The labels describe evidence in the text:

- `agent`: an explicit direct address to AI Camera.
- `other`: a clear address to another person, or discussion/quotation of the assistant.
- `uncertain`: either listener could be the addressee.

This is a conservative policy probe, not ground truth about hidden human intent. Even after an
agent asks “Which city?”, “Seattle” could be a reply to the friend. The input cannot distinguish
those two situations. The corpus deliberately marks such cases uncertain. It includes a few
Spanish, French, German, and Chinese examples, not enough to evaluate a language.

## Observed results

Each model completed all 60 cases on September 6, 2026. Every output matched the required syntax.
The following counts are diagnostic outputs from the initial runs, **not qualified classifier
accuracy**. Input-reading controls added afterward failed, as described below. The first table
is LFM2-350M:

| Expected label | Predicted agent | Predicted other | Predicted uncertain |
| --- | ---: | ---: | ---: |
| Agent, 20 cases | 6 | 14 | 0 |
| Other, 20 cases | 3 | 17 | 0 |
| Uncertain, 20 cases | 4 | 16 | 0 |

LFM2 matched 23 of 60 labels. For a proposed decision to send speech to the agent, it would
miss 14 direct requests and admit seven cases without a clear agent address. It never abstained.
For example, it rejected “AI Camera, what is the weather in Seattle?” but admitted “Alex, can you
check the weather for our picnic?” It also admitted “Maya, try saying AI Camera, show a timer.”

The newer LFM2.5-350M produced a different failure pattern:

| Expected label | Predicted agent | Predicted other | Predicted uncertain |
| --- | ---: | ---: | ---: |
| Agent, 20 cases | 0 | 3 | 17 |
| Other, 20 cases | 0 | 0 | 20 |
| Uncertain, 20 cases | 0 | 1 | 19 |

It matched 19 labels and never selected agent. Zero false admissions here comes with missing all
20 direct requests. This does not make it a useful listening control.

A transparent baseline recognizes AI Camera at the beginning or after a comma at the end of the
utterance; everything else is uncertain. It found 19 of 20 direct requests, missed the mid-sentence
address in a19, and admitted none of the 40 other/uncertain cases. It matched 39 of 60 three-way
labels because it does not attempt to distinguish other from uncertain. Its result does not prove
that name detection is a reliable wake-word system on real audio.

To preserve all predictions compactly: LFM2 returned `agent` for a02, a04, a06, a13, a14,
a16, o02, o12, o13, u02, u04, u17, and u20. It returned `other` for every remaining case.
LFM2.5 returned `other` for a09, a14, a16, and u20, and `uncertain` for every remaining case.
The baseline returned `agent` for a01–a20 except a19, and `uncertain` for everything else.
The [corpus](../Tests/Fixtures/addressed-speech.json) contains the exact inputs and expected labels.

These observations apply to these quantizations, this backend, prompt, and synthetic corpus. They
do not isolate model quality, nor rule out a trained classifier or useful acoustic context. Liquid AI recommends
[fine-tuning its small models for narrow tasks](https://huggingface.co/LiquidAI/LFM2-350M).
No claim about real-call accuracy, speech recognition errors, latency, or energy use follows from
these runs. Per-process elapsed times include repeated model loading on a shared machine.

## Input-reading qualification failed

The constant-word canary only proved that the runner could emit the one allowed word. A stronger
control asked it to read `{"animal":"cat"}` and `{"animal":"dog"}`, with both words allowed by
the grammar. LFM2 returned cat for both inputs; LFM2.5 returned dog for both. Both therefore failed
one of two cases. The control used the same JSON/ChatML formatting and CPU execution path.

A bounded diagnostic on LFM2.5 repeated the cat input across raw versus native chat formatting,
grammar on/off, and warmup on/off. All eight combinations returned dog. A simpler unconstrained
instruction to copy the plain user word dog succeeded with both models. These observations do
not identify whether the remaining problem is model behavior, prompt interpretation, quantization,
or the backend. They prevent attributing the earlier counts specifically to addressee reasoning.

The probe now runs both input-reading controls before the corpus. If either fails, it preserves
the evidence, exits unsuccessfully, and runs no classification cases. The initial diagnostic runs
predate this guard. No prompt was tuned and no model was trained to improve their scores.

## Reproduce

The optional probe is separate from normal app validation. It needs an existing llama-completion
binary with LFM2 support. It installs no packages and starts no service. Review the model's
[LFM Open License v1.0](https://huggingface.co/LiquidAI/LFM2-350M-GGUF/blob/8fdc9d526b7ed346b19257551b05816c7912ecc2/LICENSE)
before use or redistribution; the weights are not bundled with AI Camera.

```sh
HF_HUB_DISABLE_IMPLICIT_TOKEN=1 hf download LiquidAI/LFM2-350M-GGUF \
  LFM2-350M-Q8_0.gguf LICENSE README.md \
  --revision 8fdc9d526b7ed346b19257551b05816c7912ecc2 \
  --local-dir build/addressed-speech/model
python3 scripts/probe-addressed-speech.py --check-only
python3 scripts/probe-addressed-speech.py --runner /path/to/llama-completion
```

For the newer model, download `LFM2.5-350M-Q8_0.gguf` from
`LiquidAI/LFM2.5-350M-GGUF` at revision `9969000761ce34de907bf20017cbfc3d52d6eaf9` into
`build/addressed-speech/model-2.5`, then add `--generation lfm2.5` to the probe command.
On the tested backend the current script stops at input-reading qualification; it does not rerun
the corpus or silently treat a canary failure as a classification result.

The script verifies the model, corpus, and prompt hashes before inference. It refuses to replace
an existing results file. Use `--output build/addressed-speech/another-run.json` for a deliberate
new run. The JSON records every synthetic input, raw output, backend log, summary, runner version,
and binary/script hash. Partial evidence survives a timeout or backend failure. Temporary prompt
files are removed when the process exits normally or through a handled exception.

The recorded backend is llama.cpp build 10603, commit c060ca974, AppleClang 21.0.0.21000101,
Darwin arm64. SHA-256 provenance:

| Input or artifact | SHA-256 |
| --- | --- |
| LFM2 Q8_0 model | `b7bfeab6495a1ae3ae78811c1297df9f301b35261ff9580d42fb30dc4dc9034b` |
| LFM2.5 Q8_0 model | `be036a757295e550098b85e13f6af2735d0fa73b41e1156a40c7d8e8e32a5766` |
| Corpus | `5fb4d337e32470d2d3b697828124853f10e842671c83ef6805e735267f9e385d` |
| Prompt | `b76a0a5ca51968afab31b510e1b70c4c8c3edd31a64989f3eb1c568ee7d1cb57` |
| Runner binary | `e77bc318f9218f2abaec6235759dfeaf53f24c9f734657ad3a077eb069933676` |
| Initial LFM2 probe script, before the guard | `a19cae1b6269604c26ad4eb2e6c878ef281efefde3ff6ceb64c538450e4ed34d` |
| Initial LFM2.5 probe script, before the guard | `eb29de7c46953a3f8334c3786261d58e32e4776dafda5b25504708dadd4a38e3` |
| Initial LFM2 local results JSON | `45d9e3d28e645eab6c552019e0c65d523b6516c93fe3e9f4f38c20bc5204ebbb` |
| Initial LFM2.5 local results JSON | `95f541b3f9a55d659ca1ed492bfc3d5a128597d3f20ccc457d3380d39d0b460e` |

## What would justify another step?

First test whether the explicit listening controls meet the user's call workflow. Qualify the
local inference setup on basic input-reading controls before interpreting classifier scores. If automatic
addressing still has value, define an opt-in evaluation with realistic switching, interrupted
sentences, quoted names, and recognition errors. Keep a separate held-out set; do not tune on this
small probe and call the resulting score general accuracy. Optimize false admissions and missed
requests separately, with an explicit uncertain outcome.

Any local-only addressing promise also needs local transcription. Sending audio to a remote
transcriber before deciding whom it addresses does not provide that boundary. A future design
must bound any pending audio, respect full mute and explicit agent pause, and handle late results.
No classifier or new model dependency is connected to the app by this experiment.
