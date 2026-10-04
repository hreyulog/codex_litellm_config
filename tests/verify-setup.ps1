#requires -Version 5.1
param([Parameter(Mandatory)][int]$Port, [Parameter(Mandatory)][string]$CliPath)
$ErrorActionPreference = 'Stop'
$suiteRoot = Split-Path $PSScriptRoot -Parent
$testRoot = Join-Path $PSScriptRoot ('runs\' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
. (Join-Path $suiteRoot 'setup-codex-litellm.ps1') -Action Configure -CodexHome $testRoot -CodexExe $CliPath -BaseUrl "http://127.0.0.1:$Port/v1" -Model 'company-coding'
$testBundled = Invoke-LocalCodex $CliPath 'debug models --bundled' $testRoot
if ($testBundled.Code -ne 0) { throw 'Cannot read installed Codex model catalog' }
$testTemplate = ($testBundled.Out | ConvertFrom-Json).models[0]
$UpstreamModel = $testTemplate.slug

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Assertion failed: $Message" }
}
function Assert-Throws([scriptblock]$Work, [string]$Message) {
    $caught = $false
    try { & $Work } catch { $caught = $true }
    Assert $caught $Message
}
function Read-ApiKey { return 'dummy-local-test-key' }

$original = @'
# Preserve user configuration, including multiline values.
model = "old-model"
model_provider = "old-provider"
model_context_window = 999999
profile = "old-profile"
developer_instructions = """
[model_providers.company_litellm]
model = "do not edit this prompt"
"""
notify = [
    "helper.exe",
    "literal # text"
]

[desktop]
enabled-reasoning-efforts = [
  "high", "max"
]
zoom = 1.2

[mcp_servers.example]
command = "local-tool"
args = ["--foo"]

[projects.'D:\Work']
trust_level = "trusted"

[model_providers.company_litellm]
name = "Old Company API"
experimental_bearer_token = "old-local-test-secret"
[model_providers.company_litellm.http_headers]
"x-thing" = "old"

[model_providers."company_litellm.other"]
name = "unrelated quoted provider"
base_url = "https://keep.example/v1"

[model_providers.other]
name = "Other"
base_url = "https://other.example/v1"
wire_api = "responses"
env_key = "OTHER_API_KEY"

[shell_environment_policy]
inherit = "core"
'@
$originalEnv = "OTHER_API_KEY=old-other-test-key`r`nCODEX_LITELLM_API_KEY=previous-test-key`r`n"
$configPath = Join-Path $testRoot 'config.toml'
$envPath = Join-Path $testRoot '.env'
[IO.File]::WriteAllText($configPath, $original, $script:Utf8)
[IO.File]::WriteAllText($envPath, $originalEnv, $script:Utf8)
$originalConfigBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath))
$originalEnvBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($envPath))

Assert ((Get-ApiBase 'https://company.example') -eq 'https://company.example/v1') 'Root URL adds v1'
Assert ((Get-ApiBase 'https://company.example/v1/') -eq 'https://company.example/v1') 'No duplicate v1'
Assert ((Get-ApiBase 'https://company.example/gateway/v1/responses') -eq 'https://company.example/gateway/v1') 'Gateway paths preserved'
Assert ((Get-ApiBase 'https://company.example/custom-api/') -eq 'https://company.example/custom-api') 'Unknown API path preserved'
Assert-Throws { Get-ApiBase 'https://company.example/v1?api_key=secret' } 'Reject secrets in URL'
Assert-Throws { Get-ApiBase 'https://user:pass@company.example/v1' } 'Reject basic credentials in URL'
Assert-Throws { Get-TomlStatements 'prompt = """unfinished' } 'Reject unclosed strings'
Assert-Throws { Protect-ApiKey "bad`nkey" } 'Reject multiline keys'

Invoke-Setup
$configured = [IO.File]::ReadAllText($configPath)
$keyFile = [IO.File]::ReadAllText((Join-Path $testRoot 'litellm-key.dpapi'))
Assert ($configured.Contains('command = "local-tool"')) 'MCP retained'
Assert ($configured.Contains('trust_level = "trusted"')) 'Project trust retained'
Assert ($configured.Contains('zoom = 1.2')) 'Desktop other settings retained'
Assert ($configured.Contains('model = "do not edit this prompt"')) 'Multiline prompt retained'
Assert ($configured.Contains('literal # text')) 'Multiline array retained'
Assert ($configured.Contains('unrelated quoted provider')) 'Quoted provider with dot retained'
Assert ($configured.Contains('name = "Other"')) 'Other provider retained'
Assert (-not $configured.Contains('old-local-test-secret')) 'Old provider token removed'
Assert (-not $configured.Contains('dummy-local-test-key')) 'Key absent from TOML'
Assert (-not $configured.Contains('model_context_window = 999999')) 'Stale context override removed'
Assert ([IO.File]::ReadAllText($envPath) -ceq $originalEnv) 'Existing .env unchanged'
Assert (-not $keyFile.Contains('dummy-local-test-key')) 'Credential is encrypted'
$decrypted = ConvertTo-SecureString -String $keyFile
$pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($decrypted)
try { Assert ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) -ceq 'dummy-local-test-key') 'DPAPI roundtrip' }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer); $decrypted.Dispose() }
Assert (([regex]::Matches($configured, '(?m)^\[desktop\]')).Count -eq 1) 'No duplicate desktop table'
$catalog = [IO.File]::ReadAllText((Join-Path $testRoot 'litellm-models.json')) | ConvertFrom-Json
$visible = @($catalog.models | Where-Object { $_.visibility -eq 'list' -and $_.supported_in_api })
Assert ($visible.Count -eq 1 -and $visible[0].slug -eq 'company-coding') 'Picker contains selected company alias'
Assert ((Get-Acl -LiteralPath (Join-Path $testRoot 'litellm-key.dpapi')).AreAccessRulesProtected) 'Credential ACL protected'

# Rerun must be idempotent and avoid duplicate keys/tables.
Invoke-Setup
Assert ([IO.File]::ReadAllText($configPath) -ceq $configured) 'Repeated setup is idempotent'
$keyFile = [IO.File]::ReadAllText((Join-Path $testRoot 'litellm-key.dpapi'))

# Generic metadata must also load through the real installed Codex parser.
$generic = New-GenericMetadata 'unknown-company-model' 32768 $testTemplate
$genericPath = Join-Path $testRoot 'generic-models.json'
[IO.File]::WriteAllText($genericPath, (ConvertTo-Json -InputObject @{ models = @($generic) } -Depth 20), $script:Utf8)
$genericHome = Join-Path $testRoot 'generic-home'
New-Item -ItemType Directory -Path $genericHome | Out-Null
$genericConfig = Merge-CodexConfig '' "http://127.0.0.1:$Port/v1" 'unknown-company-model' $genericPath $generic (Join-Path $testRoot 'litellm-auth.ps1') (Join-Path $testRoot 'litellm-key.dpapi')
[IO.File]::WriteAllText((Join-Path $genericHome 'config.toml'), $genericConfig, $script:Utf8)
$genericResult = Invoke-LocalCodex $CliPath 'debug models' $genericHome
Assert ($genericResult.Code -eq 0) 'Generic catalog accepted'
$loadedGeneric = $genericResult.Out | ConvertFrom-Json
Assert (@($loadedGeneric.models | Where-Object { $_.slug -eq 'unknown-company-model' }).Count -eq 1) 'Validation actually loads custom catalog'

# Reject JSON-only, truncated SSE, missing Responses endpoints, and credential echoes.
Assert-Throws { Test-GatewayCompatibility "http://127.0.0.1:$Port/json-only/v1" 'dummy-local-test-key' 'company-coding' } 'Reject JSON-only endpoint'
Assert-Throws { Test-GatewayCompatibility "http://127.0.0.1:$Port/truncated/v1" 'dummy-local-test-key' 'company-coding' } 'Reject truncated SSE'
Assert-Throws { Test-GatewayCompatibility "http://127.0.0.1:$Port/chat-only/v1" 'dummy-local-test-key' 'company-coding' } 'Reject chat-only gateway'
$errorText = ''
try { Invoke-Gateway "http://127.0.0.1:$Port/unauth/v1/models" 'dummy-local-test-key' } catch { $errorText = $_.Exception.Message }
Assert ($errorText.Contains('401') -and -not $errorText.Contains('reflected-secret')) 'HTTP errors do not reveal gateway response bodies'

# API failure must leave an existing configuration and credential unchanged.
$BaseUrl = "http://127.0.0.1:$Port/chat-only/v1"
Assert-Throws { Invoke-Setup } 'Setup rejects failed gateway'
Assert ([IO.File]::ReadAllText($configPath) -ceq $configured) 'Failed setup does not modify configuration'
Assert ([IO.File]::ReadAllText((Join-Path $testRoot 'litellm-key.dpapi')) -ceq $keyFile) 'Failed setup does not modify credentials'

# Simulated filesystem failure after partial commit must roll back every file.
$BaseUrl = "http://127.0.0.1:$Port/v1"
$savedAtomicWriter = ${function:Write-Utf8Atomic}
function Write-Utf8Atomic([string]$Path, [string]$Content) {
    if ([IO.Path]::GetFileName($Path) -eq 'litellm-key.dpapi') { throw 'Injected write failure' }
    & $savedAtomicWriter $Path $Content
}
try { Assert-Throws { Invoke-Setup } 'Setup handles partial write failure' }
finally { ${function:Write-Utf8Atomic} = $savedAtomicWriter }
Assert ([IO.File]::ReadAllText($configPath) -ceq $configured) 'Rollback preserves configuration'
Assert ([IO.File]::ReadAllText((Join-Path $testRoot 'litellm-key.dpapi')) -ceq $keyFile) 'Rollback preserves exact encrypted credential'

# Restore original bytes, not just equivalent parsed values.
$Action = 'Restore'
Invoke-Setup
Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath)) -ceq $originalConfigBytes) 'Restore preserves exact config bytes'
Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($envPath)) -ceq $originalEnvBytes) 'Restore preserves exact credential bytes'
Assert (-not (Test-Path -LiteralPath (Join-Path $testRoot 'litellm-models.json'))) 'Restore removes newly created catalog'
Assert (-not (Test-Path -LiteralPath (Join-Path $testRoot 'litellm-auth.ps1'))) 'Restore removes newly created helper'
Assert (-not (Test-Path -LiteralPath (Join-Path $testRoot 'litellm-key.dpapi'))) 'Restore removes newly created credential'

Write-Host "ALL CHECKS PASSED: $testRoot" -ForegroundColor Green
