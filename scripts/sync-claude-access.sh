#!/usr/bin/env bash
set -euo pipefail
exec node "$(dirname "$0")/lib/cli.mjs" sync-claude-access "$@"