#!/usr/bin/env bash
# Cold-start conformance — tier 1: public consumer surface.
#
# Thin wrapper. The actual gate lives in scripts/cold-start.sh (the
# consolidated tier 1-3 + specialised-module runner) — kept as a separate
# entry point so CI workflows (ci.yml, nightly-slow-tests.yml) and their
# paths-filters ("scripts/cold-start-conformance.sh") keep working unchanged.
# See scripts/README.md for the full inventory and scripts/cold-start.sh's
# header for what tier 1 actually exercises.
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cold-start.sh" --tier 1
