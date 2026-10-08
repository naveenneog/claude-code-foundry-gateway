param(
    [string]$WorkspaceCustomerId,
    [switch]$PrintQuery
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$python = Join-Path $root '.venv-aum-service\Scripts\python.exe'
if (-not (Test-Path $python)) { $python = Join-Path $root '.venv-aum-service\bin\python' }
if (-not (Test-Path $python)) { throw 'Missing .venv-aum-service.' }
$gateway = 'https://management.azure.com/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.ApiManagement/service/apim-test'
$env:PYTHONPATH = Join-Path $root 'service\aum'
$query = & $python -c @"
from datetime import datetime, timezone
from aum_service.usd_reconcile import usage_query
print(usage_query('$gateway', datetime(2026, 10, 9, 2, tzinfo=timezone.utc), chargeback='ChargebackFixture', metrics='MetricsFixture'))
"@
$fixture = @'
let ChargebackFixture = (_from:datetime, _to:datetime) {
datatable(timestamp:datetime, ingested_at:datetime, gateway_id:string, actor:string, user_id:string, tier:string, business_unit:string, client_surface:string, client_raw:string, client_ip:string, model:string, deployment:string, streamed:bool, prompt_tokens:real, completion_tokens:real, total_tokens:real, cache_read_tokens:real, cache_write_5m_tokens:real, cache_write_1h_tokens:real, cache_read_known:bool, cache_write_known:bool, inference_geo:string, cache_tokens_known:bool, usage_source:string, message_id:string, request_id:string)
[
datetime(2026-10-08T10:00:00Z), datetime(2026-10-08T10:01:00Z), "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.ApiManagement/service/apim-test", "Dev", "u1", "standard", "eng", "sdk", "", "", "claude-haiku-4-5-20251001", "", true, 1, 1, 2, real(null), 0, 0, false, true, "global", false, "log", "m1", "r1",
datetime(2026-10-08T11:00:00Z), datetime(2026-10-08T11:01:00Z), "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.ApiManagement/service/apim-test", "Dev", "u1", "standard", "finance", "sdk", "", "", "claude-haiku-4-5-20251001", "", true, 1, 1, 2, real(null), 0, 0, false, true, "global", false, "log", "m2", "r2",
datetime(2026-10-08T11:30:00Z), datetime(2026-10-08T11:31:00Z), "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.ApiManagement/service/apim-test", "Dev", "u2", "standard", "sales", "sdk", "", "", "claude-sonnet-5", "claude-sonnet-5", false, 1, 1, 2, 7, 0, 0, true, true, "global", true, "body", "m3", "r3",
datetime(2026-10-08T11:35:00Z), datetime(2026-10-08T11:36:00Z), "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.ApiManagement/service/apim-test", "Big", "u4", "premium", "platform", "sdk", "", "", "claude-opus-5-5-20260101", "prod-big", false, 1, 1, 2, 2, 0, 0, true, true, "global", true, "body", "m7", "r7",
datetime(2026-10-08T11:36:00Z), datetime(2026-10-08T11:37:00Z), "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.ApiManagement/service/apim-test", "Multi", "u5", "standard", "eng", "sdk", "", "", "claude-sonnet-5", "claude-sonnet-5", false, 1, 1, 2, 3, 0, 0, true, true, "global", true, "body", "m8", "r8",
datetime(2026-10-08T11:37:00Z), datetime(2026-10-08T11:38:00Z), "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.ApiManagement/service/apim-test", "Multi", "u5", "premium", "platform", "sdk", "", "", "claude-opus-5-5-20260101", "prod-big", false, 1, 1, 2, 4, 0, 0, true, true, "global", true, "body", "m9", "r9",
datetime(2026-10-08T11:38:00Z), datetime(2026-10-08T11:39:00Z), "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.ApiManagement/service/apim-test", "Residual", "u6", "premium", "platform", "sdk", "", "", "claude-opus-5-5-20260101", "", false, 1, 1, 2, 5, 0, 0, true, true, "global", true, "body", "m10", "r10",
datetime(2026-10-08T11:39:00Z), datetime(2026-10-08T11:40:00Z), "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.ApiManagement/service/apim-test", "Known", "u7", "standard", "eng", "sdk", "", "", "claude-sonnet-5", "", false, 1, 1, 2, 6, 0, 0, true, true, "global", true, "body", "m11", "r11",
datetime(2026-10-08T11:40:00Z), datetime(2026-10-08T11:41:00Z), "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.ApiManagement/service/apim-test", "Ghost", "", "standard", "", "sdk", "", "", "claude-sonnet-5", "claude-sonnet-5", true, 0, 0, 0, real(null), 0, 0, false, true, "global", false, "log", "m4", "r4",
datetime(2026-10-08T11:50:00Z), datetime(2026-10-08T11:51:00Z), "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.ApiManagement/service/apim-test", "Tie", "tie", "standard", "tie-a", "sdk", "", "", "claude-sonnet-5", "claude-sonnet-5", true, 1, 1, 2, real(null), 0, 0, false, true, "global", false, "log", "m5", "r5",
datetime(2026-10-08T11:50:00Z), datetime(2026-10-08T11:51:00Z), "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.ApiManagement/service/apim-test", "Tie", "tie", "standard", "tie-b", "sdk", "", "", "claude-sonnet-5", "claude-sonnet-5", true, 1, 1, 2, real(null), 0, 0, false, true, "global", false, "log", "m6", "r6"
] };
let MetricsFixture = datatable(TimeGenerated:datetime, Name:string, Sum:real, Properties:dynamic)
[
datetime(2026-10-08T11:55:00Z), "Prompt Cached Tokens", 100.0, dynamic({"Service ID":"apim-test","UserId":"u1","Model":"claude-haiku-4-5"}),
datetime(2026-10-08T11:56:00Z), "Prompt Cached Tokens", 25.0, dynamic({"Service ID":"apim-test","UserId":"u1","Model":"claude-haiku-4.5"}),
datetime(2026-10-09T00:01:00Z), "Prompt Cached Tokens", 50.0, dynamic({"Service ID":"apim-test","UserId":"u1","Model":"claude-haiku-4-5"}),
datetime(2026-10-08T11:55:00Z), "Prompt Cached Tokens", 99.0, dynamic({"Service ID":"apim-test","UserId":"u2","Model":"claude-sonnet-5"}),
datetime(2026-10-08T11:55:00Z), "Prompt Cached Tokens", 2.0, dynamic({"Service ID":"apim-test","UserId":"u4","Model":"prod-big"}),
datetime(2026-10-08T11:55:00Z), "Prompt Cached Tokens", 3.0, dynamic({"Service ID":"apim-test","UserId":"u5","Model":"claude-sonnet-5"}),
datetime(2026-10-08T11:55:00Z), "Prompt Cached Tokens", 4.0, dynamic({"Service ID":"apim-test","UserId":"u5","Model":"prod-big"}),
datetime(2026-10-08T11:55:00Z), "Prompt Cached Tokens", 9.0, dynamic({"Service ID":"apim-test","UserId":"u6","Model":"residual-big"}),
datetime(2026-10-08T11:55:00Z), "Prompt Cached Tokens", 50.0, dynamic({"Service ID":"apim-test","UserId":"u7","Model":"claude-sonnet-5"}),
datetime(2026-10-08T11:55:00Z), "Prompt Cached Tokens", 12.0, dynamic({"Service ID":"apim-test","UserId":"u3","Model":"claude-sonnet-5"}),
datetime(2026-10-08T11:55:00Z), "Prompt Cached Tokens", 20.0, dynamic({"Service ID":"apim-test","UserId":"tie","Model":"claude-sonnet-5"})
];
'@
$full = $fixture + "`n" + ($query -join "`n")
if ($PrintQuery) { $full; exit 0 }
if (-not $WorkspaceCustomerId) { throw '-WorkspaceCustomerId is required unless -PrintQuery is used.' }
$token = az account get-access-token --resource https://api.loganalytics.io --query accessToken -o tsv
if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'Cannot get Log Analytics token.' }
$response = Invoke-RestMethod -Uri "https://api.loganalytics.io/v1/workspaces/$WorkspaceCustomerId/query" -Method Post `
    -Headers @{ Authorization = "Bearer $token" } -ContentType 'application/json' -Body (@{ query = $full } | ConvertTo-Json -Depth 4)
$cols = @($response.tables[0].columns.name)
$rows = @($response.tables[0].rows | ForEach-Object {
    $o = [ordered]@{}
    for ($i = 0; $i -lt $cols.Count; $i++) { $o[$cols[$i]] = $_[$i] }
    [pscustomobject]$o
})
function RowDay($Row) { if ($null -eq $Row.day) { return '' }; return ([datetime]$Row.day).ToUniversalTime().ToString('yyyy-MM-dd') }
function Write-ReturnedRows {
    Write-Host 'Returned USD usage rows:' -ForegroundColor Yellow
    $rows | ForEach-Object {
        Write-Host ("  day={0} user=[{1}] dep={2} unit=[{3}] p={4} read={5} known={6} src={7} unknown={8}" -f $_.day, $_.user_id, $_.deployment, $_.business_unit, $_.prompt_tokens, $_.cache_read_tokens, $_.cache_read_known, $_.usage_source, $_.unit_unknown)
    }
}
function Assert($Name, $Condition) { if (-not $Condition) { Write-ReturnedRows; throw "USD usage query assertion failed: $Name" } }
Assert 'every row has a day' (@($rows | Where-Object { $null -eq $_.day -or (RowDay $_) -eq '' }).Count -eq 0)
Assert 'non-userless row has a user' (@($rows | Where-Object { $_.deployment -and $_.cache_read_tokens -ne 0 -and -not $_.unit_unknown -and [string]::IsNullOrWhiteSpace([string]$_.user_id) }).Count -eq 0)
$u1 = @($rows | Where-Object user_id -eq 'u1' | Where-Object { (RowDay $_) -eq '2026-10-08' })
Assert 'two stamped rows returned for u1' ($u1.Count -eq 2)
Assert 'metric remainder assigned to latest stamp only' ((@($u1 | Where-Object business_unit -eq 'finance')[0].cache_read_tokens -eq 125) -and (@($u1 | Where-Object business_unit -eq 'eng')[0].cache_read_tokens -eq 0))
Assert 'duplicate model spelling does not duplicate metered rows' (($u1 | Measure-Object prompt_tokens -Sum).Sum -eq 2)
Assert 'metric-only next day row uses latest stamp' (@($rows | Where-Object { (RowDay $_) -eq '2026-10-09' -and $_.business_unit -eq 'finance' -and $_.deployment -eq 'claude-haiku-4-5' }).Count -eq 1)
Assert 'known body reads ignore metric' (@($rows | Where-Object user_id -eq 'u2')[0].cache_read_tokens -eq 7)
Assert 'custom deployment metric joins model ledger and does not create metric-only row' ((@($rows | Where-Object { $_.user_id -eq 'u4' -and $_.deployment -eq 'prod-big' -and $_.cache_read_tokens -eq 2 }).Count -eq 1) -and (@($rows | Where-Object { $_.user_id -eq 'u4' -and $_.usage_source -eq 'metric' }).Count -eq 0))
Assert 'one user can carry two model families on one day' ((@($rows | Where-Object { $_.user_id -eq 'u5' }).Count -eq 2) -and (($rows | Where-Object user_id -eq 'u5' | Measure-Object cache_read_tokens -Sum).Sum -eq 7))
Assert 'residual empty deployment custom metric is a latest-stamp metric-only row and body reads remain' ((@($rows | Where-Object { $_.user_id -eq 'u6' -and $_.deployment -eq 'claude-opus-5-5-20260101' -and $_.cache_read_tokens -eq 5 }).Count -eq 1) -and (@($rows | Where-Object { $_.user_id -eq 'u6' -and $_.deployment -eq 'residual-big' -and $_.usage_source -eq 'metric' -and $_.business_unit -eq 'platform' -and $_.cache_read_tokens -eq 9 }).Count -eq 1))
Assert 'known-read family ignores same-family metric residual' ((@($rows | Where-Object { $_.user_id -eq 'u7' -and $_.deployment -eq 'claude-sonnet-5' -and $_.cache_read_tokens -eq 6 }).Count -eq 1) -and (@($rows | Where-Object { $_.user_id -eq 'u7' -and $_.usage_source -eq 'metric' }).Count -eq 0))
Assert 'userless row passes through' (@($rows | Where-Object { $_.user_id -eq '' }).Count -eq 1)
Assert 'metric without ledger row is unit_unknown' (@($rows | Where-Object { $_.user_id -eq 'u3' -and $_.unit_unknown -eq $true }).Count -eq 1)
$tie = @($rows | Where-Object user_id -eq 'tie')
Assert 'tied latest rows receive one metric remainder only' (($tie | Measure-Object cache_read_tokens -Sum).Sum -eq 20 -and @($tie | Where-Object { $_.cache_read_tokens -eq 20 }).Count -eq 1)
Write-Host 'USD usage query live fixture passed.'
