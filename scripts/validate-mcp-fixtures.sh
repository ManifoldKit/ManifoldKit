#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE_ROOT="$ROOT/Tests/ManifoldMCPTests/Fixtures/Providers"

"$ROOT/scripts/regenerate-mcp-fixtures.sh" --check

python3 - <<'PY' "$FIXTURE_ROOT"
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
providers = ["github", "linear", "notion"]
required_files = ["server.json", "initialize.result.json", "tools.list.result.json"]

errors = []
for provider in providers:
    pdir = root / provider
    if not pdir.is_dir():
        errors.append(f"missing provider directory: {pdir}")
        continue

    for name in required_files:
        path = pdir / name
        if not path.exists():
            errors.append(f"missing fixture: {path}")
            continue
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except Exception as exc:
            errors.append(f"invalid JSON in {path}: {exc}")
            continue

        if name == "server.json":
            catalog = payload.get("catalog")
            if payload.get("provider") != provider:
                errors.append(f"{path}: provider must equal '{provider}'")
            if not isinstance(catalog, dict):
                errors.append(f"{path}: missing object field 'catalog'")
                continue
            transport = catalog.get("transport")
            oauth = catalog.get("oauth")
            if not isinstance(transport, dict) or transport.get("type") != "streamable-http":
                errors.append(f"{path}: catalog.transport.type must be streamable-http")
            if not isinstance(oauth, dict) or not isinstance(oauth.get("scopes"), list) or not oauth.get("scopes"):
                errors.append(f"{path}: catalog.oauth.scopes must be a non-empty array")
            continue

        if payload.get("jsonrpc") != "2.0":
            errors.append(f"{path}: jsonrpc must be '2.0'")
        if "result" not in payload or not isinstance(payload["result"], dict):
            errors.append(f"{path}: missing object field 'result'")
            continue

        if name == "initialize.result.json":
            result = payload["result"]
            if result.get("protocolVersion") != "2025-03-26":
                errors.append(f"{path}: protocolVersion must be 2025-03-26")
            if not isinstance(result.get("capabilities"), dict):
                errors.append(f"{path}: capabilities must be an object")
        elif name == "tools.list.result.json":
            tools = payload["result"].get("tools")
            if not isinstance(tools, list) or not tools:
                errors.append(f"{path}: result.tools must be a non-empty array")
                continue
            for idx, tool in enumerate(tools):
                if not isinstance(tool, dict):
                    errors.append(f"{path}: tools[{idx}] must be an object")
                    continue
                if not isinstance(tool.get("name"), str) or not tool["name"]:
                    errors.append(f"{path}: tools[{idx}].name must be a non-empty string")
                if "inputSchema" not in tool and "parameters" not in tool:
                    errors.append(f"{path}: tools[{idx}] missing inputSchema/parameters")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    sys.exit(1)

print("MCP provider fixtures validate successfully.")
PY
