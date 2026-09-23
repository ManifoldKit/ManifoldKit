"""A strict line-delimited MCP stdio peer used by process-backed tests."""

import json
import os
import signal
import sys
import time


mode = sys.argv[1]
pid_path = sys.argv[2]
if mode == "silent_ignore_termination":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
with open(pid_path, "w", encoding="ascii") as marker:
    marker.write(str(os.getpid()))

for line in sys.stdin.buffer:
    request = json.loads(line)
    method = request.get("method")
    if mode in ("silent", "silent_ignore_termination") and method == "initialize":
        time.sleep(60)
        break
    if method == "initialize":
        response = {
            "jsonrpc": "2.0",
            "id": request["id"],
            "result": {
                "protocolVersion": "2025-03-26",
                "serverInfo": {"name": "line-peer", "version": "1"},
                "capabilities": {"tools": {"listChanged": True}},
            },
        }
    elif method == "notifications/initialized":
        if mode == "exit_on_initialized":
            break
        if mode == "exit_after_initialize":
            time.sleep(0.2)
            break
        if mode == "malformed_after_initialize":
            sys.stdout.buffer.write(b"not-json\n")
            sys.stdout.buffer.flush()
            break
        continue
    elif method == "tools/list":
        response = {
            "jsonrpc": "2.0",
            "id": request["id"],
            "result": {
                "tools": [{
                    "name": "echo",
                    "description": "Echo a value",
                    "inputSchema": {"type": "object", "properties": {}},
                }],
            },
        }
    else:
        continue
    sys.stdout.buffer.write(json.dumps(response, separators=(",", ":")).encode() + b"\n")
    sys.stdout.buffer.flush()
