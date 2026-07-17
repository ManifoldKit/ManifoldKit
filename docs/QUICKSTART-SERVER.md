# manifold-server Quickstart

**Audience:** consumer
**Status:** living

`manifold-server` is an OpenAI-compatible HTTP server built on top of ManifoldKit. Point Cursor, Continue, LangChain, or any OpenAI SDK at `http://127.0.0.1:8080/v1` and use local or cloud-backed models without changing your tooling.

Endpoints: `POST /v1/chat/completions` (streaming + non-streaming), `GET /v1/models`, `POST /v1/embeddings`, `GET /health`, `GET /metrics`.

**`POST /v1/embeddings` has no working backend out of the box.** None of the built-in `--backend` selections (`foundation`, `ollama`, `mlx`, `llama`, `cloud`) currently vend an `EmbeddingBackend`, so the endpoint always returns 503. To serve embeddings, embed `ManifoldServer` in a host app and supply a custom `ServerBackendProvider` that overrides `embeddingBackend(for:)` — for example with the [manifold-llama](https://github.com/ManifoldKit/manifold-llama) companion package's `LlamaEmbeddingBackend`.

---

## Install via Homebrew

```bash
brew tap manifoldkit/manifoldkit https://github.com/ManifoldKit/ManifoldKit.git
brew install manifold-server
```

The formula builds from source. Since v0.48 core ManifoldKit has no heavy ML binary dependencies (the llama.cpp xcframework moved to the manifold-llama companion package), so a cold build is dominated by compiling the Swift sources plus the Hummingbird dependency tree. Subsequent installs reuse the SwiftPM cache and are faster.

### Alternative: download a pre-built binary

Each GitHub release includes a pre-built tar for Apple Silicon:

```bash
# Replace TAG with the latest release tag, e.g. v0.46.0
TAG=v0.46.0
curl -L "https://github.com/ManifoldKit/ManifoldKit/releases/download/${TAG}/manifold-server-${TAG}-macos-arm64.tar.gz" \
  | tar -xz -C /usr/local/bin
```

The binary is **unsigned and unnotarized**. If macOS quarantines it:

```bash
xattr -dr com.apple.quarantine /usr/local/bin/manifold-server
```

---

## Build from source (SwiftPM)

```bash
git clone https://github.com/ManifoldKit/ManifoldKit.git
cd ManifoldKit
swift build -c release --product ManifoldServer --traits Server
.build/release/ManifoldServer --help
```

---

## Running the server

All examples use Ollama as the backend. Substitute `--backend foundation` for the on-device Apple model (macOS 26+). `foundation` and `ollama` are the only two selections that actually work: the `mlx` and `llama` selections fail with a pointer to the companion packages since v0.48 — the MLX and llama.cpp backends moved to [manifold-mlx](https://github.com/ManifoldKit/manifold-mlx) / [manifold-llama](https://github.com/ManifoldKit/manifold-llama) and are no longer compiled into `manifold-server` — and `--backend cloud` always fails too (Cloud SaaS backend loading is not implemented for ManifoldServer v1; there is no working configuration for it despite it being a listed `ServerBackendKind` case).

### Minimal (no auth, localhost only)

```bash
# Loopback without auth requires an explicit opt-in (any local process can call inference):
manifold-server --backend ollama --model llama3.2 --allow-anonymous
```

### With an API key (recommended)

```bash
manifold-server --backend ollama --model llama3.2 --api-key sk-my-secret
```

### Public bind with CORS

Non-loopback binds **require** `--api-key` (`--allow-anonymous` is rejected off loopback):

```bash
manifold-server \
  --host 0.0.0.0 \
  --port 8080 \
  --backend ollama \
  --model llama3.2 \
  --api-key sk-my-secret \
  --cors-origin https://myapp.example.com
```

### Enable the Prometheus metrics endpoint

```bash
manifold-server --backend ollama --model llama3.2 --api-key sk-my-secret --metrics
# then: curl -H "Authorization: Bearer sk-my-secret" http://127.0.0.1:8080/metrics
```

---

## Verify it's working

```bash
curl http://127.0.0.1:8080/health
# {"status":"ok"}   # /health stays unauthenticated for probes

curl -H "Authorization: Bearer sk-my-secret" http://127.0.0.1:8080/v1/models
# {"object":"list","data":[{"id":"llama3.2",...}]}

curl http://127.0.0.1:8080/v1/chat/completions \
  -H "Authorization: Bearer sk-my-secret" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama3.2",
    "messages": [{"role": "user", "content": "Hello"}],
    "stream": false
  }'
```

---

## Cursor configuration

Open **Cursor Settings → Models → Add Model** and fill in:

```json
{
  "baseUrl": "http://127.0.0.1:8080/v1",
  "apiKey": "sk-my-secret",
  "model": "llama3.2"
}
```

If you started with `--allow-anonymous` (loopback only), Cursor still requires a non-empty `apiKey` field — use any placeholder string; the server ignores it.

## Continue (VS Code / JetBrains) configuration

In `~/.continue/config.json`:

```json
{
  "models": [
    {
      "title": "manifold-server (local)",
      "provider": "openai",
      "model": "llama3.2",
      "apiBase": "http://127.0.0.1:8080/v1",
      "apiKey": "sk-my-secret"
    }
  ]
}
```

---

## Flags reference

| Flag | Default | Description |
|------|---------|-------------|
| `--host` | `127.0.0.1` | Interface to bind. Use `0.0.0.0` for network access (requires `--api-key`). |
| `--port` | `8080` | TCP port. |
| `--api-key` | _(none)_ | Require this key in `Authorization: Bearer` headers. Required unless `--allow-anonymous` on loopback. |
| `--allow-anonymous` | `false` | Explicit opt-in for unauthenticated loopback-only binds. Rejected for non-loopback hosts. |
| `--parallel` | `1` | Maximum concurrent generation requests. |
| `--backend` | `foundation` | `foundation` or `ollama` — the only selections that actually load a backend. (`mlx` / `llama` error with a companion-package pointer since v0.48; `cloud` always errors with `ServerError.notImplemented` — Cloud SaaS backend loading isn't implemented for ManifoldServer v1.) |
| `--model` | _(none)_ | Model name or HuggingFace repo ID for the selected backend. |
| `--model-path` | _(none)_ | Local model path (only meaningful for backends compiled into the server). |
| `--ollama-base-url` | `http://localhost:11434` | Ollama server URL. |
| `--cors-origin` | _(none)_ | Allowed CORS origin (e.g. `https://app.example.com`). |
| `--unsafe-cors` | `false` | Allow any CORS origin. Development only. |
| `--metrics` | `false` | Enable `GET /metrics` (Prometheus text format). |

---

## Security notes

- Bind to `127.0.0.1` (default) unless you need network access.
- Unauthenticated mode requires explicit `--allow-anonymous` and is **loopback-only**. Non-loopback binds always require `--api-key`.
- When exposing to a network, always set `--api-key` and terminate TLS at a reverse proxy (nginx, Caddy).
- The `basechat_*` Prometheus metric prefix is a legacy artifact from the BaseChatKit rename; it is intentionally preserved to avoid breaking existing dashboards.
