#!/usr/bin/env bash
# scripts/example-server.sh
#
# Runnable vehicle for the `openai-compat-server` demo-coverage capability
# (issue #2453, milestone M3). Boots the REAL `manifold-server` executable
# (Server-trait build, real TCP bind, real process) against a real backend
# and drives it with real curl requests — the gap this script closes is that
# Tests/ManifoldServerTests exercises ServerApp's routing/adapter logic only
# through Hummingbird's in-process test client (HummingbirdTesting's
# `app.test(.router)`), never the compiled CLI binary actually listening on a
# socket. See scripts/demo-coverage-manifest.tsv's `openai-compat-server` row
# for how the two lanes divide the evidence.
#
# `manifold-server` has no built-in mock/scripted backend selection — its
# `--backend` flag only accepts mlx/llama/foundation/ollama/cloud (see
# Sources/ManifoldServer/TraitAwareServerBackendProvider.swift), and mlx/llama
# are companion-package-only (unavailable in a core-only build) while cloud is
# unimplemented for v1. So this script prefers a live local Ollama server
# (matches docs/QUICKSTART-SERVER.md's own canonical examples) and fails
# CLOSED with a clear message when Ollama is not reachable, rather than
# silently downgrading to some other behavior.
#
# Verbs:
#   scripts/example-server.sh build   swift build --product ManifoldServer --traits Server
#   scripts/example-server.sh run     boot the built server, wait for readiness,
#                                      curl-verify it end to end, shut it down —
#                                      prints PASS/FAIL per step
#   scripts/example-server.sh all     build, then run
#
# Env overrides:
#   SERVER_HOST            default 127.0.0.1
#   SERVER_PORT            default 8099
#   SERVER_API_KEY         default a fixed local test token (not a secret —
#                           this is a throwaway bearer token for a loopback
#                           process this script itself starts and stops)
#   SERVER_BACKEND         default ollama; the only other supported value
#                           here is foundation (macOS 26+ only)
#   OLLAMA_BASE_URL        default http://localhost:11434
#   SERVER_MODEL           Ollama model name to request; default: the first
#                           model reported by `GET /api/tags`
#   SERVER_CONFIGURATION   swift build configuration: debug (default) or release
#   SERVER_READY_TIMEOUT   seconds to wait for /health before failing closed
#                           (default 30)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SERVER_HOST="${SERVER_HOST:-127.0.0.1}"
SERVER_PORT="${SERVER_PORT:-8099}"
SERVER_API_KEY="${SERVER_API_KEY:-manifold-server-vehicle-local-test-key}"
SERVER_BACKEND="${SERVER_BACKEND:-ollama}"
OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-http://localhost:11434}"
SERVER_MODEL="${SERVER_MODEL:-}"
SERVER_CONFIGURATION="${SERVER_CONFIGURATION:-debug}"
SERVER_READY_TIMEOUT="${SERVER_READY_TIMEOUT:-30}"

BASE_URL="http://${SERVER_HOST}:${SERVER_PORT}"
BIN_PATH="$REPO_ROOT/.build/${SERVER_CONFIGURATION}/ManifoldServer"

STEP_FAILURES=0
SERVER_PID=""
SERVER_LOG=""
SCRATCH_DIR=""
BACKEND_ARGS=()

usage() {
    cat <<'EOF'
Usage:
  scripts/example-server.sh build
  scripts/example-server.sh run
  scripts/example-server.sh all

See the file header for env var overrides (SERVER_HOST, SERVER_PORT,
SERVER_API_KEY, SERVER_BACKEND, OLLAMA_BASE_URL, SERVER_MODEL,
SERVER_CONFIGURATION, SERVER_READY_TIMEOUT).
EOF
}

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; STEP_FAILURES=$((STEP_FAILURES + 1)); }

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "FAIL  required command not found: $1" >&2
        exit 1
    fi
}

cleanup() {
    if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    if [[ -n "$SERVER_LOG" && -f "$SERVER_LOG" ]]; then
        if [[ "$STEP_FAILURES" -ne 0 ]]; then
            echo "---- server log ($SERVER_LOG) ----" >&2
            cat "$SERVER_LOG" >&2
            echo "---- end server log ----" >&2
        fi
    fi
    if [[ -n "$SCRATCH_DIR" && -d "$SCRATCH_DIR" ]]; then
        rm -rf "$SCRATCH_DIR"
    fi
}
trap cleanup EXIT

cmd_build() {
    require_command swift
    echo ">> swift build --product ManifoldServer --traits Server -c $SERVER_CONFIGURATION"
    swift build --product ManifoldServer --traits Server -c "$SERVER_CONFIGURATION"
    if [[ ! -x "$BIN_PATH" ]]; then
        fail "build produced no executable at $BIN_PATH"
        exit 1
    fi
    pass "build ($BIN_PATH)"
}

# Resolves the backend arguments for `manifold-server` into the global
# BACKEND_ARGS array, failing CLOSED with a clear message when the chosen
# backend is not actually reachable — this is the "assertion a dead server
# can't satisfy" for backend selection: a wrong or absent backend must stop
# the script before it ever binds a port, not surface as a confusing curl
# failure five steps later. Called directly (never inside a command/process
# substitution) so `exit 1` here terminates the whole script, not a subshell.
resolve_backend_args() {
    case "$SERVER_BACKEND" in
        ollama)
            local tags
            if ! tags="$(curl -sf -m 5 "${OLLAMA_BASE_URL}/api/tags")"; then
                echo "FAIL  Ollama is not reachable at ${OLLAMA_BASE_URL} — start it with 'ollama serve' (or 'brew services start ollama') and pull a model with 'ollama pull llama3.2', then re-run. manifold-server has no built-in mock backend to fall back to (see docs/QUICKSTART-SERVER.md)." >&2
                exit 1
            fi
            if [[ -z "$SERVER_MODEL" ]]; then
                SERVER_MODEL="$(printf '%s' "$tags" | jq -r '.models[0].name // empty')"
            fi
            if [[ -z "$SERVER_MODEL" ]]; then
                echo "FAIL  Ollama at ${OLLAMA_BASE_URL} has no models pulled — run 'ollama pull llama3.2' and re-run. manifold-server has no built-in mock backend to fall back to." >&2
                exit 1
            fi
            BACKEND_ARGS=(--backend ollama --model "$SERVER_MODEL" --ollama-base-url "$OLLAMA_BASE_URL")
            ;;
        foundation)
            # Fail CLOSED before ever spawning the server, the same way the
            # ollama branch above fails closed when Ollama isn't reachable —
            # without this, an old-OS run would boot fine (buildApp() doesn't
            # load the backend), pass /health, and only surface the real
            # problem as a confusing verify_chat_completion failure several
            # steps later, when TraitAwareServerBackendProvider.loadFoundationBackend()
            # (Sources/ManifoldServer/TraitAwareServerBackendProvider.swift)
            # throws backendUnavailable.
            local macos_major
            macos_major="$(sw_vers -productVersion | cut -d. -f1)"
            if [[ -z "$macos_major" || "$macos_major" -lt 26 ]]; then
                echo "FAIL  --backend foundation requires macOS 26 or later (this Mac reports $(sw_vers -productVersion) via sw_vers) — Apple Foundation Models are OS-provided and unavailable below that floor. Use --backend ollama instead, or re-run on macOS 26+." >&2
                exit 1
            fi
            # SERVER_MODEL is descriptive only for this backend —
            # TraitAwareServerBackendProvider.modelID(for:) ignores the
            # request's `model` field entirely for `.foundation` and always
            # resolves to the OS-provided built-in model
            # (ModelInfo.builtInFoundation.name in
            # Sources/ManifoldModelCatalog/ModelInfo.swift). Setting it here
            # keeps the startup line and the chat-completion request payload
            # from showing a blank `model: ""` for a value nothing server-side
            # actually reads.
            SERVER_MODEL="Apple Foundation Model"
            BACKEND_ARGS=(--backend foundation)
            ;;
        *)
            echo "FAIL  unsupported SERVER_BACKEND '$SERVER_BACKEND' — this vehicle supports ollama or foundation (mlx/llama live in companion packages, cloud is unimplemented for ManifoldServer v1)." >&2
            exit 1
            ;;
    esac
}

# Prints the PID(s) currently listening on SERVER_HOST:SERVER_PORT (TCP), one
# per line, or nothing if the port is free. Host-scoped (`@host:port`, not a
# bare `:port`) so an unrelated listener on a different local address (e.g.
# something bound to `[::1]` or a LAN interface while we only care about
# SERVER_HOST) can't trigger a spurious refusal.
port_listener_pids() {
    # `lsof` is NOT in ScriptFailOpenAuditTest's tolerantCommands list — this
    # `|| true` is approved ONLY by the fail-open-ok marker below, not by any
    # inherent tolerance of lsof's exit code. Don't remove the marker on the
    # assumption lsof is safe by default; it isn't, for this audit.
    lsof -nP -iTCP@"${SERVER_HOST}:${SERVER_PORT}" -sTCP:LISTEN -t 2>/dev/null || true  # fail-open-ok: lsof exits 1 when nothing is listening — that IS "port is free", not a failure; callers read stdout, not the exit status
}

# True iff SERVER_PID is among the port's current listener(s). Used both
# before we start (must be empty) and once /health answers (must contain our
# own PID) — see the port-ownership comment on `wait_for_ready` below.
port_is_owned_by_server_pid() {
    local pids
    pids="$(port_listener_pids)"
    [[ -n "$pids" ]] || return 1
    printf '%s\n' "$pids" | grep -qx "$SERVER_PID"
}

# `wait_for_ready`'s original two checks (kill -0, then curl /health) were
# two UNRELATED facts about two different things — a live PID and an HTTP
# response — with nothing binding the socket being probed to the process
# under test. `buildApp()` doesn't load the backend, so our own bind happens
# strictly after fork while the very first poll can land at t≈0; if anything
# was already listening on SERVER_PORT (a stale process from a prior crashed
# run, a stray dev server, anything), IT answers /health first and gets
# silently adopted as "the server" — every verify_* check below then runs
# against a foreign process, and RESULT: PASS prints having never touched our
# binary.
#
# `port_is_owned_by_server_pid` below is what ACTUALLY closes this — it
# demands a POSITIVE match (our own PID among the port's listener(s)), so
# every degradation mode fails closed: lsof blind, lsof erroring, an empty
# listener list, all read as "not owned", never "owned by default". And a
# foreign process can only answer `curl` on SERVER_HOST:SERVER_PORT by
# genuinely holding that exact address, which means OUR bind failed — so
# either `kill -0` catches our own process having exited, or the PID match
# here catches it if it's still limping along. Do not weaken this to an
# absence check ("nothing else is listening") — that's the polarity that
# created the original bug.
#
# cmd_run's pre-spawn port-busy refusal (below, before this function runs) is
# NOT a second independent safety mechanism — it's a better error message.
# Refusing before we ever fork tells the operator "port 8099 is occupied by
# PID X, go deal with it" instead of a generic ownership-mismatch failure
# after a wasted SERVER_READY_TIMEOUT-second wait. The actual guarantee lives
# here, in the positive-match check.
wait_for_ready() {
    local waited=0
    while (( waited < SERVER_READY_TIMEOUT )); do
        if kill -0 "$SERVER_PID" 2>/dev/null; then
            if curl -sf -m 2 "${BASE_URL}/health" >/dev/null 2>&1; then
                if ! port_is_owned_by_server_pid; then
                    fail "something on ${BASE_URL} answered /health, but its listener PID does not match our own server (PID ${SERVER_PID}) — refusing to trust a foreign process"
                    return 1
                fi
                pass "server ready at ${BASE_URL} (${waited}s), listener PID confirmed == ${SERVER_PID}"
                return 0
            fi
        else
            fail "server process exited before becoming ready — see log below"
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
    fail "server did not become ready within ${SERVER_READY_TIMEOUT}s"
    return 1
}

# Each check below asserts a shape a dead/inert server cannot satisfy: a
# non-2xx status fails the jq -e pipeline outright (bad JSON or wrong status
# never parses as the expected object), and every positive assertion pins a
# specific non-empty field from a real generation or a real auth decision —
# not just "the process returned bytes".
# Every curl call below is guarded with `if ! status=$(...)`, never a bare
# assignment — under `set -e` a bare `status="$(curl ...)"` would abort the
# whole script the instant curl hits a network-level failure (connection
# reset, server crash mid-run), skipping straight past `fail()` with no
# PASS/FAIL line at all. Guarding keeps every failure mode — HTTP-level and
# network-level alike — reported the same way.
verify_health_open() {
    local body status
    if ! status="$(curl -s -o "$SCRATCH_DIR/health.json" -w '%{http_code}' -m 5 "${BASE_URL}/health")"; then
        fail "GET /health: curl could not complete the request (server crashed or unreachable)"
        return
    fi
    body="$(cat "$SCRATCH_DIR/health.json")"
    if [[ "$status" != "200" ]]; then
        fail "GET /health returned $status, expected 200 (body: $body)"
        return
    fi
    if echo "$body" | jq -e '.status == "ok"' >/dev/null 2>&1; then
        pass "GET /health -> 200 {status: ok} (unauthenticated, as documented)"
    else
        fail "GET /health body did not match {status: ok}: $body"
    fi
}

verify_models_requires_auth() {
    local status
    if ! status="$(curl -s -o /dev/null -w '%{http_code}' -m 5 "${BASE_URL}/v1/models")"; then
        fail "GET /v1/models (no auth): curl could not complete the request"
        return
    fi
    if [[ "$status" == "401" ]]; then
        pass "GET /v1/models without a bearer token -> 401 (auth is actually enforced)"
    else
        fail "GET /v1/models without a bearer token returned $status, expected 401"
    fi
}

# NOT backend evidence — narrower than it looks. `GET /v1/models` is served
# by `ServerApp` calling `backendProvider.listModelRecords()`
# (Sources/ManifoldServer/ServerApp.swift), which for
# `TraitAwareServerBackendProvider` delegates straight to its own
# `listModels()` (Sources/ManifoldServer/TraitAwareServerBackendProvider.swift)
# — and THAT never contacts Ollama for the `ollama` backend selection: it
# returns `[selection.model ?? APIProvider.ollama.defaultModelName]` —
# literally the `--model` flag this script itself passed in, echoed back
# through one hop of delegation. A 200 here proves
# the route, the response envelope shape, and that auth is wired correctly
# (paired with verify_models_requires_auth's 401 check) — it does NOT prove
# Ollama was ever reached. `verify_chat_completion` below is the one check
# that actually round-trips through a real backend (it calls `backend(for:)`,
# which loads and generates against Ollama for real).
verify_models_list() {
    local body status
    if ! status="$(curl -s -o "$SCRATCH_DIR/models.json" -w '%{http_code}' -m 5 \
        -H "Authorization: Bearer ${SERVER_API_KEY}" "${BASE_URL}/v1/models")"; then
        fail "GET /v1/models: curl could not complete the request"
        return
    fi
    body="$(cat "$SCRATCH_DIR/models.json")"
    if [[ "$status" != "200" ]]; then
        fail "GET /v1/models returned $status, expected 200 (body: $body)"
        return
    fi
    if echo "$body" | jq -e '.object == "list" and (.data | length) > 0 and (.data[0].id | length) > 0' >/dev/null 2>&1; then
        local model_id
        model_id="$(echo "$body" | jq -r '.data[0].id')"
        pass "GET /v1/models -> 200 {object: list, data: [$model_id, ...]}"
    else
        fail "GET /v1/models body did not match the expected non-empty model list: $body"
    fi
}

verify_chat_completion() {
    local request body status
    request="$(jq -n --arg model "$SERVER_MODEL" '{
        model: $model,
        messages: [{role: "user", content: "Reply with exactly one word: OK"}],
        stream: false,
        max_tokens: 32
    }')"
    if ! status="$(curl -s -o "$SCRATCH_DIR/chat.json" -w '%{http_code}' -m 120 \
        -H "Authorization: Bearer ${SERVER_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$request" \
        "${BASE_URL}/v1/chat/completions")"; then
        fail "POST /v1/chat/completions: curl could not complete the request"
        return
    fi
    body="$(cat "$SCRATCH_DIR/chat.json")"
    if [[ "$status" != "200" ]]; then
        fail "POST /v1/chat/completions returned $status, expected 200 (body: $body)"
        return
    fi
    if echo "$body" | jq -e '
        .object == "chat.completion"
        and (.choices | length) > 0
        and (.choices[0].message.role == "assistant")
        and (.choices[0].message.content | length) > 0
        and (.choices[0].finish_reason | length) > 0
        and (.usage.completion_tokens // 0) > 0
    ' >/dev/null 2>&1; then
        local content
        content="$(echo "$body" | jq -r '.choices[0].message.content')"
        pass "POST /v1/chat/completions -> 200 non-empty completion from a real backend: \"$content\""
    else
        fail "POST /v1/chat/completions body did not match a well-formed completion: $body"
    fi
}

cmd_run() {
    require_command curl
    require_command jq
    require_command lsof

    if [[ ! -x "$BIN_PATH" ]]; then
        echo "FAIL  no built server at $BIN_PATH — run 'scripts/example-server.sh build' first (or use the 'all' verb)." >&2
        exit 1
    fi

    # A better ERROR MESSAGE, not the safety property — see
    # port_is_owned_by_server_pid's comment above `wait_for_ready` for what
    # actually closes the false-adoption defect (the positive-PID-match
    # check, which holds even if this pre-check somehow missed something).
    # Checked before we ever spawn our own process purely so a stale/foreign
    # listener fails loud and immediately, naming the offending PID, instead
    # of producing a generic ownership-mismatch failure after a wasted
    # SERVER_READY_TIMEOUT-second wait.
    local pre_existing_pids
    pre_existing_pids="$(port_listener_pids)"
    if [[ -n "$pre_existing_pids" ]]; then
        echo "FAIL  ${SERVER_HOST}:${SERVER_PORT} is already in use (listener PID(s): $(printf '%s' "$pre_existing_pids" | tr '\n' ' ')) — refusing to start so this vehicle can't silently adopt a foreign process as \"the server\". Free the port (e.g. kill the listed PID) or set SERVER_PORT to something else and re-run." >&2
        exit 1
    fi

    SCRATCH_DIR="$(mktemp -d -t manifold-server-vehicle)"
    resolve_backend_args

    SERVER_LOG="$SCRATCH_DIR/server.log"
    echo ">> starting manifold-server on ${BASE_URL} (backend: ${SERVER_BACKEND}${SERVER_MODEL:+, model: $SERVER_MODEL})"
    # LOAD-BEARING ASSUMPTION for the port-ownership check below: `$!` is the
    # PID bash just forked, and the ownership guard only works if THAT
    # process is the one that binds the socket — i.e. `$BIN_PATH` execs
    # directly rather than forking a grandchild that does the real work
    # (a launcher/wrapper shape). True for `ManifoldServer` today (a single
    # process, no re-exec). If this ever becomes a forking launcher, the
    # ownership check would need to walk the process's descendants rather
    # than compare `$SERVER_PID` directly against `port_listener_pids`'
    # output, or it would silently stop verifying anything.
    "$BIN_PATH" \
        --host "$SERVER_HOST" \
        --port "$SERVER_PORT" \
        --api-key "$SERVER_API_KEY" \
        "${BACKEND_ARGS[@]}" \
        >"$SERVER_LOG" 2>&1 &
    SERVER_PID=$!

    if ! wait_for_ready; then
        exit 1
    fi

    verify_health_open
    verify_models_requires_auth
    verify_models_list
    verify_chat_completion

    # Same "silently skipped, not verified" hazard as wait_for_ready above: a
    # server that already died before we got here must FAIL this step, not
    # slide past it — `pass "clean shutdown"` was previously nested inside
    # `kill -0`, so a dead server made the whole if-block a no-op and
    # RESULT: PASS still printed with STEP_FAILURES untouched.
    if [[ -n "$SERVER_PID" ]]; then
        if kill -0 "$SERVER_PID" 2>/dev/null; then
            kill "$SERVER_PID" 2>/dev/null || true
            wait "$SERVER_PID" 2>/dev/null || true
            pass "clean shutdown"
        else
            fail "server process (PID $SERVER_PID) was already dead before shutdown — it did not survive the verification steps"
        fi
        SERVER_PID=""
    fi

    echo ""
    if [[ "$STEP_FAILURES" -eq 0 ]]; then
        echo "RESULT: PASS — manifold-server served real ${SERVER_BACKEND} traffic end to end at ${BASE_URL}"
        exit 0
    else
        echo "RESULT: FAIL — $STEP_FAILURES step(s) failed"
        exit 1
    fi
}

if [[ $# -eq 0 ]]; then
    usage
    exit 1
fi

case "$1" in
    build)
        cmd_build
        ;;
    run)
        cmd_run
        ;;
    all)
        cmd_build
        cmd_run
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage
        exit 1
        ;;
esac
