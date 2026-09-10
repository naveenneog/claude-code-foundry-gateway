#!/usr/bin/env bash
set -euo pipefail
exec node "$(dirname "$0")/lib/cli.mjs" find-claude-user-data "$@"