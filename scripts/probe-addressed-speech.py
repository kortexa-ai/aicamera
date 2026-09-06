#!/usr/bin/env python3
"""Optional CPU-only synthetic research probe. Does not connect to the app or a service."""

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
MODELS = {
    "lfm2": {
        "model": "LiquidAI/LFM2-350M-GGUF/LFM2-350M-Q8_0.gguf",
        "revision": "8fdc9d526b7ed346b19257551b05816c7912ecc2",
        "sha256": "b7bfeab6495a1ae3ae78811c1297df9f301b35261ff9580d42fb30dc4dc9034b",
        "directory": "model", "output": "results.json",
    },
    "lfm2.5": {
        "model": "LiquidAI/LFM2.5-350M-GGUF/LFM2.5-350M-Q8_0.gguf",
        "revision": "9969000761ce34de907bf20017cbfc3d52d6eaf9",
        "sha256": "be036a757295e550098b85e13f6af2735d0fa73b41e1156a40c7d8e8e32a5766",
        "directory": "model-2.5", "output": "results-lfm2.5.json",
    },
}
CORPUS_SHA = "5fb4d337e32470d2d3b697828124853f10e842671c83ef6805e735267f9e385d"
PROMPT_SHA = "b76a0a5ca51968afab31b510e1b70c4c8c3edd31a64989f3eb1c568ee7d1cb57"
LABELS = ("agent", "other", "uncertain")
GRAMMAR = 'root ::= "agent" | "other" | "uncertain"'


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def require_digest(path, expected):
    if digest(path) != expected:
        raise ValueError(f"Pinned input changed: {path.name}")


def parse_label(output):
    # llama-completion prints this fixed terminal marker after EOS. Accept no prose.
    match = re.fullmatch(r"(agent|other|uncertain)(?: \[end of text\])?", output.strip())
    return match.group(1) if match else "invalid"


def invocation_baseline(text):
    # Transparent deliberately small baseline; not a product wake-word feature.
    starts = re.match(r"^(?:hey\s+)?AI Camera\s*[,，]", text, re.IGNORECASE)
    ends = re.search(r"[,，]\s*AI Camera[.!?。？]?\s*$", text, re.IGNORECASE)
    return "agent" if starts or ends else "uncertain"


def completion_command(runner, model, prompt_path, grammar):
    return [str(runner), "-m", str(model), "--device", "none", "-ngl", "0",
            "--no-op-offload", "--no-kv-offload", "-t", "2", "-tb", "2", "-c", "2048",
            "-n", "8", "--seed", "42", "--temp", "0", "--no-conversation",
            "--no-display-prompt", "--no-warmup", "--no-perf", "--simple-io",
            "--grammar", grammar, "-f", str(prompt_path)]


def format_prompt(system, data):
    # The model tokenizer adds BOS itself. Do not put a second BOS in this template.
    return f"<|im_start|>system\n{system}<|im_end|>\n<|im_start|>user\n{json.dumps(data, ensure_ascii=False)}<|im_end|>\n<|im_start|>assistant\n"


def summary(rows, key):
    confusion = {label: dict(Counter(row[key] for row in rows if row["expected"] == label))
                 for label in LABELS}
    return {
        "correct": sum(row[key] == row["expected"] for row in rows),
        "total": len(rows),
        "false_agent": sum(row[key] == "agent" and row["expected"] != "agent" for row in rows),
        "missed_agent": sum(row[key] != "agent" and row["expected"] == "agent" for row in rows),
        "abstained": sum(row[key] == "uncertain" for row in rows),
        "invalid": sum(row[key] == "invalid" for row in rows),
        "confusion": confusion,
    }


def fixtures():
    corpus = ROOT / "Tests/Fixtures/addressed-speech.json"
    prompt = ROOT / "Tests/Fixtures/addressed-speech-prompt.txt"
    require_digest(corpus, CORPUS_SHA)
    require_digest(prompt, PROMPT_SHA)
    cases = json.loads(corpus.read_text())["cases"]
    if len(cases) != 60 or len({case["id"] for case in cases}) != 60:
        raise ValueError("Expected exactly 60 uniquely identified frozen cases")
    if Counter(case["expected"] for case in cases) != Counter(dict.fromkeys(LABELS, 20)):
        raise ValueError("Expected 20 cases per label")
    for case in cases:
        if set(case) != {"id", "group", "agent_last_utterance", "user_text", "expected"}:
            raise ValueError("Unexpected case fields")
        if any(not isinstance(value, str) or len(value.encode()) > 2048 for value in case.values()):
            raise ValueError("Invalid case value")
    return cases, prompt.read_text().strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runner", type=Path, help="Existing llama-completion executable")
    parser.add_argument("--generation", choices=MODELS, default="lfm2")
    parser.add_argument("--model", type=Path, help="Override local path to the pinned model")
    parser.add_argument("--output", type=Path, help="New evidence file; defaults to a generation-specific file under build")
    parser.add_argument("--check-only", action="store_true", help="Check frozen fixtures and parser without inference")
    args = parser.parse_args()
    model = MODELS[args.generation]
    args.model = args.model or ROOT / "build/addressed-speech" / model["directory"] / model["model"].split("/")[-1]
    args.output = args.output or ROOT / "build/addressed-speech" / model["output"]
    cases, system = fixtures()
    for output, expected in [("agent [end of text]\n", "agent"), ("uncertain", "uncertain"),
                             ("other\n\n", "other"), ("", "invalid"), ("agent other", "invalid"),
                             ("I think agent", "invalid")]:
        if parse_label(output) != expected:
            raise ValueError("Output parser check failed")
    if args.check_only:
        print("Frozen corpus, label balance, bounds, and strict output parser passed.")
        return
    if args.runner is None or not args.runner.is_file() or not os.access(args.runner, os.X_OK):
        parser.error("--runner must name an existing llama-completion executable")
    require_digest(args.model, model["sha256"])
    if args.output.exists():
        parser.error("Output exists; use a new output path to preserve previous evidence")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(("LLAMA_", "GGML_", "HF_", "OPENAI_"))}
    version = subprocess.run([str(args.runner), "--version"], env=environment,
                             capture_output=True, text=True, timeout=30, check=True)
    report = {
        "created_at": datetime.now(timezone.utc).isoformat(),
        "model": model["model"], "revision": model["revision"],
        "model_sha256": model["sha256"], "corpus_sha256": CORPUS_SHA, "prompt_sha256": PROMPT_SHA,
        "runner_sha256": digest(args.runner),
        "runner_version": (version.stdout + version.stderr).strip(),
        "probe_sha256": digest(Path(__file__)),
        "limits": {"cpu_threads": 2, "context_tokens": 2048, "output_tokens": 8,
                   "per_case_seconds": 30, "total_seconds": 600},
        "method": "One frozen prompt, greedy grammar-constrained labels, separate CPU process per case; no training or tuning.",
        "timing_note": "Process elapsed time includes repeated model loading; shared machine, not an isolated performance benchmark.",
        "qualified": False, "runner_canaries": [], "complete": False, "results": [],
    }
    started = time.monotonic()
    # Reserve a new file before inference; preserve partial evidence if a backend call fails.
    with args.output.open("x", encoding="utf-8") as evidence, tempfile.TemporaryDirectory(prefix="aicamera-addressed-") as temporary:
        def save():
            evidence.seek(0)
            json.dump(report, evidence, ensure_ascii=False, indent=2)
            evidence.write("\n")
            evidence.truncate()
            evidence.flush()

        save()
        try:
            # A valid constrained label is not proof that the runner understood its input.
            # These controls exposed failures in the initial exploratory runs. Do not report
            # another classification score until both distinct inputs are read correctly.
            prompt_path = Path(temporary) / "prompt.txt"
            for animal in ("cat", "dog"):
                canary_system = "Read the animal field in the JSON input. Output exactly its value: cat or dog."
                prompt_path.write_text(format_prompt(canary_system, {"animal": animal}))
                result = subprocess.run(
                    completion_command(args.runner, args.model, prompt_path, 'root ::= "cat" | "dog"'),
                    env=environment, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                    timeout=30, check=True,
                )
                if len(result.stdout.encode()) > 4096 or len(result.stderr.encode()) > 1024 * 1024:
                    raise ValueError("Unexpected canary output size")
                passed = result.stdout.strip() == animal + " [end of text]"
                report["runner_canaries"].append({"system": canary_system, "input": {"animal": animal},
                                                  "expected": animal, "output": result.stdout,
                                                  "backend_log": result.stderr, "passed": passed})
                save()
            report["qualified"] = all(row["passed"] for row in report["runner_canaries"])
            if not report["qualified"]:
                raise ValueError("Input-reading canary failed; classification scores would be unqualified")
            for case in cases:
                remaining = 600 - (time.monotonic() - started)
                if remaining <= 0:
                    raise TimeoutError("Total probe deadline reached")
                data = {key: case[key] for key in ("agent_last_utterance", "user_text")}
                prompt_path.write_text(format_prompt(system, data))
                command = completion_command(args.runner, args.model, prompt_path, GRAMMAR)
                case_started = time.monotonic()
                result = subprocess.run(command, env=environment, stdin=subprocess.DEVNULL,
                                        capture_output=True, text=True, timeout=min(30, remaining), check=True)
                if len(result.stdout.encode()) > 4096 or len(result.stderr.encode()) > 1024 * 1024:
                    raise ValueError("Unexpected backend output size")
                if "double_bos" in result.stderr:
                    raise ValueError("Unexpected duplicate beginning-of-sequence token")
                row = {**case, "prediction": parse_label(result.stdout),
                       "baseline": invocation_baseline(case["user_text"]),
                       "raw_output": result.stdout, "backend_log": result.stderr,
                       "process_elapsed_seconds": round(time.monotonic() - case_started, 4)}
                report["results"].append(row)
                save()
                print(f"{case['id']}: expected={case['expected']} prediction={row['prediction']}", flush=True)
            report["complete"] = True
        except Exception as error:
            report["error"] = f"{type(error).__name__}: {error}"
            raise
        finally:
            report["model_summary"] = summary(report["results"], "prediction")
            report["baseline_summary"] = summary(report["results"], "baseline")
            save()
    print(json.dumps({"model": report["model_summary"], "baseline": report["baseline_summary"]}, indent=2))


if __name__ == "__main__":
    main()
