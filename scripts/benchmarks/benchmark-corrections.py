#!/usr/bin/env python3
"""Compare local MLX correction proposals with the production GGUF helper.

Synthetic inputs only. No microphone, app settings, clipboard, or saved history.
Fetch is explicit; run uses local files with Hugging Face offline mode enforced.
"""

import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import selectors
import statistics
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from cleanup_prompt import add_prompt_arguments, load_cleanup_prompt

CACHE = ROOT / ".build/benchmarks"
os.environ.setdefault("HF_HOME", str(CACHE / "hf"))
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
os.environ["HF_HUB_DISABLE_IMPLICIT_TOKEN"] = "1"
os.environ["TOKENIZERS_PARALLELISM"] = "false"


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")
    temporary.replace(path)


def fetch(repo, revision):
    from huggingface_hub import HfApi, snapshot_download
    info = HfApi().model_info(repo, revision=revision, files_metadata=True)
    path = snapshot_download(repo, revision=info.sha, max_workers=4, allow_patterns=[
        "*.json", "*.safetensors", "*.model", "*.jinja", "*.txt", "README.md", "LICENSE*", "NOTICE*",
    ])
    manifest = dict(id=repo, revision=info.sha, path=str(Path(path).resolve()),
                    weightBytes=sum(f.size or 0 for f in info.siblings if f.rfilename.endswith(".safetensors")),
                    license=(info.card_data or {}).get("license"))
    destination = CACHE / (repo.split("/")[-1] + ".json")
    write_json(destination, manifest)
    print(destination, flush=True)


class RSSSampler:
    """Same sampled process-RSS metric for MLX Python and the GGUF child."""
    def __init__(self, pid):
        import psutil
        self.process = psutil.Process(pid)
        self.peak = 0
        self.done = threading.Event()
        self.thread = threading.Thread(target=self.sample, daemon=True)
        self.thread.start()

    def sample(self):
        import psutil
        while not self.done.is_set():
            try:
                self.peak = max(self.peak, self.process.memory_info().rss)
            except psutil.NoSuchProcess:
                break
            self.done.wait(0.02)

    def close(self):
        self.done.set()
        self.thread.join()


class MLXEngine:
    def __init__(self, path):
        import mlx.core as mx
        from mlx_lm import load
        self.mx = mx
        if not mx.metal.is_available():
            raise RuntimeError("MLX Metal GPU is unavailable; do not benchmark a CPU fallback")
        self.memory = RSSSampler(os.getpid())
        mx.reset_peak_memory()
        start = time.perf_counter()
        self.model, self.tokenizer = load(str(path), tokenizer_config={"trust_remote_code": False})
        mx.synchronize()
        self.load_seconds = time.perf_counter() - start
        self.versions = {name: importlib.metadata.version(name) for name in ["mlx", "mlx-lm", "transformers"]}
        # Literal role markers in user data must not become chat control tokens.
        tokenizer = self.tokenizer
        marker = next((t for t in tokenizer.all_special_tokens if len(t) > 3), None)
        if marker:
            safe = tokenizer.encode(marker, add_special_tokens=False, split_special_tokens=True)
            if tokenizer.convert_tokens_to_ids(marker) in safe:
                raise RuntimeError("Tokenizer cannot encode user data without special-token interpretation")

    def correct(self, case, prompt):
        from mlx_lm import stream_generate
        from mlx_lm.sample_utils import make_sampler
        start = time.perf_counter()
        system_slot = "SOTTO_BENCHMARK_SYSTEM_70ecdeff"
        payload_slot = "SOTTO_BENCHMARK_PAYLOAD_a5d3b912"
        template = self.tokenizer.apply_chat_template(
            [{"role": "system", "content": system_slot}, {"role": "user", "content": payload_slot}],
            tokenize=False, add_generation_prompt=True, enable_thinking=False,
        )
        if template.count(system_slot) != 1 or template.count(payload_slot) != 1:
            raise RuntimeError("Chat template did not preserve the benchmark content slots")
        prefix, remaining = template.split(system_slot)
        if payload_slot not in remaining:
            raise RuntimeError("Chat template put the user payload before its system prompt")
        middle, suffix = remaining.split(payload_slot)
        payload = json.dumps(dict(transcript=case["input"], preferredTerms=case["terms"], language="en"),
                             ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        tokens = self.tokenizer.encode(prefix, add_special_tokens=False, split_special_tokens=False)
        tokens += self.tokenizer.encode(prompt, add_special_tokens=False, split_special_tokens=True)
        tokens += self.tokenizer.encode(middle, add_special_tokens=False, split_special_tokens=False)
        tokens += self.tokenizer.encode(payload, add_special_tokens=False, split_special_tokens=True)
        tokens += self.tokenizer.encode(suffix, add_special_tokens=False, split_special_tokens=False)
        if len(tokens) + 2048 > 8192:
            raise ValueError("Cleanup prompt, transcript, dictionary, and output exceed the production context budget")
        chunks, first, last = [], None, None
        for response in stream_generate(self.model, self.tokenizer, tokens, max_tokens=2048,
                                        sampler=make_sampler(temp=0), prefill_step_size=512):
            if first is None:
                first = time.perf_counter() - start
            last = response
            chunks.append(response.text)
            if time.perf_counter() - start > 15:
                raise TimeoutError("Correction exceeded the production 15-second limit")
        self.mx.synchronize()
        if last is None or last.finish_reason != "stop":
            raise RuntimeError("The correction did not reach an end-of-sequence token")
        return dict(text="".join(chunks).strip(), seconds=time.perf_counter() - start,
                    firstTokenSeconds=first, promptTokens=last.prompt_tokens,
                    outputTokens=last.generation_tokens, generationTPS=last.generation_tps,
                    peakMLXBytes=self.mx.get_peak_memory())

    def close(self):
        self.memory.close()


class GGUFEngine:
    def __init__(self, path, helper):
        self.diagnostics = tempfile.TemporaryFile(mode="w+")
        start = time.perf_counter()
        self.process = subprocess.Popen([str(helper), "--model", str(path), "--threads", "6"],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.diagnostics, text=True, bufsize=1)
        self.memory = RSSSampler(self.process.pid)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        try:
            ready = self.receive(45)
            if ready["type"] != "ready":
                raise RuntimeError(str(ready))
            self.load_seconds = time.perf_counter() - start
            self.versions = {"engine": ready["engineVersion"]}
        except Exception:
            self.close()
            raise

    def receive(self, seconds):
        if not self.selector.select(seconds):
            raise TimeoutError("GGUF helper response timed out")
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError("GGUF helper exited without a result")
        return json.loads(line)

    def correct(self, case, prompt):
        start = time.perf_counter()
        self.process.stdin.write(json.dumps(dict(type="correct", id=case["id"], text=case["input"],
                                                terms=case["terms"], language="en", systemPrompt=prompt)) + "\n")
        self.process.stdin.flush()
        result = self.receive(20)
        if result["type"] != "result":
            raise RuntimeError(str(result))
        return dict(text=result["text"], seconds=time.perf_counter() - start,
                    engineSeconds=result["elapsed"])

    def close(self):
        self.memory.close()
        self.selector.close()
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.process.stdout.close()
        self.diagnostics.close()


def score(case, text):
    return dict(exactMatch=text.strip() in case["expected"],
                missingRequired=[s for s in case["required"] if s not in text],
                foundForbidden=[s for s in case["forbidden"] if s in text])


def run(args):
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    cases = json.loads(args.cases.read_text())["cases"]
    prompt = load_cleanup_prompt(args)
    manifest = json.loads(args.model.read_text()) if args.backend == "mlx" else dict(
        id="Qwen3-4B-Instruct-2507-Q4_K_M", path=str(args.model), weightBytes=args.model.stat().st_size)
    path = Path(manifest["path"])
    if not path.exists():
        raise FileNotFoundError(path)
    result = dict(schemaVersion=1, backend=args.backend, model=manifest,
                  python=platform.python_version(), macOS=platform.mac_ver()[0],
                  timestamp=time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                  promptSHA256=hashlib.sha256(prompt.encode()).hexdigest(),
                  promptSource=str(args.prompt) if args.prompt else str(args.server) + ":--print-default-proofreading-prompt",
                  casesSHA256=hashlib.sha256(args.cases.read_bytes()).hexdigest(),
                  repeats=args.repeats, promptCache=False, thinking=False, temperature=0,
                  measurements=[])
    engine = None
    try:
        engine = MLXEngine(path) if args.backend == "mlx" else GGUFEngine(path, args.helper)
        result.update(loadSeconds=engine.load_seconds, versions=engine.versions)
        print(f"Loaded {manifest['id']} in {engine.load_seconds:.3f}s", flush=True)
        # Separately report first request, including lazy kernel compilation;
        # it is not included in the warmed benchmark median.
        result["firstRequest"] = engine.correct(dict(id="warmup", input="The microphone is ready.", terms=[]), prompt)
        for repeat in range(args.repeats):
            for case in cases:
                row = dict(caseID=case["id"], category=case["category"], repeat=repeat)
                try:
                    row.update(engine.correct(case, prompt))
                    row.update(score(case, row["text"]))
                except Exception as error:
                    row.update(error=f"{type(error).__name__}: {error}", exactMatch=False)
                result["measurements"].append(row)
            write_json(args.output, result)
            print(f"{manifest['id']}: pass {repeat + 1}/{args.repeats} complete", flush=True)
        lookup = {case["id"]: case for case in cases}
        valid = [r for r in result["measurements"] if "text" in r]
        if valid:
            requests = [json.dumps(dict(original=lookup[r["caseID"]]["input"], candidate=r["text"],
                                       terms=lookup[r["caseID"]]["terms"])) for r in valid]
            graded = subprocess.run([str(args.grader)], input="\n".join(requests) + "\n",
                                    capture_output=True, text=True, check=True)
            grades = [json.loads(line) for line in graded.stdout.splitlines()]
            if len(grades) != len(valid):
                raise RuntimeError("Policy grader result count mismatch")
            for row, grade in zip(valid, grades):
                row["policy"] = grade
            times = sorted(r["seconds"] for r in valid)
            result["summary"] = dict(medianSeconds=statistics.median(times),
                p95Seconds=times[min(len(times)-1, int(len(times)*0.95))],
                exactMatches=sum(r["exactMatch"] for r in valid),
                constraintsPassed=sum(not r["missingRequired"] and not r["foundForbidden"] for r in valid),
                policyAccepted=sum(r["policy"]["accepted"] for r in valid),
                successfulRequests=len(valid), totalRequests=len(result["measurements"]),
                sampledPeakRSSBytes=engine.memory.peak)
            print(json.dumps(result["summary"]), flush=True)
    except Exception as error:
        result["error"] = f"{type(error).__name__}: {error}"
        raise
    finally:
        if engine is not None:
            engine.close()
        write_json(args.output, result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    download = sub.add_parser("fetch")
    download.add_argument("repo")
    download.add_argument("--revision", required=True)
    bench = sub.add_parser("run")
    bench.add_argument("--backend", choices=["mlx", "gguf"], required=True)
    bench.add_argument("--model", type=Path, required=True, help="MLX download manifest or GGUF file")
    bench.add_argument("--output", type=Path, required=True)
    bench.add_argument("--repeats", type=int, default=3)
    add_prompt_arguments(bench)
    bench.add_argument("--cases", type=Path, default=Path(__file__).with_name("correction-cases.json"))
    bench.add_argument("--grader", type=Path, default=CACHE / "grade-corrections")
    bench.add_argument("--helper", type=Path, default=ROOT / ".build/server-llama/sotto-text-engine")
    args = parser.parse_args()
    if args.command == "fetch":
        fetch(args.repo, args.revision)
    elif args.repeats < 1:
        parser.error("--repeats must be positive")
    else:
        run(args)


if __name__ == "__main__":
    main()
