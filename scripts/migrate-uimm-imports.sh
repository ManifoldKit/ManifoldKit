#!/usr/bin/env bash
#
# migrate-uimm-imports.sh — codemod for the v2.0 ManifoldUIModelManagement peel.
#
# Adds `import ManifoldUIModelManagement` to any Swift file that uses one of
# the symbols that moved from ManifoldUI to the new module, inserting the new
# import line immediately after the first existing `import ManifoldUI` line.
#
# Idempotent — re-running the script on an already-migrated file leaves it
# unchanged. Handles `#if`-gated import blocks correctly: the new import is
# placed inside the same `#if` branch as the originating ManifoldUI import.
#
# Usage:
#   scripts/migrate-uimm-imports.sh [<path> ...]
#
# When no paths are given, the script scans the current working directory.
#
# Exits 0 on success, 1 on any internal error.

set -euo pipefail

# Symbols that moved out of ManifoldUI in v2.0.
SYMBOLS=(
    ModelManagementSheet
    ModelManagementViewModel
    ModelSelectionTabView
    APIConfigurationView
    APIEndpointEditorView
    APIEndpointRow
    APIEndpointDraftValidator
    RemoteServerConfigSheet
    HuggingFaceBrowserView
    DownloadableModelRow
    DownloadProgressView
    LocalModelStorageView
    StorageManagementView
    WhyDownloadView
)

# Word-boundary regex matching any of the moved symbols. Word boundary `\<...\>`
# avoids matching `MyModelManagementSheetWrapper`-style longer identifiers.
PATTERN="\\<($(IFS='|'; echo "${SYMBOLS[*]}"))\\>"

migrate_file() {
    local file="$1"

    # Skip if already migrated.
    if grep -qE '^\s*import\s+ManifoldUIModelManagement\s*$' "$file"; then
        return 0
    fi

    # Skip if the file references no moved symbol — nothing to do.
    if ! grep -qE "$PATTERN" "$file"; then
        return 0
    fi

    # Find the first `import ManifoldUI` (exact module match, not a prefix).
    # Using awk for portability — `sed -i` differs across BSD/GNU.
    local tmp
    tmp=$(mktemp)
    awk '
        BEGIN { inserted = 0 }
        {
            print
            if (!inserted && $0 ~ /^[[:space:]]*import[[:space:]]+ManifoldUI[[:space:]]*$/) {
                # Mirror leading indentation so #if-gated blocks stay tidy.
                indent = $0
                sub(/import.*$/, "", indent)
                print indent "import ManifoldUIModelManagement"
                inserted = 1
            }
        }
        END {
            if (!inserted) {
                # Emit a marker so the caller knows we could not migrate.
                exit 2
            }
        }
    ' "$file" > "$tmp" || {
        local rc=$?
        rm -f "$tmp"
        if [ "$rc" -eq 2 ]; then
            echo "warning: $file uses moved symbols but has no 'import ManifoldUI' to anchor the new import after — add manually" >&2
            return 0
        fi
        return "$rc"
    }

    mv "$tmp" "$file"
    echo "migrated: $file"
}

main() {
    local roots=("$@")
    if [ "${#roots[@]}" -eq 0 ]; then
        roots=(.)
    fi

    while IFS= read -r -d '' file; do
        migrate_file "$file"
    done < <(find "${roots[@]}" -type f -name '*.swift' -print0)
}

main "$@"
