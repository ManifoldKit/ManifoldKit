#!/usr/bin/env python3
"""
ManifoldKit HTTP backend benchmark client.

Measures TTFT and throughput for any OpenAI-compatible or Ollama-native
streaming endpoint. Token count is derived by counting SSE content chunks
(each chunk == 1 token for llama.cpp/Ollama-backed servers).

Usage:
    # OpenAI-compat endpoint (ManifoldKit server, Ollama /v1/):
    python3 http-bench.py --url http://localhost:8080/v1/chat/completions \
        --model llama3.1:8b --runs 4

    # Ollama native endpoint:
    python3 http-bench.py --url http://localhost:11434/api/generate \
        --model llama3.1:8b --mode ollama --runs 4

    # Print as Markdown row (for benchmark.sh table assembly):
    python3 http-bench.py ... --label "Raw Ollama" --markdown
"""

import argparse
import json
import statistics
import time
import urllib.request

PROMPT = "Write a short story about a robot learning to paint. Be concise."
MAX_TOKENS = 300


def bench_openai(url: str, model: str, runs: int) -> list[dict]:
    results = []

    def run_once() -> tuple[float, float, int]:
        payload = json.dumps({
            "model": model,
            "messages": [{"role": "user", "content": PROMPT}],
            "stream": True,
            "max_tokens": MAX_TOKENS,
        }).encode()
        req = urllib.request.Request(
            url, data=payload, headers={"Content-Type": "application/json"}
        )
        t_start = time.perf_counter()
        t_first = None
        token_count = 0
        with urllib.request.urlopen(req, timeout=180) as resp:
            for raw in resp:
                line = raw.strip()
                if not line or line == b"data: [DONE]":
                    continue
                if line.startswith(b"data: "):
                    try:
                        chunk = json.loads(line[6:])
                        content = (
                            chunk.get("choices", [{}])[0]
                            .get("delta", {})
                            .get("content", "")
                        )
                        if content:
                            if t_first is None:
                                t_first = time.perf_counter()
                            token_count += 1  # 1 SSE chunk == 1 token
                    except (json.JSONDecodeError, IndexError, KeyError):
                        continue
        t_end = time.perf_counter()
        return (t_first - t_start) if t_first else 0.0, t_end - t_start, token_count

    # Warmup
    run_once()

    for _ in range(runs):
        ttft, total, tokens = run_once()
        results.append({"ttft_ms": ttft * 1000, "total_ms": total * 1000, "tokens": tokens})

    return results


def bench_ollama(url: str, model: str, runs: int) -> list[dict]:
    results = []

    def run_once() -> tuple[float, float, int]:
        payload = json.dumps({"model": model, "prompt": PROMPT, "stream": True}).encode()
        req = urllib.request.Request(
            url, data=payload, headers={"Content-Type": "application/json"}
        )
        t_start = time.perf_counter()
        t_first = None
        t_end = t_start  # fallback if stream is empty
        eval_count = 0
        with urllib.request.urlopen(req, timeout=180) as resp:
            for raw in resp:
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    data = json.loads(raw)
                    if data.get("response"):
                        if t_first is None:
                            t_first = time.perf_counter()
                    if data.get("done"):
                        t_end = time.perf_counter()
                        eval_count = data.get("eval_count", 0)
                except json.JSONDecodeError:
                    continue
        return (t_first - t_start) if t_first else 0.0, t_end - t_start, eval_count

    # Warmup
    run_once()

    for _ in range(runs):
        ttft, total, tokens = run_once()
        results.append({"ttft_ms": ttft * 1000, "total_ms": total * 1000, "tokens": tokens})

    return results


def summarize(results: list[dict]) -> dict:
    ttfts = [r["ttft_ms"] for r in results]
    tpss = [r["tokens"] / (r["total_ms"] / 1000) for r in results]
    return {
        "median_ttft_ms": statistics.median(ttfts),
        "median_tps": statistics.median(tpss),
        "runs": len(results),
    }


def main():
    p = argparse.ArgumentParser(description="ManifoldKit HTTP benchmark client")
    p.add_argument("--url", required=True, help="Endpoint URL")
    p.add_argument("--model", required=True, help="Model name/id")
    p.add_argument("--mode", choices=["openai", "ollama"], default="openai",
                   help="API format (default: openai)")
    p.add_argument("--runs", type=int, default=4, help="Timed runs after warmup")
    p.add_argument("--label", default="", help="Row label for --markdown output")
    p.add_argument("--markdown", action="store_true",
                   help="Print a single Markdown table row instead of verbose output")
    args = p.parse_args()

    bench_fn = bench_ollama if args.mode == "ollama" else bench_openai
    results = bench_fn(args.url, args.model, args.runs)
    s = summarize(results)

    if args.markdown:
        label = args.label or args.url
        print(f"| {label} | {s['median_ttft_ms']:.0f} ms | {s['median_tps']:.1f} tok/s | {args.model} |")
    else:
        print(f"median TTFT : {s['median_ttft_ms']:.0f} ms")
        print(f"median TPS  : {s['median_tps']:.1f} tok/s")
        print(f"runs        : {s['runs']}")
        for i, r in enumerate(results, 1):
            tps = r["tokens"] / (r["total_ms"] / 1000)
            print(f"  run {i}: TTFT={r['ttft_ms']:.0f}ms  "
                  f"total={r['total_ms']:.0f}ms  tokens={r['tokens']}  TPS={tps:.1f}")


if __name__ == "__main__":
    main()
