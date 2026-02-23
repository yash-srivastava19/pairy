#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

git config core.hooksPath .githooks
chmod +x .githooks/pre-commit .githooks/pre-push scripts/test.sh

echo "[pairy] Git hooks installed. pre-commit and pre-push will run scripts/test.sh"
