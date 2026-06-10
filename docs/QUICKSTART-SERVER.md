# manifold-server Quickstart

`manifold-server` is an OpenAI-compatible HTTP server built on top of ManifoldKit. Point Cursor, Continue, LangChain, or any OpenAI SDK at `http://127.0.0.1:8080/v1` and use local or cloud-backed models without changing your tooling.

Endpoints: `POST /v1/chat/completions` (streaming + non-streaming), `GET /v1/models`, `POST /v1/embeddings`, `GET /health`, `GET /metrics`.

---

## Install via Homebrew

```bash
brew tap roryford/manifoldkit https://github.com/roryford/ManifoldKit.git
brew install manifold-server
```

The formula builds from source. ManifoldKit pins a ~563 MB llama.cpp xcframework as a SwiftPM binary dependency — even in a `--traits Server`-only build SwiftPM resolves all declared packages, so the xcframework is downloaded. On a cold machine with no local SwiftPM cache allow **10–20 minutes**. Subsequent installs reuse the cache and are faster.

### Alternative: download a pre-built binary

Each GitHub release includes a pre-built tar for Apple Silicon:

```bash
# Replace TAG with the latest release tag, e.g. v0.46.0
TAG=v0.46.0
curl -L "https://github.com/roryford/ManifoldKit/releases/download/${TAG}/manifold-server-${TAG}-macos-arm64.tar.gz" \
  | tar -xz -C /usr/local/bin
```

The binary is **unsigned and unnotarized**. If macOS quarantines it:

```bash
xattr -dr com.apple.quarantine /usr/local/bin/manifold-server
```

---

## Build from source (SwiftPM)

```bash
git clone https://github.com/roryford/ManifoldKit.git
cd ManifoldKit
swift build -c release --product ManifoldServer --traits Server
.build/release/ManifoldServer --help
```

---

## Running the server

All examples use Ollama as the backend. Substitute `--backend mlx`, `--backend llama`, or `--backend foundation` for local backends.

### Minimal (no auth, localhost only)

```bash
manifold-server --backend ollama --model llama3.2
```

### With an API key

```bash
manifold-server --backend ollama --model llama3.2 --api-key sk-my-secret
```

### Public bind with CORS

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
manifold-server --backend ollama --model llama3.2 --metrics
# then: curl http://127.0.0.1:8080/metrics
```

---

## Verify it's working

```bash
curl http://127.0.0.1:8080/health
# {"status":"ok"}

curl http://127.0.0.1:8080/v1/models
# {"object":"list","data":[{"id":"llama3.2",...}]}

curl http://127.0.0.1:8080/v1/chat/completions \
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

If you started `manifold-server` without `--api-key`, set `apiKey` to any non-empty string (Cursor requires a value; the server ignores it when no key is configured).

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
| `--host` | `127.0.0.1` | Interface to bind. Use `0.0.0.0` for network access. |
| `--port` | `8080` | TCP port. |
| `--api-key` | _(none)_ | Require this key in `Authorization: Bearer` headers. Omit for unauthenticated localhost. |
| `--parallel` | `1` | Maximum concurrent generation requests. |
| `--backend` | `foundation` | `mlx`, `llama`, `foundation`, `ollama`, or `cloud`. |
| `--model` | _(none)_ | Model name or HuggingFace repo ID for the selected backend. |
| `--model-path` | _(none)_ | Local path to a `.gguf` file (Llama backend) or MLX model directory. |
| `--ollama-base-url` | `http://localhost:11434` | Ollama server URL. |
| `--cors-origin` | _(none)_ | Allowed CORS origin (e.g. `https://app.example.com`). |
| `--unsafe-cors` | `false` | Allow any CORS origin. Development only. |
| `--metrics` | `false` | Enable `GET /metrics` (Prometheus text format). |

---

## Security notes

- Bind to `127.0.0.1` (default) unless you need network access. The server issues no auth challenge unless `--api-key` is set.
- When exposing to a network, always set `--api-key` and consider TLS termination via a reverse proxy (nginx, Caddy).
- The `basechat_*` Prometheus metric prefix is a legacy artifact from the BaseChatKit rename; it is intentionally preserved to avoid breaking existing dashboards.
