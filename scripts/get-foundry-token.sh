#!/usr/bin/env bash
#
# Credential helper for Claude Desktop on macOS and Linux.
#
# Prints a Microsoft Entra bearer token for the Cognitive Services data plane to
# stdout, and nothing else.
#
# Claude Desktop runs the executable named by inferenceCredentialHelper and
# reads a bearer token from its standard output. This implementation reuses the
# Azure CLI's own sign-in, which is why the helper path needs no app
# registration and no admin consent: the Azure CLI client
# (04b07795-8ddb-461a-bbee-02f9e1bf7b46) is already consented in essentially
# every tenant.
#
# Contract:
#   - stdout carries the token and nothing else; any stray output corrupts it
#   - diagnostics go to stderr
#   - non-zero exit on failure, so the app can surface a real error
#
# The app sets CLAUDE_HELPER_CONTEXT so a helper can tell an interactive start
# from a mid-session refresh. During a silent refresh nobody is watching, so
# this fails fast rather than blocking on a prompt.
#
# Set CLAUDE_FOUNDRY_TENANT_ID when the developer is a guest, or is signed in to
# more than one tenant - a bare az login lands guests in their home directory
# and the resulting token is rejected downstream.

set -uo pipefail

RESOURCE="${CLAUDE_FOUNDRY_RESOURCE_SCOPE:-https://cognitiveservices.azure.com}"

diag() { echo "[claude-helper] $*" >&2; }

if ! command -v az >/dev/null 2>&1; then
  diag "Azure CLI not found on PATH."
  exit 1
fi

ARGS=(account get-access-token --resource "$RESOURCE" --query accessToken -o tsv)
[ -n "${CLAUDE_FOUNDRY_TENANT_ID:-}" ] && ARGS+=(--tenant "$CLAUDE_FOUNDRY_TENANT_ID")

token="$(az "${ARGS[@]}" 2>/dev/null || true)"

if [ -z "$token" ]; then
  if [ "${CLAUDE_HELPER_CONTEXT:-}" = "refresh" ]; then
    diag "No cached credential and this is a silent refresh - not prompting."
    diag "Run: az login${CLAUDE_FOUNDRY_TENANT_ID:+ --tenant $CLAUDE_FOUNDRY_TENANT_ID}"
    exit 2
  fi

  diag "No cached credential. Starting interactive sign-in."
  if [ -n "${CLAUDE_FOUNDRY_TENANT_ID:-}" ]; then
    az login --tenant "$CLAUDE_FOUNDRY_TENANT_ID" >/dev/null 2>&1
  else
    az login >/dev/null 2>&1
  fi
  token="$(az "${ARGS[@]}" 2>/dev/null || true)"
fi

# Cheap sanity check - a JWT starts with the base64 of '{"', which is 'eyJ'.
case "$token" in
  eyJ*) printf '%s' "$token"; exit 0 ;;
  '')   diag "Could not acquire a token."; exit 1 ;;
  *)    diag "Response did not look like a JWT."; exit 1 ;;
esac
