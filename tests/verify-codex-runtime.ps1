param([Parameter(Mandatory)][int]$Port, [Parameter(Mandatory)][string]$CliPath)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'setup-codex-litellm.ps1')
$runtimeHome = Join-Path $PSScriptRoot ('runtime-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $runtimeHome | Out-Null
$testBundled = Invoke-LocalCodex $CliPath 'debug models --bundled' $runtimeHome
if ($testBundled.Code -ne 0) { throw 'Cannot read installed Codex model catalog' }
$testTemplate = ($testBundled.Out | ConvertFrom-Json).models[0]
$modelInfo = New-GenericMetadata 'runtime-company-alias' 32768 $testTemplate
$catalogPath = Join-Path $runtimeHome 'models.json'
[IO.File]::WriteAllText($catalogPath, (ConvertTo-Json -InputObject @{ models = @($modelInfo) } -Depth 30), $script:Utf8)
$helperPath = Join-Path $runtimeHome 'litellm-auth.ps1'
$keyPath = Join-Path $runtimeHome 'litellm-key.dpapi'
$runtimeConfig = Merge-CodexConfig '' "http://127.0.0.1:$Port/cli/v1" 'runtime-company-alias' $catalogPath $modelInfo $helperPath $keyPath
$runtimeConfig += "`r`n[analytics]`r`nenabled = false`r`n"
[IO.File]::WriteAllText((Join-Path $runtimeHome 'config.toml'), $runtimeConfig, $script:Utf8)
[IO.File]::WriteAllText($helperPath, $script:AuthHelper, $script:Utf8)
[IO.File]::WriteAllText($keyPath, (Protect-ApiKey 'dummy-local-test-key'), $script:Utf8)
$result = Invoke-LocalCodex $CliPath 'exec --ephemeral --skip-git-repo-check --json "Reply OK without using any tools."' $runtimeHome
if ($result.Code -ne 0) {
    Write-Host $result.Out
    Write-Host $result.Err
    throw "Real Codex runtime failed with code $($result.Code)"
}
$events = @($result.Out -split '\r?\n' | Where-Object { $_.StartsWith('{') } | ForEach-Object { $_ | ConvertFrom-Json })
if (@($events | Where-Object { $_.type -eq 'turn.completed' }).Count -ne 1) { throw 'Real Codex did not complete the turn' }
$lastRequest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'mock-requests.jsonl') -Tail 1 -Encoding UTF8 | ConvertFrom-Json
if (-not $lastRequest.auth_ok -or $lastRequest.body.model -ne 'runtime-company-alias') { throw 'Codex did not read the DPAPI key or use the configured model alias' }
Write-Host 'REAL CODEX RUNTIME PASSED: DPAPI credential, custom model alias, gateway routing, completed SSE turn' -ForegroundColor Green
Write-Host ('Advertised tool types: ' + (($lastRequest.body.tools | ForEach-Object { $_.type } | Select-Object -Unique) -join ', '))
