#!/usr/bin/env bash
# Exercises the parts of setup-claude-workstation.sh that can be verified off
# a Mac or Linux box: platform rejection, argument handling, and the jq
# transforms that write the three config files.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/setup-claude-workstation.sh"
PASS=0; FAIL=0

ok()   { echo "  [OK]   $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

echo
echo "=== 1. rejects unsupported platform with a useful message ==="
out="$(bash "$SCRIPT" --gateway-url https://x/claude 2>&1 || true)"
if printf '%s' "$out" | grep -q 'Unsupported platform'; then
  if printf '%s' "$out" | grep -q 'Setup-ClaudeWorkstation.ps1'; then
    ok "rejects and points at the PowerShell version"
  else
    bad "rejects but does not point at the Windows script"
  fi
else
  bad "did not reject: $out"
fi

echo
echo "=== 2. --help prints usage ==="
out="$(bash "$SCRIPT" --help 2>&1 || true)"
printf '%s' "$out" | grep -q -- '--skip-install' && ok "usage lists options" || bad "usage missing options"

echo
echo "=== 3. unknown option is an error ==="
bash "$SCRIPT" --nonsense >/dev/null 2>&1
[ $? -eq 2 ] && ok "exit 2 on unknown option" || bad "wrong exit code for unknown option"

echo
echo "=== 4. jq transform: Claude Code settings ==="
if command -v jq >/dev/null 2>&1; then
  tmp="$(mktemp)"
  # Pre-seed the mutually-exclusive key to prove it gets removed.
  echo '{"env":{"ANTHROPIC_FOUNDRY_RESOURCE":"leftover","KEEP":"yes"},"other":1}' > "$tmp"
  models_json='["claude-sonnet-5","claude-opus-5"]'
  out="$(jq --arg url "https://gw/claude" --arg sonnet "claude-sonnet-5" --arg opus "claude-opus-5" \
     --argjson models "$models_json" '
      .env = (.env // {})
      | .env.CLAUDE_CODE_USE_FOUNDRY = "1"
      | .env.ANTHROPIC_FOUNDRY_BASE_URL = $url
      | (if $opus   != "" then .env.ANTHROPIC_DEFAULT_OPUS_MODEL   = $opus   else . end)
      | (if $sonnet != "" then .env.ANTHROPIC_DEFAULT_SONNET_MODEL = $sonnet else . end)
      | (if $sonnet != "" then .env.ANTHROPIC_DEFAULT_HAIKU_MODEL  = $sonnet else . end)
      | del(.env.ANTHROPIC_FOUNDRY_RESOURCE)
      | .availableModels = $models
      | .enforceAvailableModels = true
    ' "$tmp")"

  printf '%s' "$out" | jq -e '.env.CLAUDE_CODE_USE_FOUNDRY == "1"' >/dev/null && ok "sets CLAUDE_CODE_USE_FOUNDRY" || bad "provider flag not set"
  printf '%s' "$out" | jq -e '.env.ANTHROPIC_FOUNDRY_RESOURCE == null' >/dev/null && ok "removes the mutually-exclusive RESOURCE key" || bad "RESOURCE key survived"
  printf '%s' "$out" | jq -e '.env.ANTHROPIC_DEFAULT_HAIKU_MODEL == "claude-sonnet-5"' >/dev/null && ok "haiku alias points at sonnet" || bad "haiku alias wrong"
  printf '%s' "$out" | jq -e '.env.KEEP == "yes"' >/dev/null && ok "preserves unrelated existing keys" || bad "clobbered existing keys"
  printf '%s' "$out" | jq -e '.other == 1' >/dev/null && ok "preserves unrelated top-level keys" || bad "clobbered top level"
  rm -f "$tmp"

  echo
  echo "=== 5. jq transform: VS Code environmentVariables ==="
  ev="$(jq -n --arg url "https://gw/claude" --arg sonnet "claude-sonnet-5" --arg opus "claude-opus-5" '
      [ {name:"CLAUDE_CODE_USE_FOUNDRY", value:"1"},
        {name:"ANTHROPIC_FOUNDRY_BASE_URL", value:$url} ]
      + (if $opus   != "" then [{name:"ANTHROPIC_DEFAULT_OPUS_MODEL",   value:$opus}]   else [] end)
      + (if $sonnet != "" then [{name:"ANTHROPIC_DEFAULT_SONNET_MODEL", value:$sonnet},
                                {name:"ANTHROPIC_DEFAULT_HAIKU_MODEL",  value:$sonnet}] else [] end)')"
  n="$(printf '%s' "$ev" | jq 'length')"
  [ "$n" = "5" ] && ok "builds 5 environment variables" || bad "expected 5 variables, got $n"
  printf '%s' "$ev" | jq -e '.[0] | has("name") and has("value")' >/dev/null && ok "uses the name/value shape the extension expects" || bad "wrong shape"

  echo
  echo "=== 6. jq transform: Desktop profile ==="
  models_obj="$(printf '%s\n' claude-sonnet-5 claude-opus-5 | jq -R '{name: .}' | jq -s .)"
  prof="$(jq -n --arg url "https://gw/claude" --arg helper "/h/get-foundry-token.sh" \
      --argjson models "$models_obj" --argjson cowork true '{
        inferenceProvider: "gateway",
        inferenceGatewayBaseUrl: $url,
        inferenceGatewayAuthScheme: "bearer",
        inferenceCredentialKind: "helper-script",
        inferenceCredentialHelper: $helper,
        inferenceModels: $models,
        coworkTabEnabled: $cowork }')"
  printf '%s' "$prof" | jq -e '.inferenceProvider == "gateway"' >/dev/null && ok "provider is gateway" || bad "provider wrong"
  printf '%s' "$prof" | jq -e '.inferenceModels[0].name == "claude-sonnet-5"' >/dev/null && ok "models use the {name} shape" || bad "model shape wrong"
  printf '%s' "$prof" | jq -e '.coworkTabEnabled == true' >/dev/null && ok "cowork enabled" || bad "cowork flag wrong"
else
  echo "  jq unavailable - skipping transform tests"
fi

echo
echo "----------------------------------------------------------------------"
echo "  $PASS passed, $FAIL failed"
echo
[ "$FAIL" -eq 0 ] || exit 1
