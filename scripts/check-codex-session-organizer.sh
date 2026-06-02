#!/usr/bin/env bash
# Lightweight safety check for the Codex session organizer data model.
set -euo pipefail

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
SRC_DB="$CODEX_HOME/state_5.sqlite"
TMP_DIR="${TMPDIR:-/tmp}/cxpod-organizer-check.$$"
TMP_DB="$TMP_DIR/state_5.sqlite"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

[[ -f "$SRC_DB" ]] || {
  echo "missing Codex state db: $SRC_DB" >&2
  exit 1
}

mkdir -p "$TMP_DIR"
sqlite3 "$SRC_DB" ".backup '$TMP_DB'"

first_id="$(sqlite3 "$TMP_DB" "SELECT id FROM threads ORDER BY COALESCE(updated_at_ms, updated_at * 1000) DESC LIMIT 1;")"
[[ -n "$first_id" ]] || {
  echo "no Codex threads found"
  exit 0
}

target="$TMP_DIR/Test Project"
sqlite3 "$TMP_DB" "UPDATE threads SET cwd = '$target' WHERE id = '$first_id';"
changed="$(sqlite3 "$TMP_DB" "SELECT COUNT(*) FROM threads WHERE id = '$first_id' AND cwd = '$target';")"

if [[ "$changed" != "1" ]]; then
  echo "organizer sqlite update check failed" >&2
  exit 1
fi

cat > "$TMP_DIR/codex-session-projects.json" <<JSON
{
  "pendingThreadProjects": {
    "$first_id": "$target"
  },
  "projects": [
    {
      "name": "Test Project",
      "path": "$target"
    }
  ]
}
JSON

python3 -m json.tool "$TMP_DIR/codex-session-projects.json" >/dev/null

echo "ok: organizer sqlite update check passed"
