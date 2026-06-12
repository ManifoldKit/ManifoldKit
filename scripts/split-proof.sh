#!/usr/bin/env bash
# split-proof.sh — B5 out-of-package compile proof for the companion-package
# split (#1749, v0.48 plan §3 B3 / §5 go/no-go). RETIRED at C2.
#
# Pre-C2 this script copied the ManifoldMLX / ManifoldLlama family sources
# (plus vendored FluxSwift / StableDiffusion) into scratch SwiftPM packages,
# stripped the `#if Llama` / `#if MLX` / `#if HuggingFace` trait gates, and
# proved the families compiled and passed their contract suites OUTSIDE this
# package against core's published products. That proof gated the C-stream
# cutover and was last run green at C1.
#
# v0.48 PR C2 deleted the family sources from this repository — they now live
# in the companion packages:
#   https://github.com/roryford/manifold-mlx
#   https://github.com/roryford/manifold-llama
#
# There is nothing left in this repo to copy, so the proof can no longer run
# here. The live equivalent is the companion repos' own CI, which builds the
# real (un-renamed) targets against core's published products on every push.
#
# Kept as a stub (exit 0) rather than deleted so historical references to the
# B3 gate keep resolving; see git history for the full implementation.
set -euo pipefail

echo "split-proof.sh: RETIRED — the B3 out-of-package proof completed pre-C2."
echo "The MLX/Llama family sources were moved to the companion packages"
echo "(manifold-mlx / manifold-llama) in v0.48 PR C2; their CI is the live"
echo "equivalent of this proof. Nothing to do here."
exit 0
