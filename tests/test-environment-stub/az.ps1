# Stand-in for az used by tests/Test-TestEnvironment.ps1: records every call and answers from a fixture.
$fixture = Get-Content $env:STUB_AZ_FIXTURE -Raw | ConvertFrom-Json -AsHashtable
$line = $args -join ' '
Add-Content -Path $env:STUB_AZ_LOG -Value $line
function Answer($value) { if ($null -ne $value) { Write-Output $value }; exit 0 }
switch -Regex ($line) {
    '^account show .*tenantId' { Answer '00000000-0000-4000-8000-0000000000aa' }
    '^group show -n \S+ --query tags' { if ($fixture.ContainsKey('tags')) { Answer ($fixture.tags | ConvertTo-Json -Compress) } else { [Console]::Error.WriteLine('ResourceGroupNotFound'); exit 3 } }
    '^ad group show --group (\S+) --query displayName' { $n = $fixture.groupNames[$Matches[1]]; if ($n) { Answer $n } else { exit 3 } }
    '^ad app show --id (\S+) --query displayName' { $n = $fixture.appNames[$Matches[1]]; if ($n) { Answer $n } else { exit 3 } }
    '^ad signed-in-user show' { Answer '00000000-0000-4000-8000-0000000000bb' }
    '^(ad group delete|ad app delete|group delete|group create|tag update|ad group create|ad app create)' { Answer '' }
    default { [Console]::Error.WriteLine("stub az: no answer for: $line"); exit 9 }
}
