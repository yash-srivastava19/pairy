#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v nvim >/dev/null 2>&1; then
  echo "[pairy:test] Neovim is required but not found in PATH." >&2
  exit 1
fi

nvim --headless -u NONE -n -l tests/run.lua
