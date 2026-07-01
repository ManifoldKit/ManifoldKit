#!/usr/bin/env bash
# Cold-start conformance — tier 2: ManifoldBootstrap -> ChatViewModel.
#
# Thin wrapper. The actual gate lives in scripts/cold-start.sh (the
# consolidated tier 1-3 + specialised-module runner) — kept as a separate
# entry point so CI workflows (ci.yml, nightly-slow-tests.yml) and their
# paths-filters ("scripts/cold-start-tier2-bootstrap.sh") keep working
# unchanged. See scripts/README.md for the full inventory and
# scripts/cold-start.sh's header for what tier 2 actually exercises.
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cold-start.sh" --tier 2
