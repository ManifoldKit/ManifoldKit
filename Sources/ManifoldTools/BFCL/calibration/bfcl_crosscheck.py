#!/usr/bin/env python3
"""One-time, LOCAL calibration: cross-check ManifoldKit's Swift ``ASTMatcher``
against canonical ``bfcl-eval`` on the SAME decoded model outputs.

This is NOT wired into CI or the Swift build (see Package.swift `exclude`). It
exists so the spike's load-bearing claim — that the argument-level score is
faithful to canonical BFCL, not an artifact of our matcher's strictness — is
reproducible. See README.md in this directory for setup and the recorded result.

Inputs:
  --dump      JSONL from `manifold-tools bfcl --dump` (decoded calls + our verdict)
  --questions vendored BFCL <cat>_questions.jsonl (func_description, verbatim)
  --answers   vendored BFCL <cat>_answers.jsonl  (ground_truth, verbatim)

We feed canonical `ast_checker` the calls our matcher already decoded, so any
disagreement isolates *matcher strictness*, not parser differences.
"""
import argparse, json
from bfcl_eval.eval_checker.ast_eval.ast_checker import ast_checker

# A model config whose function names keep dots (underscore_to_dot=False), matching
# our Ollama backend which emits the schema's dotted names verbatim.
MODEL_NAME = "gorilla-openfunctions-v2"
LANGUAGE = "Python"
CATEGORY = "multiple"


def load_jsonl(path):
    out = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                rec = json.loads(line)
                out[rec["id"]] = rec
    return out


def canonical_valid(question, answer, dump_rec):
    """Run canonical ast_checker on our decoded calls; return (valid, detail)."""
    model_output = []
    for call in dump_rec["decoded"]:
        args = call["args"]
        if not isinstance(args, dict):
            # Non-object payload — the checker can't .items() a non-dict; true fail.
            return False, f"non-dict args: {args!r}"
        model_output.append({call["name"]: args})
    try:
        res = ast_checker(
            question["function"], model_output, answer["ground_truth"],
            LANGUAGE, CATEGORY, MODEL_NAME,
        )
        if res.get("valid"):
            return True, ""
        return False, res.get("error_type") or (res.get("error") or [""])[0]
    except Exception as e:  # noqa: BLE001 — calibration tool, surface any failure
        return None, f"{type(e).__name__}: {e}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dump", required=True)
    ap.add_argument("--questions", required=True)
    ap.add_argument("--answers", required=True)
    args = ap.parse_args()

    dump = load_jsonl(args.dump)
    questions = load_jsonl(args.questions)
    answers = load_jsonl(args.answers)

    agree_pass = agree_fail = we_stricter = we_looser = errored = 0
    stricter_ids, looser_ids, error_ids = [], [], []

    for cid in sorted(dump, key=lambda s: (len(s), s)):
        rec = dump[cid]
        ours = bool(rec["ast_matched"])
        q, a = questions.get(cid), answers.get(cid)
        if q is None or a is None:
            print(f"  ! {cid}: missing question/answer in vendored fixtures")
            continue
        canon, detail = canonical_valid(q, a, rec)
        if canon is None:
            errored += 1
            error_ids.append((cid, detail))
            mark = "ERR"
        elif canon == ours:
            mark = "=="
            agree_pass += ours
            agree_fail += (not ours)
        elif ours and not canon:
            we_looser += 1
            looser_ids.append((cid, detail))
            mark = "WE-LOOSER"
        else:
            we_stricter += 1
            stricter_ids.append((cid, detail))
            mark = "WE-STRICTER"
        print(f"  {mark:12} {cid:14} ours={ours!s:5} canonical={canon!s:5}  {detail}")

    total = len(dump)
    print("\n  ── summary ──")
    print(f"  cases:            {total}")
    # ours passed = agreed-pass + (ours pass, canon fail); canon passed = agreed-pass
    # + (ours fail, canon pass). Keep these straight — they invert.
    print(f"  ours  AST pass:   {agree_pass + we_looser}/{total}")
    print(f"  canon AST pass:   {agree_pass + we_stricter}/{total}  (errored: {errored})")
    print(f"  agree pass:       {agree_pass}")
    print(f"  agree fail:       {agree_fail}")
    print(f"  WE STRICTER:      {we_stricter}  {[c for c, _ in stricter_ids]}")
    print(f"  WE LOOSER:        {we_looser}  {[c for c, _ in looser_ids]}")
    if errored:
        print(f"  ERRORED:          {errored}  {[c for c, _ in error_ids]}")
    if stricter_ids:
        print("\n  canonical PASSES but we FAIL (matcher over-strictness):")
        for cid, detail in stricter_ids:
            print(f"    {cid}: {detail}")


if __name__ == "__main__":
    main()
