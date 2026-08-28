<#
.SYNOPSIS
    Produces the onboarding email for a newly entitled developer, and can send
    it through Microsoft Graph.

.DESCRIPTION
    Generates a self-contained package - HTML mail, plain text, an .eml you can
    open in Outlook, and the config file the setup script reads - so the whole
    handover is one message with one command in it.

    Sending is optional and separate on purpose. Graph sendMail needs the
    Mail.Send delegated permission, which many tenants do not grant by default,
    so the default behaviour is to write the files and let you send them
    however you normally would. -Send attempts Graph and falls back cleanly.

    The config file carries no secret. It holds the gateway URL, the tenant id
    and the tier limits - all of which the developer needs and none of which
    grants access. Access comes from group membership.

.EXAMPLE
    ./scripts/New-OnboardingEmail.ps1 -ConfigPath ./onboarding/claude-gateway.json -To dev@contoso.com

.EXAMPLE
    ./scripts/New-OnboardingEmail.ps1 -ConfigPath ./onboarding/claude-gateway.json `
        -To dev@contoso.com -DisplayName 'Sam' -Tier premium -Send
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [Parameter(Mandatory = $true)][string]$To,
    [string]$DisplayName,
    [ValidateSet('standard', 'premium')][string]$Tier = 'standard',

    # Where the developer can fetch the setup script and config. A share, an
    # internal site, or the repo. Leave empty to attach instead.
    [string]$DistributionUrl,

    [string]$SupportContact = 'your platform team',
    [string]$OutputPath = './onboarding',
    [switch]$Send
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ConfigPath)) { throw "Config not found: $ConfigPath" }
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$tierCfg = $cfg.tiers.$Tier
$group = if ($Tier -eq 'premium') { $cfg.premiumGroup } else { $cfg.standardGroup }
$name = if ($DisplayName) { $DisplayName } else { ($To -split '@')[0] }

New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null

$tpm = '{0:n0}' -f $tierCfg.tokensPerMinute
$tpd = '{0:n0}' -f $tierCfg.tokensPerDay

$cmd = if ($DistributionUrl) {
    "irm $($DistributionUrl.TrimEnd('/'))/Setup-ClaudeWorkstation.ps1 -OutFile Setup-ClaudeWorkstation.ps1`n" +
    ".\Setup-ClaudeWorkstation.ps1 -ConfigPath $($DistributionUrl.TrimEnd('/'))/claude-gateway.json"
} else {
    ".\Setup-ClaudeWorkstation.ps1 -ConfigPath .\claude-gateway.json"
}

$subject = "Your Claude access is ready - one command to set up"

# Loaded before the templates below use it. HttpUtility is only present once
# System.Web is loaded, and the here-strings are evaluated where they are
# defined - so this has to come first, not after.
Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
function ConvertTo-HtmlText([string]$s) {
    if ([System.Web.HttpUtility] -as [type]) { return [System.Web.HttpUtility]::HtmlEncode($s) }
    return ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;')
}

# ------------------------------------------------------------------ plain text

$text = @"
Hi $name,

You now have access to Claude running in our own Microsoft Foundry deployment.

There is no API key and no Anthropic account. You sign in with your work
account, and your usage is metered against your own budget.

SET UP - one command, no admin rights needed

Open PowerShell and run:

$cmd

It checks what you already have, installs anything missing, and configures all
three clients: the Claude Code CLI, the VS Code extension, and Claude Desktop
including Cowork. It finishes by making a real call to confirm it works.

Takes a few minutes. You will be asked to sign in with your work account once.

AFTERWARDS

  Claude Code CLI   run: claude
  VS Code           reload the window, then Ctrl+Shift+P -> Claude Code: Open in Side Bar
  Claude Desktop    quit completely, including the tray icon, then reopen

The restarts matter. All three read their configuration at startup.

YOUR BUDGET

  Tier              $Tier
  Per minute        $tpm tokens
  Per day           $tpd tokens
  Models            $(($cfg.tiers.PSObject.Properties.Name) -join ', ' | Out-Null; 'claude-sonnet-5, claude-opus-5')

Going over the per-minute limit causes a short pause while the client retries -
you may not notice. Exhausting the daily budget stops you until it resets. Ask
$SupportContact if you need the premium tier.

WORTH KNOWING

  - Your usage is attributed to you by name for cost reporting. Only token
    counts are recorded - never your prompts or conversations.
  - Claude Design will not work against our deployment. Chat, Cowork and Code
    do. Design depends on Anthropic-hosted services that cannot be re-pointed.
  - Nothing you send leaves our Azure tenant.

IF SOMETHING GOES WRONG

  "Not entitled" / 403     your entitlement has not synced yet - contact $SupportContact
  401                      re-run the setup script; it pins the right tenant
  Asked to sign in to Anthropic   the app did not pick up the config - restart it fully

Anything else, contact $SupportContact.
"@

# ------------------------------------------------------------------------ html

$html = @"
<!doctype html>
<html><head><meta charset="utf-8"></head>
<body style="margin:0;padding:0;background:#f4f5f7;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f5f7;padding:24px 12px;">
<tr><td align="center">
<table role="presentation" width="640" cellpadding="0" cellspacing="0" style="max-width:640px;background:#ffffff;border-radius:10px;overflow:hidden;font-family:Segoe UI,system-ui,-apple-system,sans-serif;">

  <tr><td style="background:#1E2761;padding:26px 30px;">
    <div style="color:#ffffff;font-size:21px;font-weight:600;">Your Claude access is ready</div>
    <div style="color:#cadcfc;font-size:14px;padding-top:5px;">Running in our own Microsoft Foundry deployment</div>
  </td></tr>

  <tr><td style="padding:28px 30px 6px;color:#1a1a1a;font-size:15px;line-height:1.6;">
    <p style="margin:0 0 14px;">Hi $name,</p>
    <p style="margin:0 0 14px;">You now have access to Claude running on our own deployment.
    <strong>There is no API key and no Anthropic account</strong> &mdash; you sign in with your
    work account, and your usage is metered against your own budget.</p>
  </td></tr>

  <tr><td style="padding:14px 30px 0;">
    <div style="font-size:13px;font-weight:700;color:#1E2761;letter-spacing:.5px;">SET UP &mdash; ONE COMMAND</div>
    <p style="margin:8px 0 12px;font-size:14px;color:#444;line-height:1.6;">
      Open PowerShell and run this. No administrator rights needed.</p>
    <div style="background:#0d1117;border-radius:7px;padding:15px 17px;">
      <code style="color:#8fe3a0;font-family:Consolas,monospace;font-size:12.5px;white-space:pre;line-height:1.7;">$(ConvertTo-HtmlText $cmd)</code>
    </div>
    <p style="margin:12px 0 0;font-size:13.5px;color:#666;line-height:1.6;">
      It checks what you already have, installs anything missing, and configures the
      Claude Code CLI, the VS Code extension, and Claude Desktop including Cowork.
      It finishes by making a real call to confirm everything works.</p>
  </td></tr>

  <tr><td style="padding:22px 30px 0;">
    <div style="font-size:13px;font-weight:700;color:#1E2761;letter-spacing:.5px;">AFTERWARDS</div>
    <table cellpadding="0" cellspacing="0" style="margin-top:10px;font-size:14px;color:#333;width:100%;">
      <tr><td style="padding:5px 0;width:150px;color:#666;">Claude Code CLI</td><td style="padding:5px 0;"><code style="background:#f0f1f3;padding:2px 6px;border-radius:4px;">claude</code></td></tr>
      <tr><td style="padding:5px 0;color:#666;">VS Code</td><td style="padding:5px 0;">Reload the window, then <em>Claude Code: Open in Side Bar</em></td></tr>
      <tr><td style="padding:5px 0;color:#666;">Claude Desktop</td><td style="padding:5px 0;">Quit completely, <strong>including the tray icon</strong>, then reopen</td></tr>
    </table>
    <p style="margin:10px 0 0;font-size:13px;color:#8a6d00;background:#fff8e1;border-left:3px solid #F2A007;padding:9px 12px;border-radius:3px;">
      The restarts matter &mdash; all three read their configuration at startup.</p>
  </td></tr>

  <tr><td style="padding:22px 30px 0;">
    <div style="font-size:13px;font-weight:700;color:#1E2761;letter-spacing:.5px;">YOUR BUDGET</div>
    <table cellpadding="0" cellspacing="0" style="margin-top:10px;font-size:14px;width:100%;border-collapse:collapse;">
      <tr><td style="padding:7px 0;border-bottom:1px solid #eee;color:#666;width:150px;">Tier</td><td style="padding:7px 0;border-bottom:1px solid #eee;"><strong>$Tier</strong></td></tr>
      <tr><td style="padding:7px 0;border-bottom:1px solid #eee;color:#666;">Per minute</td><td style="padding:7px 0;border-bottom:1px solid #eee;">$tpm tokens</td></tr>
      <tr><td style="padding:7px 0;border-bottom:1px solid #eee;color:#666;">Per day</td><td style="padding:7px 0;border-bottom:1px solid #eee;">$tpd tokens</td></tr>
      <tr><td style="padding:7px 0;color:#666;">Models</td><td style="padding:7px 0;">claude-sonnet-5, claude-opus-5</td></tr>
    </table>
    <p style="margin:11px 0 0;font-size:13.5px;color:#666;line-height:1.6;">
      Going over the per-minute limit causes a short pause while the client retries &mdash;
      you may not even notice. Ask $SupportContact if you need the premium tier.</p>
  </td></tr>

  <tr><td style="padding:22px 30px 0;">
    <div style="font-size:13px;font-weight:700;color:#1E2761;letter-spacing:.5px;">WORTH KNOWING</div>
    <ul style="margin:10px 0 0;padding-left:19px;font-size:14px;color:#444;line-height:1.75;">
      <li>Your usage is attributed to you by name for cost reporting. Only token counts
          are recorded &mdash; never your prompts or conversations.</li>
      <li><strong>Claude Design will not work</strong> against our deployment. Chat, Cowork
          and Code do. Design depends on Anthropic-hosted services that cannot be re-pointed.</li>
      <li>Nothing you send leaves our Azure tenant.</li>
    </ul>
  </td></tr>

  <tr><td style="padding:22px 30px 28px;">
    <div style="font-size:13px;font-weight:700;color:#1E2761;letter-spacing:.5px;">IF SOMETHING GOES WRONG</div>
    <table cellpadding="0" cellspacing="0" style="margin-top:10px;font-size:13.5px;width:100%;border-collapse:collapse;">
      <tr><td style="padding:6px 0;border-bottom:1px solid #eee;color:#c4314b;width:230px;">&ldquo;Not entitled&rdquo; / 403</td><td style="padding:6px 0;border-bottom:1px solid #eee;color:#444;">Entitlement has not synced yet &mdash; contact $SupportContact</td></tr>
      <tr><td style="padding:6px 0;border-bottom:1px solid #eee;color:#c4314b;">401</td><td style="padding:6px 0;border-bottom:1px solid #eee;color:#444;">Re-run the setup script; it pins the right tenant</td></tr>
      <tr><td style="padding:6px 0;color:#c4314b;">Asked to sign in to Anthropic</td><td style="padding:6px 0;color:#444;">The app did not pick up the config &mdash; restart it fully</td></tr>
    </table>
  </td></tr>

  <tr><td style="background:#f7f8fa;padding:16px 30px;border-top:1px solid #e8e9ec;color:#8a8f98;font-size:12px;">
    Entitled through <code style="background:#eceef1;padding:1px 5px;border-radius:3px;">$group</code>.
    Questions: $SupportContact.
  </td></tr>

</table>
</td></tr></table>
</body></html>
"@

$htmlPath = Join-Path $OutputPath "onboarding-$($To -replace '[^a-zA-Z0-9]','-').html"
$textPath = Join-Path $OutputPath "onboarding-$($To -replace '[^a-zA-Z0-9]','-').txt"
$html | Set-Content $htmlPath -Encoding UTF8
$text | Set-Content $textPath -Encoding UTF8

# .eml so it can be opened and sent from Outlook without Graph permissions.
$emlPath = Join-Path $OutputPath "onboarding-$($To -replace '[^a-zA-Z0-9]','-').eml"
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($html))
$eml = @"
To: $To
Subject: $subject
X-Unsent: 1
MIME-Version: 1.0
Content-Type: text/html; charset=utf-8
Content-Transfer-Encoding: base64

$([regex]::Replace($b64, '.{1,76}', { param($m) $m.Value + "`r`n" }))
"@
$eml | Set-Content $emlPath -Encoding UTF8

Write-Host ''
Write-Host 'Onboarding package' -ForegroundColor Cyan
Write-Host "  to      $To  ($Tier tier)"
Write-Host "  html    $htmlPath" -ForegroundColor DarkGray
Write-Host "  text    $textPath" -ForegroundColor DarkGray
Write-Host "  eml     $emlPath  (double-click to open in Outlook)" -ForegroundColor DarkGray
Write-Host "  config  $ConfigPath" -ForegroundColor DarkGray

if ($Send) {
    Write-Host ''
    Write-Host 'Sending via Microsoft Graph...' -ForegroundColor Cyan
    $tok = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv 2>$null
    if (-not $tok) { Write-Host '  no Graph token - send the .eml manually' -ForegroundColor Yellow; return }

    $payload = @{
        message = @{
            subject = $subject
            body    = @{ contentType = 'HTML'; content = $html }
            toRecipients = @(@{ emailAddress = @{ address = $To } })
        }
        saveToSentItems = $true
    } | ConvertTo-Json -Depth 8

    try {
        Invoke-RestMethod -Method Post -Uri 'https://graph.microsoft.com/v1.0/me/sendMail' `
            -Headers @{ Authorization = "Bearer $tok" } -ContentType 'application/json' -Body $payload | Out-Null
        Write-Host "  sent to $To" -ForegroundColor Green
    }
    catch {
        Write-Host "  Graph send failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host '  This usually means Mail.Send is not consented in your tenant.' -ForegroundColor DarkGray
        Write-Host "  Open $emlPath in Outlook and send it from there." -ForegroundColor DarkGray
    }
}
else {
    Write-Host ''
    Write-Host "  Open the .eml in Outlook to send, or add -Send to try Microsoft Graph." -ForegroundColor DarkGray
}
Write-Host ''
