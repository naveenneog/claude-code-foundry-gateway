@echo off
REM Credential helper shim for Claude Desktop.
REM
REM inferenceCredentialHelper must name an executable, and Claude Desktop reads
REM a bearer token from its stdout. This wrapper exists so the policy value can
REM point at a .cmd rather than depending on how the endpoint resolves .ps1
REM execution policy.
REM
REM Install both this file and get-foundry-token.ps1 into the same directory.
REM Setup-ClaudeWorkstation.ps1 copies both to %LOCALAPPDATA%\ClaudeFoundry\
REM and writes that path into Claude Desktop's profile. The pair has to stay
REM there: Desktop re-runs this every inferenceCredentialHelperTtlSec seconds
REM (30 minutes by default) to refresh the token, so removing it breaks Desktop
REM at the next refresh rather than straight away.
REM
REM -NonInteractive is deliberately NOT set: an interactive start may need to
REM open a sign-in window. The PowerShell helper decides whether prompting is
REM appropriate using CLAUDE_HELPER_CONTEXT.

setlocal
set "HELPER=%~dp0get-foundry-token.ps1"

if not exist "%HELPER%" (
    echo [claude-helper] Missing %HELPER% 1>&2
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%HELPER%" %*
exit /b %ERRORLEVEL%
