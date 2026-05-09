#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE_ROOT="$ROOT/Tests/ManifoldMCPTests/Fixtures/Providers"

mode="check"
providers=(github linear notion)
selected=()

usage() {
  cat <<'USAGE'
Usage: scripts/regenerate-mcp-fixtures.sh [--check|--write] [--provider <name> ...]

Generates deterministic, offline MCP provider fixtures used by ManifoldMCPTests.
Default mode is --check (non-destructive).
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      mode="check"
      shift
      ;;
    --write)
      mode="write"
      shift
      ;;
    --provider)
      shift
      [[ $# -gt 0 ]] || { echo "--provider requires a value" >&2; exit 2; }
      if [[ " ${providers[*]} " != *" $1 "* ]]; then
        echo "Unknown provider: $1" >&2
        exit 2
      fi
      selected+=("$1")
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ ${#selected[@]} -gt 0 ]]; then
  providers=("${selected[@]}")
fi

render() {
  local provider="$1"
  local file="$2"

  case "$provider:$file" in
    github:server.json)
      cat <<'JSON'
{
  "provider": "github",
  "catalog": {
    "id": "7B573A8A-C3CB-450D-9EBE-2E7D4C973682",
    "displayName": "GitHub",
    "toolNamespace": "github",
    "dataDisclosure": "Tool calls may send prompt content and selected arguments to GitHub.",
    "transport": {
      "type": "streamable-http",
      "endpoint": "https://mcp.github.com/v1/sse"
    },
    "oauth": {
      "issuer": "https://github.com",
      "scopes": ["read:user", "repo"],
      "redirectURI": "basechat://oauth/mcp/github/callback"
    }
  }
}
JSON
      ;;
    github:initialize.result.json)
      cat <<'JSON'
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2025-03-26",
    "serverInfo": {
      "name": "GitHub MCP",
      "version": "fixture-2025-10-01"
    },
    "capabilities": {
      "tools": {
        "listChanged": true
      },
      "resources": {}
    }
  }
}
JSON
      ;;
    github:tools.list.result.json)
      cat <<'JSON'
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "tools": [
      {
        "name": "search_issues",
        "description": "Search GitHub issues by query.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "query": { "type": "string" }
          },
          "required": ["query"]
        }
      },
      {
        "name": "list_pull_requests",
        "description": "List pull requests for a repository.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "owner": { "type": "string" },
            "repo": { "type": "string" }
          },
          "required": ["owner", "repo"]
        }
      }
    ]
  }
}
JSON
      ;;
    linear:server.json)
      cat <<'JSON'
{
  "provider": "linear",
  "catalog": {
    "id": "B146A315-DFA4-4F75-9AF8-7B98CDE569FB",
    "displayName": "Linear",
    "toolNamespace": "linear",
    "dataDisclosure": "Tool calls may send prompt content and selected arguments to Linear.",
    "transport": {
      "type": "streamable-http",
      "endpoint": "https://mcp.linear.app/v1/sse"
    },
    "oauth": {
      "issuer": "https://linear.app",
      "scopes": ["read", "write"],
      "redirectURI": "basechat://oauth/mcp/linear/callback"
    }
  }
}
JSON
      ;;
    linear:initialize.result.json)
      cat <<'JSON'
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2025-03-26",
    "serverInfo": {
      "name": "Linear MCP",
      "version": "fixture-2025-10-01"
    },
    "capabilities": {
      "tools": {
        "listChanged": false
      }
    }
  }
}
JSON
      ;;
    linear:tools.list.result.json)
      cat <<'JSON'
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "tools": [
      {
        "name": "search_issues",
        "description": "Search Linear issues.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "query": { "type": "string" }
          },
          "required": ["query"]
        }
      },
      {
        "name": "create_comment",
        "description": "Create a comment on an issue.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "issueId": { "type": "string" },
            "body": { "type": "string" }
          },
          "required": ["issueId", "body"]
        }
      }
    ]
  }
}
JSON
      ;;
    notion:server.json)
      cat <<'JSON'
{
  "provider": "notion",
  "catalog": {
    "id": "5E4A6401-C86D-43DE-847E-AE02A34E89D8",
    "displayName": "Notion",
    "toolNamespace": "notion",
    "dataDisclosure": "Tool calls may send prompt content and selected arguments to Notion.",
    "transport": {
      "type": "streamable-http",
      "endpoint": "https://mcp.notion.com/v1/sse"
    },
    "oauth": {
      "issuer": "https://notion.com",
      "scopes": ["read:content", "write:content"],
      "redirectURI": "basechat://oauth/mcp/notion/callback"
    }
  }
}
JSON
      ;;
    notion:initialize.result.json)
      cat <<'JSON'
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2025-03-26",
    "serverInfo": {
      "name": "Notion MCP",
      "version": "fixture-2025-10-01"
    },
    "capabilities": {
      "tools": {
        "listChanged": true
      },
      "prompts": {}
    }
  }
}
JSON
      ;;
    notion:tools.list.result.json)
      cat <<'JSON'
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "tools": [
      {
        "name": "search",
        "description": "Search pages in Notion.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "query": { "type": "string" }
          },
          "required": ["query"]
        }
      },
      {
        "name": "create_page",
        "description": "Create a Notion page.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "parentId": { "type": "string" },
            "title": { "type": "string" }
          },
          "required": ["parentId", "title"]
        }
      }
    ]
  }
}
JSON
      ;;
    *)
      echo "No template for $provider/$file" >&2
      return 1
      ;;
  esac
}

status=0
for provider in "${providers[@]}"; do
  provider_dir="$FIXTURE_ROOT/$provider"
  mkdir -p "$provider_dir"

  for file in server.json initialize.result.json tools.list.result.json; do
    path="$provider_dir/$file"
    expected="$(render "$provider" "$file")"

    if [[ "$mode" == "write" ]]; then
      printf '%s\n' "$expected" > "$path"
      echo "wrote $path"
      continue
    fi

    if [[ ! -f "$path" ]]; then
      echo "missing fixture: $path" >&2
      status=1
      continue
    fi

    current="$(cat "$path")"
    if [[ "$current" != "$expected" ]]; then
      echo "fixture drift detected: $path" >&2
      echo "run: scripts/regenerate-mcp-fixtures.sh --write --provider $provider" >&2
      status=1
    fi
  done
done

if [[ "$mode" == "check" && $status -eq 0 ]]; then
  echo "MCP provider fixtures are up to date."
fi

exit "$status"
