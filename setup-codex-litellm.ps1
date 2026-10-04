#requires -Version 5.1
<#
Windows Codex desktop / LiteLLM setup. No packages are installed.
Copy this folder to the company PC; run setup.cmd after installing Codex.
Secrets are entered interactively and are never accepted as command arguments.
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Configure', 'Restore')][string]$Action = 'Menu',
    [string]$BaseUrl,
    [string]$Model,
    [string]$UpstreamModel,
    [ValidateRange(4096, 2147483647)][int]$ContextWindow = 32768,
    [string]$CodexHome,
    [string]$CodexExe,
    [ValidateSet('en', 'zh-CN')][string]$Language,
    [switch]$SkipProbe
)

$ErrorActionPreference = 'Stop'
$script:ProviderId = 'company_litellm'
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:ContextWindowWasSpecified = $PSBoundParameters.ContainsKey('ContextWindow')
$script:UiLanguage = $Language
$script:ManagedFiles = @('config.toml', 'litellm-models.json', 'litellm-auth.ps1', 'litellm-key.dpapi')
$script:AuthHelper = @'
#requires -Version 5.1
param([Parameter(Mandatory)][string]$KeyFile)
$ErrorActionPreference = 'Stop'
$pointer = [IntPtr]::Zero
$secure = $null
try {
    $encrypted = [IO.File]::ReadAllText($KeyFile).Trim()
    $secure = ConvertTo-SecureString -String $encrypted
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    [Console]::Out.Write([Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer))
} catch {
    [Console]::Error.WriteLine('Cannot read the company gateway credential for this Windows user.')
    exit 1
} finally {
    if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    if ($secure) { $secure.Dispose() }
}
'@

function Get-UiText([string]$English, [string]$Chinese) {
    if ($script:UiLanguage -eq 'zh-CN') { return $Chinese }
    return $English
}

function Initialize-UiLanguage {
    if ($script:UiLanguage) { return }
    Write-Host "`nLanguage / 语言`n1. English`n2. 简体中文" -ForegroundColor Cyan
    while ($true) {
        $selection = Read-Host 'Choose / 选择 [1]'
        if (-not $selection -or $selection -eq '1') { $script:UiLanguage = 'en'; return }
        if ($selection -eq '2') { $script:UiLanguage = 'zh-CN'; return }
        Write-Host 'Please enter 1 or 2. / 请输入 1 或 2。' -ForegroundColor Yellow
    }
}

function Protect-ApiKey([string]$KeyValue) {
    if (-not $KeyValue -or $KeyValue -match '[\r\n\x00-\x1f]') { throw (Get-UiText 'The API key is empty or contains invalid control characters.' 'API Key 为空或包含换行等无效字符。') }
    $secure = ConvertTo-SecureString -String $KeyValue -AsPlainText -Force
    try { return ConvertFrom-SecureString -SecureString $secure }
    finally { $secure.Dispose() }
}

function Get-PropertyValue($Object, [string]$Name, $Default = $null) {
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) {
        return $Object.PSObject.Properties[$Name].Value
    }
    return $Default
}

function Set-PropertyValue($Object, [string]$Name, $Value) {
    $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force
}

function ConvertTo-TomlString([string]$Value) {
    # JSON string escapes used here are also valid TOML basic-string escapes.
    return ConvertTo-Json -InputObject $Value -Compress
}

function Get-ApiBase([string]$Address) {
    $uri = $null
    if (-not [Uri]::TryCreate($Address.Trim(), [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @('https', 'http') -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
        throw (Get-UiText 'Enter a complete API base URL, e.g. https://litellm.company.com/v1, without keys, query parameters or user credentials.' '请填写完整 API 地址，例如 https://litellm.company.com/v1；地址中不要带 Key、查询参数或用户名。')
    }
    $path = $uri.AbsolutePath.TrimEnd('/')
    $path = $path -replace '/(?:responses|chat/completions|models)$', ''
    if (-not $path) { $path = '/v1' }
    return $uri.GetLeftPart([UriPartial]::Authority) + $path
}

function Set-PrivateAcl([string]$Path) {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $systemSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    if (Test-Path -LiteralPath $Path -PathType Container) {
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    } else {
        $acl = New-Object Security.AccessControl.FileSecurity
        $inheritance = [Security.AccessControl.InheritanceFlags]::None
    }
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($identity in @($sid, $systemSid)) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            $identity, 'FullControl', $inheritance, 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-AccessAcl $Path $acl
}

function Set-AccessAcl([string]$Path, $Acl) {
    # Persist access rules only; restoring owner/audit sections would require
    # privileges that ordinary company users need not hold.
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        if (Test-Path -LiteralPath $Path -PathType Container) { [IO.Directory]::SetAccessControl($Path, $Acl) }
        else { [IO.File]::SetAccessControl($Path, $Acl) }
    } else {
        if (Test-Path -LiteralPath $Path -PathType Container) { [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]$Path, $Acl) }
        else { [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]$Path, $Acl) }
    }
}

function Invoke-LocalCodex([string]$Exe, [string]$Arguments, [string]$HomePath) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $Exe
    $start.Arguments = $Arguments
    $start.WorkingDirectory = $HomePath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = $script:Utf8
    $start.StandardErrorEncoding = $script:Utf8
    # A child-only home prevents validation from loading personal login or projects.
    $start.EnvironmentVariables['CODEX_HOME'] = $HomePath
    foreach ($key in @('OPENAI_API_KEY', 'CODEX_API_KEY')) {
        $start.EnvironmentVariables.Remove($key)
    }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill()
            throw (Get-UiText 'Local Codex validation timed out. Supply the bundled CLI executable, not the desktop app executable.' 'Codex 本地配置校验超时。请确认提供的是内置命令行程序，而不是桌面程序。')
        }
        return [pscustomobject]@{ Code = $process.ExitCode; Out = $outTask.Result; Err = $errTask.Result }
    } finally { $process.Dispose() }
}

function Find-CodexCli([string]$ExplicitPath) {
    if ($ExplicitPath) {
        if (-not (Test-Path -LiteralPath $ExplicitPath -PathType Leaf)) { throw (Get-UiText 'The file specified by CodexExe does not exist.' 'CodexExe 指定的文件不存在。') }
        return (Resolve-Path -LiteralPath $ExplicitPath).Path
    }
    $command = Get-Command codex.exe -ErrorAction SilentlyContinue
    if ($command -and $command.Source -notmatch '\\WindowsApps\\') { return $command.Source }
    $candidates = @()
    foreach ($root in @(
        (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Codex\resources'),
        (Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT\resources')
    )) {
        if (Test-Path -LiteralPath $root) {
            $candidates += @(Get-ChildItem -LiteralPath $root -Filter codex.exe -File -Recurse -ErrorAction SilentlyContinue)
        }
    }
    if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
        foreach ($package in @(Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'OpenAI|Codex' })) {
            $root = Join-Path $package.InstallLocation 'app\resources'
            if (Test-Path -LiteralPath $root) {
                $candidates += @(Get-ChildItem -LiteralPath $root -Filter codex.exe -File -Recurse -ErrorAction SilentlyContinue)
            }
        }
    }
    $found = $candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($found) { return $found.FullName }
    throw (Get-UiText 'Bundled Codex CLI not found. Install and open an approved current Codex Desktop version, or use -CodexExe to specify codex.exe in its resources or bin directory.' '未找到 Codex 内置 CLI。请先安装并打开公司认可的新版 Codex 桌面客户端。若安装位置不同，可使用 -CodexExe 指定其 resources 或 bin 目录中的 codex.exe。')
}

function Get-TomlStatements([string]$Text) {
    # Lexical boundaries, rather than line regexes, preserve multiline strings,
    # arrays, inline tables, and text resembling table headers inside prompts.
    $result = New-Object 'Collections.Generic.List[string]'
    $start = 0; $quote = ''; $depth = 0; $comment = $false
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($comment) {
            if ($c -ne "`n") { continue }
            $comment = $false
        } elseif ($quote) {
            if (($quote -eq '"' -or $quote -eq '"""') -and $c -eq '\') { $i++; continue }
            if ($quote.Length -eq 3) {
                if ($i + 2 -lt $Text.Length -and $Text.Substring($i, 3) -eq $quote) {
                    # TOML permits one or two quotation marks before the closing delimiter.
                    $i += 2
                    while ($i + 1 -lt $Text.Length -and $Text[$i + 1] -eq $quote[0]) { $i++ }
                    $quote = ''
                }
            } elseif ([string]$c -eq $quote) { $quote = '' }
            continue
        } else {
            if ($c -eq '#') { $comment = $true; continue }
            if ($c -eq '"' -or $c -eq "'") {
                if ($i + 2 -lt $Text.Length -and $Text.Substring($i, 3) -eq ([string]$c * 3)) {
                    $quote = [string]$c * 3; $i += 2
                } else { $quote = [string]$c }
                continue
            }
            if ($c -eq '[' -or $c -eq '{') { $depth++ }
            if ($c -eq ']' -or $c -eq '}') { $depth-- }
        }
        if ($c -eq "`n" -and $depth -eq 0) {
            $result.Add($Text.Substring($start, $i - $start + 1)); $start = $i + 1
        }
    }
    if ($quote -or $depth -ne 0) { throw (Get-UiText 'The original config.toml contains an unclosed string or bracket. Setup stopped without modifying it.' '原 config.toml 含未结束的字符串或括号，已停止，原文件未修改。') }
    if ($start -lt $Text.Length) { $result.Add($Text.Substring($start)) }
    return $result.ToArray()
}

function Get-TomlKeyPath([string]$Text) {
    $parts = New-Object 'Collections.Generic.List[string]'
    $pattern = '\G\s*(?:"((?:[^"\\]|\\.)*)"|''([^'']*)''|([A-Za-z0-9_-]+))\s*(\.|$)'
    $position = 0
    while ($position -lt $Text.Length) {
        # Match at the current offset with \G.
        $match = ([regex]$pattern).Match($Text, $position)
        if (-not $match.Success) { throw (Get-UiText 'The configuration contains an unsupported TOML key format. Setup stopped without modifying it.' '配置含不支持的 TOML 键名格式，已停止，原文件未修改。') }
        if ($match.Groups[1].Success) {
            $parts.Add((('"' + $match.Groups[1].Value + '"' | ConvertFrom-Json).Replace('%', '%25').Replace('.', '%2E')))
        } elseif ($match.Groups[2].Success) { $parts.Add($match.Groups[2].Value.Replace('%', '%25').Replace('.', '%2E')) }
        else { $parts.Add($match.Groups[3].Value) }
        $position = $match.Index + $match.Length
    }
    return ($parts -join '.')
}

function Merge-CodexConfig([string]$Original, [string]$ApiBase, [string]$ModelName,
                          [string]$CatalogPath, $Metadata, [string]$HelperPath, [string]$KeyPath) {
    $managed = @('model', 'model_provider', 'model_catalog_json', 'web_search', 'profile',
        'preferred_auth_method', 'forced_login_method', 'forced_chatgpt_workspace_id',
        'model_reasoning_effort', 'model_reasoning_summary', 'model_supports_reasoning_summaries',
        'model_verbosity', 'model_context_window', 'model_auto_compact_token_limit', 'service_tier', 'review_model')
    $kept = New-Object Text.StringBuilder
    $section = ''
    $provider = 'model_providers.' + $script:ProviderId
    $hasDesktop = $false
    $efforts = @(Get-PropertyValue $Metadata 'supported_reasoning_levels' @() | ForEach-Object { $_.effort })
    $desktopSetting = 'enabled-reasoning-efforts = ' + (ConvertTo-Json -InputObject @($efforts) -Compress)
    foreach ($statement in @(Get-TomlStatements $Original)) {
        $trimmed = $statement.Trim()
        if ($trimmed -match '^\[\[?(.+?)\]\]?\s*(?:#.*)?$') {
            $section = Get-TomlKeyPath $Matches[1]
            if ($section -eq $provider -or $section.StartsWith($provider + '.')) { continue }
            [void]$kept.Append($statement)
            if ($section -eq 'desktop') {
                $hasDesktop = $true
                if (-not $statement.EndsWith("`n")) { [void]$kept.Append("`r`n") }
                [void]$kept.AppendLine($desktopSetting)
            }
            continue
        }
        if ($section -eq $provider -or $section.StartsWith($provider + '.')) { continue }
        if ($trimmed -and -not $trimmed.StartsWith('#') -and $trimmed -match '^([^=]+)=') {
            $key = Get-TomlKeyPath ($Matches[1].Trim())
            $fullKey = if ($section) { $section + '.' + $key } else { $key }
            if (($section -eq '' -and $key -in $managed) -or
                $fullKey -eq $provider -or $fullKey.StartsWith($provider + '.') -or
                $fullKey -eq 'desktop.enabled-reasoning-efforts') { continue }
            if ($fullKey -eq 'model_providers' -or $fullKey -eq 'desktop') {
                throw (Get-UiText 'The original config uses an inline model_providers or desktop table. Convert it to [table] format and retry. The original file has not been modified.' '原配置将 model_providers 或 desktop 写成内联表。请先改成标准 [表名] 格式再运行，原文件未修改。')
            }
        }
        [void]$kept.Append($statement)
    }
    $root = New-Object 'Collections.Generic.List[string]'
    $root.Add('model = ' + (ConvertTo-TomlString $ModelName))
    $root.Add('model_provider = ' + (ConvertTo-TomlString $script:ProviderId))
    $root.Add('model_catalog_json = ' + (ConvertTo-TomlString $CatalogPath.Replace('\', '/')))
    $root.Add('model_context_window = ' + [string]$Metadata.context_window)
    $root.Add('web_search = "disabled"')
    $root.Add('model_reasoning_summary = "none"')
    $effort = Get-PropertyValue $Metadata 'default_reasoning_level'
    if ($effort -and $effort -ne 'none' -and $effort -in $efforts) {
        $root.Add('model_reasoning_effort = ' + (ConvertTo-TomlString $effort))
    }
    $providerBlock = @(
        '', ('[model_providers.' + $script:ProviderId + ']'),
        'name = "Company LiteLLM"',
        ('base_url = ' + (ConvertTo-TomlString $ApiBase)),
        'wire_api = "responses"', 'supports_websockets = false',
        'stream_idle_timeout_ms = 600000', 'request_max_retries = 2', 'stream_max_retries = 2',
        '', ('[model_providers.' + $script:ProviderId + '.auth]'),
        ('command = ' + (ConvertTo-TomlString ((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe').Replace('\', '/')))),
        ('args = ' + (ConvertTo-Json -InputObject @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $HelperPath.Replace('\', '/'), '-KeyFile', $KeyPath.Replace('\', '/')) -Compress)),
        'timeout_ms = 30000', 'refresh_interval_ms = 300000'
    ) -join "`r`n"
    $desktopBlock = if ($hasDesktop) { '' } else { "`r`n[desktop]`r`n$desktopSetting`r`n" }
    return ($root -join "`r`n") + "`r`n`r`n" + $kept.ToString().Trim([char[]]"`r`n").TrimEnd() + "`r`n" + $providerBlock + "`r`n" + $desktopBlock
}

function Read-ApiKey {
    $secure = Read-Host (Get-UiText 'Enter your company LiteLLM API key (hidden; not recorded in command history)' '输入公司的 LiteLLM API Key（隐藏输入，不会显示或写进命令历史）') -AsSecureString
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer).Trim() }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer); $secure.Dispose() }
}

function Invoke-Gateway([string]$Url, [string]$KeyValue, [string]$Method = 'Get', $Body = $null) {
    $parameters = @{
        Uri = $Url; Method = $Method; Headers = @{ Authorization = 'Bearer ' + $KeyValue }
        UseBasicParsing = $true; MaximumRedirection = 0; TimeoutSec = 90; ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $parameters.ContentType = 'application/json; charset=utf-8'
        $parameters.Body = $script:Utf8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 100 -Compress))
    }
    try { return Invoke-WebRequest @parameters }
    catch {
        $status = 0
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        $reason = switch ($status) {
            400 { Get-UiText 'Incompatible parameters or tool calls. Ask your administrator to check Responses support for this model.' '请求参数或工具调用不兼容，请让管理员检查该模型的 Responses 支持。' }
            401 { Get-UiText 'The API key is invalid or expired.' 'API Key 无效或已过期。' }
            403 { Get-UiText 'The key does not have permission to access this model or endpoint.' 'Key 没有该模型或接口的访问权限。' }
            404 { Get-UiText 'Endpoint not found. Check the API base path and whether the gateway exposes /responses.' '接口不存在，请检查 API 基础路径，以及网关是否开放 /responses。' }
            429 { Get-UiText 'Usage or concurrency limit reached. Retry later or contact your administrator.' '额度或并发限制，请稍后重试或联系管理员。' }
            0 { Get-UiText 'Network, VPN, proxy or certificate connection failed. Check company connectivity and trusted certificates.' '网络、VPN、代理或证书连接失败，请检查公司网络及受信任证书。' }
            default { Get-UiText 'The gateway could not process the request. Ask your administrator to check the service.' '网关未成功处理请求，请联系管理员检查服务。' }
        }
        # Do not print response bodies or exception details: gateways can echo credentials.
        throw (Get-UiText "Gateway request failed (HTTP $status): $reason" "网关请求失败（HTTP $status）：$reason")
    }
}

function Get-CompletedStreamResponse($HttpResponse) {
    $contentType = [string]$HttpResponse.Headers['Content-Type']
    if ($contentType -notmatch 'text/event-stream') { throw (Get-UiText 'The gateway did not return SSE. Codex requires a compatible streaming Responses endpoint.' '网关没有返回 SSE 流，Codex 需要兼容 Responses 的流式接口。') }
    $completed = $null
    foreach ($block in [regex]::Split([string]$HttpResponse.Content, '\r?\n\r?\n')) {
        $dataLines = @([regex]::Matches($block, '(?m)^data:\s?(.*)\r?$') | ForEach-Object { $_.Groups[1].Value.TrimEnd("`r") })
        if ($dataLines.Count -eq 0) { continue }
        $data = $dataLines -join "`n"
        if ($data -eq '[DONE]') { continue }
        try { $event = $data | ConvertFrom-Json } catch { throw (Get-UiText 'A gateway SSE event contains invalid JSON.' '网关的 SSE 事件包含无效 JSON。') }
        $kind = Get-PropertyValue $event 'type'
        if ($kind -in @('error', 'response.failed')) { throw (Get-UiText 'The gateway returned a streaming failure event. Ask your administrator to check model routing.' '网关在流式请求中返回失败事件，请让管理员检查模型路由。') }
        if ($kind -eq 'response.completed') { $completed = $event.response }
    }
    if ($null -eq $completed -or (Get-PropertyValue $completed 'status') -ne 'completed') {
        throw (Get-UiText 'No valid response.completed event received. Ask your administrator to check the gateway streaming protocol.' '没有收到有效 response.completed 事件，请让管理员检查网关流式协议。')
    }
    return $completed
}

function Test-GatewayCompatibility([string]$ApiBase, [string]$KeyValue, [string]$ModelName) {
    Write-Host (Get-UiText 'Checking Responses streaming, function calls and tool-result continuation (two small requests count toward company API usage)...' '正在检查 Responses 流式响应、函数调用和工具结果续接（两次简短请求，会计入公司 API 用量）...')
    $tool = @{
        type = 'function'; name = 'codex_setup_probe'; description = 'A setup connectivity test. Call with value OK.'
        parameters = @{ type = 'object'; properties = @{ value = @{ type = 'string' } }; required = @('value'); additionalProperties = $false }
    }
    $request = @{
        model = $ModelName; store = $false; stream = $true
        include = @('reasoning.encrypted_content')
        input = 'Call codex_setup_probe with value OK. This is a connectivity test.'
        tools = @($tool); tool_choice = @{ type = 'function'; name = 'codex_setup_probe' }
    }
    $first = Get-CompletedStreamResponse (Invoke-Gateway ($ApiBase + '/responses') $KeyValue 'Post' $request)
    $call = @(Get-PropertyValue $first 'output' @() | Where-Object { $_.type -eq 'function_call' -and $_.name -eq 'codex_setup_probe' }) | Select-Object -First 1
    if (-not $call -or -not $call.call_id) { throw (Get-UiText 'The model did not return the expected function call. Ask your administrator to confirm tool-call support.' '模型未返回预期函数调用，请管理员确认模型支持工具调用。') }
    try { $argsObject = $call.arguments | ConvertFrom-Json } catch { throw (Get-UiText 'The model returned invalid JSON tool arguments.' '模型返回的工具参数不是有效 JSON。') }
    if ($argsObject.value -ne 'OK') { throw (Get-UiText 'The tool arguments do not match the connectivity test requirements.' '模型返回的工具参数不符合连接测试要求。') }
    $request.input = @(
        @{ role = 'user'; content = 'Call codex_setup_probe with value OK, then acknowledge the result.' }
    ) + @($first.output) + @(
        @{ type = 'function_call_output'; call_id = $call.call_id; output = 'OK' }
    )
    $request.tool_choice = 'none'
    $second = Get-CompletedStreamResponse (Invoke-Gateway ($ApiBase + '/responses') $KeyValue 'Post' $request)
    $messages = @(Get-PropertyValue $second 'output' @() | Where-Object { $_.type -eq 'message' })
    $texts = @($messages | ForEach-Object { $_.content } | Where-Object { $_.type -eq 'output_text' -and $_.text })
    if ($texts.Count -eq 0) { throw (Get-UiText 'No text reply after submitting the tool result. Ask your administrator to check Responses conversation translation.' '工具结果续接后没有文本回复，请管理员检查 Responses 对话转换。') }
    Write-Host (Get-UiText 'Basic gateway compatibility checks passed.' '网关基础兼容性检查通过。') -ForegroundColor Green
}

function ConvertTo-ContextWindowTokens([string]$Value) {
    $text = $Value.Trim()
    $number = [long]0
    if ($text -notmatch '^(\d+)\s*([kK]?)$' -or
        -not [long]::TryParse($Matches[1], [ref]$number) -or $number -gt [int]::MaxValue) {
        throw (Get-UiText 'Enter an integer token count (e.g. 100000), or an integer followed by k (e.g. 100k); 1k = 1000 tokens.' '请输入整数 tokens（例如 100000），或整数加 k（例如 100k）；1k = 1000 tokens。')
    }
    $tokens = if ($Matches[2]) { $number * 1000 } else { $number }
    if ($tokens -lt 4096 -or $tokens -gt [int]::MaxValue) {
        throw (Get-UiText 'The context window must be between 4096 and 2147483647 tokens, within the actual capacity of your company model.' '上下文长度必须在 4096 到 2147483647 tokens 之间，并且不能超过公司模型实际支持的长度。')
    }
    return [int]$tokens
}

function Read-ContextWindow([int]$DefaultTokens) {
    Write-Host (Get-UiText 'This changes the Codex context budget, not the model capacity. Use a window supported by your company model.' '此设置只调整 Codex 的上下文预算，不会扩大模型实际容量；请使用公司模型支持的长度。')
    while ($true) {
        $value = Read-Host (Get-UiText "Context window (tokens, e.g. 100000 or 100k; Enter keeps $DefaultTokens)" "上下文长度（tokens，例如 100000 或 100k；回车默认 $DefaultTokens）")
        if ([string]::IsNullOrWhiteSpace($value)) { return $DefaultTokens }
        try { return ConvertTo-ContextWindowTokens $value }
        catch { Write-Host $_.Exception.Message -ForegroundColor Yellow }
    }
}

function New-GenericMetadata([string]$ModelName, [int]$Tokens, $Template = $null) {
    if ($Tokens -lt 4096) { throw (Get-UiText 'ContextWindow must be at least 4096. Use the window provided by your administrator.' 'ContextWindow 至少为 4096，请使用管理员提供的上下文窗口值。') }
    # Conservative capabilities, not a guess about the model behind an alias.
    $generic = [pscustomobject]@{
        slug = $ModelName; display_name = $ModelName; description = 'Company gateway model (generic metadata)'
        default_reasoning_level = 'none'; supported_reasoning_levels = @(); shell_type = 'shell_command'
        visibility = 'list'; supported_in_api = $true; priority = 1; prefer_websockets = $false
        support_verbosity = $false; default_verbosity = 'low'; apply_patch_tool_type = $null
        web_search_tool_type = 'text'; input_modalities = @('text'); supports_image_detail_original = $false
        truncation_policy = @{ mode = 'tokens'; limit = 10000 }
        supports_parallel_tool_calls = $false; context_window = $Tokens; max_context_window = $Tokens
        effective_context_window_percent = 90; default_reasoning_summary = 'none'; use_responses_lite = $false
        experimental_supported_tools = @(); model_messages = $null
        additional_speed_tiers = @(); service_tiers = @(); upgrade = $null; availability_nux = $null
        supports_search_tool = $false; supports_experimental_context = $false; supports_reasoning_effort_updates = $false
        multi_agent_version = $null; multi_agent_reasoning_effort = $null; tool_mode = $null
        base_instructions = 'You are a coding assistant running in Codex. Help the user complete their task. Use the provided tools when needed. Follow workspace instructions, preserve unrelated changes, and report what you changed and verified.'
    }
    # Retain any version-specific schema fields, while replacing capabilities
    # and instructions above. Never infer the upstream model from an alias.
    if ($Template) {
        $result = $Template | ConvertTo-Json -Depth 100 -Compress | ConvertFrom-Json
        foreach ($property in $generic.PSObject.Properties) { Set-PropertyValue $result $property.Name $property.Value }
        return $result
    }
    return $generic
}

function New-FileSnapshot([string]$HomePath, [string]$SnapshotPath) {
    New-Item -ItemType Directory -Path $SnapshotPath -Force | Out-Null
    Set-PrivateAcl $SnapshotPath
    $files = @()
    foreach ($name in $script:ManagedFiles) {
        $path = Join-Path $HomePath $name
        $exists = Test-Path -LiteralPath $path -PathType Leaf
        $sddl = $null
        if ($exists) {
            Copy-Item -LiteralPath $path -Destination (Join-Path $SnapshotPath $name)
            $sddl = (Get-Acl -LiteralPath $path).Sddl
        }
        $files += @{ name = $name; existed = $exists; acl = $sddl }
    }
    [IO.File]::WriteAllText((Join-Path $SnapshotPath 'manifest.json'), (ConvertTo-Json -InputObject @{ files = $files } -Depth 8), $script:Utf8)
}

function Restore-FileSnapshot([string]$HomePath, [string]$SnapshotPath) {
    $manifest = Get-Content -LiteralPath (Join-Path $SnapshotPath 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($record in $manifest.files) {
        if ($record.name -notin $script:ManagedFiles) { throw (Get-UiText 'Invalid backup manifest.' '备份清单无效。') }
        $target = Join-Path $HomePath $record.name
        if ($record.existed) {
            [IO.File]::WriteAllBytes($target, [IO.File]::ReadAllBytes((Join-Path $SnapshotPath $record.name)))
            if ($record.acl) {
                $acl = New-Object Security.AccessControl.FileSecurity
                $acl.SetSecurityDescriptorSddlForm($record.acl, [Security.AccessControl.AccessControlSections]::Access)
                Set-AccessAcl $target $acl
            }
        } elseif (Test-Path -LiteralPath $target -PathType Leaf) {
            Remove-Item -LiteralPath $target -Force
        }
    }
}

function Write-Utf8Atomic([string]$Path, [string]$Content) {
    $temp = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        if ([IO.Path]::GetFileName($Path) -eq 'litellm-key.dpapi') {
            [IO.File]::Create($temp).Dispose()
            Set-PrivateAcl $temp
        }
        [IO.File]::WriteAllText($temp, $Content, $script:Utf8)
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp, $Path, [System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temp, $Path) }
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
}

function Invoke-Setup {
    Initialize-UiLanguage
    if ($env:OS -ne 'Windows_NT') { throw (Get-UiText 'This script is for Windows.' '此脚本用于 Windows。') }
    $homePath = $CodexHome
    if (-not $homePath) { $homePath = $env:CODEX_HOME }
    if (-not $homePath) { $homePath = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex' }
    $homePath = [IO.Path]::GetFullPath($homePath)
    if (-not (Test-Path -LiteralPath $homePath -PathType Container)) {
        throw (Get-UiText 'Install and open Codex Desktop once to create the .codex configuration directory, then rerun setup.' '请先安装并打开一次 Codex 桌面客户端，让它创建 .codex 配置目录，然后再运行脚本。')
    }
    Write-Host (Get-UiText "`nCodex Desktop -> Company LiteLLM setup" "`nCodex 桌面版 → 公司 LiteLLM 配置") -ForegroundColor Cyan
    Write-Host (Get-UiText "Configuration directory: $homePath" "配置目录：$homePath")
    Write-Host (Get-UiText 'Save your work and fully exit Codex Desktop. Reopen it and start a new chat after setup.' '请先保存工作并完全退出 Codex 桌面客户端，配置完成后重新打开并新建聊天。')
    $choice = $Action
    if ($choice -eq 'Menu') {
        Write-Host (Get-UiText "`n1. Configure company API`n9. Restore the original configuration (back up current files first)`n0. Exit" "`n1. 配置公司 API`n9. 恢复首次运行前的配置（先备份当前文件）`n0. 退出")
        $answer = Read-Host (Get-UiText 'Select [default 1]' '选择 [默认 1]')
        if ($answer -eq '0') { return }
        if ($answer -eq '9') { $choice = 'Restore' }
        elseif (-not $answer -or $answer -eq '1') { $choice = 'Configure' }
        else { throw (Get-UiText 'Select 1, 9 or 0.' '请选择 1、9 或 0。') }
    }
    $backupRoot = Join-Path $homePath 'backup-litellm'
    $initial = Join-Path $backupRoot 'initial'
    $snapshot = Join-Path $backupRoot ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    if ($choice -eq 'Restore') {
        if (-not (Test-Path -LiteralPath (Join-Path $initial 'manifest.json'))) { throw (Get-UiText 'No backup from before the first setup was found.' '没有找到首次配置前的备份。') }
        New-FileSnapshot $homePath $snapshot
        try { Restore-FileSnapshot $homePath $initial }
        catch { Restore-FileSnapshot $homePath $snapshot; throw (Get-UiText 'Restore failed. Files were rolled back to their state before this restore operation.' '恢复失败，已回滚到恢复操作前的状态。') }
        Write-Host (Get-UiText "Restore complete. Backup of the current files: $snapshot" "恢复完成。当前文件的额外备份：$snapshot") -ForegroundColor Green
        Write-Host (Get-UiText 'Fully exit and reopen Codex, then verify with a new chat.' '完全退出并重新打开 Codex，使用新聊天验证。')
        return
    }
    $exe = Find-CodexCli $CodexExe
    $work = Join-Path ([IO.Path]::GetTempPath()) ('codex-litellm-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    $keyValue = $null
    try {
        Set-PrivateAcl $work
        $versionResult = Invoke-LocalCodex $exe '--version' $work
        if ($versionResult.Code -ne 0 -or $versionResult.Out -notmatch '(\d+\.\d+\.\d+)') { throw (Get-UiText 'Could not read the Codex CLI version. Update the desktop app.' '未能读取 Codex CLI 版本，请更新客户端。') }
        $version = $Matches[1]
        if ([version]$version -lt [version]'0.160.0') { throw (Get-UiText 'Bundled CLI 0.160.0 or later is required. Update your company-approved Codex Desktop app.' '此脚本需要内置 CLI 0.160.0 或更新版本，请更新公司认可的 Codex 桌面客户端。') }
        Write-Host (Get-UiText "Found bundled Codex CLI: $version" "找到内置 Codex CLI：$version")
        $bundledResult = Invoke-LocalCodex $exe 'debug models --bundled' $work
        if ($bundledResult.Code -ne 0) { throw (Get-UiText 'This client cannot read its bundled model catalog. Update your company-approved Codex Desktop version.' '客户端不支持读取内置模型目录。请更新公司认可的 Codex 桌面版本。') }
        $bundled = $bundledResult.Out | ConvertFrom-Json
        if (-not (Get-PropertyValue $bundled 'models')) { throw (Get-UiText 'Unexpected bundled Codex model catalog format.' 'Codex 内置模型目录格式不符合预期。') }
        $address = $BaseUrl
        if (-not $address) { $address = Read-Host (Get-UiText 'Company LiteLLM API base URL (e.g. https://litellm.company.com/v1)' '公司 LiteLLM API 基础地址（例如 https://litellm.company.com/v1）') }
        $apiBase = Get-ApiBase $address
        Write-Host (Get-UiText "Connecting to: $apiBase/responses" "将连接：$apiBase/responses")
        if ($apiBase.StartsWith('http://')) { Write-Host (Get-UiText 'This URL uses HTTP. Your key will be sent over an unencrypted connection; verify that this is the intended company URL.' '此地址使用 HTTP，Key 会通过未加密连接发送；请确认这是公司的预期地址。') -ForegroundColor Yellow }
        Write-Host (Get-UiText 'The key is encrypted locally with Windows DPAPI and read by the Codex credential helper, including after restart.' 'Key 将用 Windows DPAPI 加密保存在本机，由 Codex 的本地认证命令读取，重启后仍可使用。')
        $keyValue = Read-ApiKey
        if (-not $keyValue) { throw (Get-UiText 'The API key cannot be empty.' 'API Key 不能为空。') }
        $remoteModels = @(); $remoteCatalog = @()
        try {
            $listing = (Invoke-Gateway ($apiBase + '/models?client_version=' + [Uri]::EscapeDataString($version)) $keyValue).Content | ConvertFrom-Json
            $remoteCatalog = @(Get-PropertyValue $listing 'models' @())
            if ($remoteCatalog.Count -gt 0) { $remoteModels = @($remoteCatalog | ForEach-Object { $_.slug }) }
            else { $remoteModels = @(Get-PropertyValue $listing 'data' @() | ForEach-Object { $_.id }) }
            $remoteModels = @($remoteModels | Where-Object { $_ } | Select-Object -Unique)
        } catch { Write-Host (Get-UiText 'Could not retrieve the model list. You can enter the alias supplied by your administrator manually.' '无法读取模型列表，可继续手动填写管理员提供的模型别名。') -ForegroundColor Yellow }
        $modelName = $Model
        if (-not $modelName) {
            for ($i = 0; $i -lt $remoteModels.Count; $i++) { Write-Host ('{0}. {1}' -f ($i + 1), $remoteModels[$i]) }
            $modelName = Read-Host (Get-UiText 'Enter a model number or the complete company model alias' '输入模型编号或公司提供的完整模型别名')
            $number = 0
            if ([int]::TryParse($modelName, [ref]$number) -and $number -ge 1 -and $number -le $remoteModels.Count) {
                $modelName = $remoteModels[$number - 1]
            }
        }
        if (-not $modelName -or $modelName -match '[\r\n\x00-\x1f]') { throw (Get-UiText 'The model alias cannot be empty or contain control characters.' '模型别名不能为空或包含换行。') }
        $metadata = $remoteCatalog | Where-Object { $_.slug -ceq $modelName } | Select-Object -First 1
        if (-not $metadata) { $metadata = $bundled.models | Where-Object { $_.slug -ceq $modelName } | Select-Object -First 1 }
        if (-not $metadata) {
            $upstream = $UpstreamModel
            if (-not $upstream) {
                Write-Host (Get-UiText 'This alias has no Codex metadata. If it maps to a bundled OpenAI model, enter that model name; otherwise press Enter for generic metadata.' '该别名没有 Codex 元数据。若对应内置 OpenAI 模型，请填写实际模型名；不了解时直接回车使用通用配置。')
                Write-Host ((Get-UiText 'Bundled models: ' '内置模型：') + (($bundled.models | ForEach-Object { $_.slug }) -join ', '))
                $upstream = Read-Host (Get-UiText 'Underlying model name [optional]' '实际模型名 [可留空]')
            }
            if ($upstream) {
                $metadata = $bundled.models | Where-Object { $_.slug -ceq $upstream } | Select-Object -First 1
                if (-not $metadata) { throw (Get-UiText 'That model is not in the bundled catalog. Leave it blank for generic metadata, or obtain a Codex catalog from your administrator.' '实际模型名不在客户端内置目录中。请留空使用通用配置，或由管理员提供 Codex 模型目录。') }
            } else {
                Write-Host (Get-UiText 'Using generic text/function-call metadata.' '使用通用文本/函数调用配置。')
                $metadata = New-GenericMetadata $modelName $ContextWindow $bundled.models[0]
            }
        }
        $metadata = $metadata | ConvertTo-Json -Depth 100 -Compress | ConvertFrom-Json
        $contextTokens = if ($script:ContextWindowWasSpecified) { $ContextWindow }
                         else { Read-ContextWindow ([int](Get-PropertyValue $metadata 'context_window' $ContextWindow)) }
        Set-PropertyValue $metadata 'context_window' $contextTokens
        Set-PropertyValue $metadata 'max_context_window' $contextTokens
        Write-Host (Get-UiText "Codex context window set to $contextTokens tokens; usable budget reserves space for prompts, tools and output." "Codex 上下文窗口设置为 $contextTokens tokens；实际可用预算还会预留系统提示、工具和输出空间。")
        Set-PropertyValue $metadata 'slug' $modelName
        Set-PropertyValue $metadata 'display_name' $modelName
        Set-PropertyValue $metadata 'visibility' 'list'
        Set-PropertyValue $metadata 'supported_in_api' $true
        Set-PropertyValue $metadata 'prefer_websockets' $false
        Set-PropertyValue $metadata 'default_reasoning_summary' 'none'
        # Retain the version-matched bundled metadata for internal model lookups;
        # show only the selected company alias in the desktop model picker.
        $catalogModels = @($bundled.models | Where-Object { $_.slug -cne $modelName } | ForEach-Object {
            Set-PropertyValue $_ 'visibility' 'hide'; Set-PropertyValue $_ 'supported_in_api' $false; $_
        }) + @($metadata)
        $catalogJson = ConvertTo-Json -InputObject @{ models = $catalogModels } -Depth 100
        $configPath = Join-Path $homePath 'config.toml'
        $catalogPath = Join-Path $homePath 'litellm-models.json'
        $helperPath = Join-Path $homePath 'litellm-auth.ps1'
        $keyPath = Join-Path $homePath 'litellm-key.dpapi'
        $original = if (Test-Path -LiteralPath $configPath) { [IO.File]::ReadAllText($configPath) } else { '' }
        $newConfig = Merge-CodexConfig $original $apiBase $modelName $catalogPath $metadata $helperPath $keyPath
        $encryptedKey = Protect-ApiKey $keyValue
        # Validate TOML and the catalog using Codex itself in the private temp home.
        $tempCatalog = Join-Path $work 'litellm-models.json'
        [IO.File]::WriteAllText($tempCatalog, $catalogJson, $script:Utf8)
        $validationConfig = Merge-CodexConfig $original $apiBase $modelName $tempCatalog $metadata $helperPath $keyPath
        [IO.File]::WriteAllText((Join-Path $work 'config.toml'), $validationConfig, $script:Utf8)
        $checked = Invoke-LocalCodex $exe 'debug models' $work
        $tomlChecked = Invoke-LocalCodex $exe 'features list' $work
        if ($checked.Code -ne 0 -or $tomlChecked.Code -ne 0) {
            throw (Get-UiText 'Generated configuration failed Codex validation. Original files were not modified. Check the original config or update the client and retry.' '生成的配置未通过 Codex 内置校验，原文件未修改。请检查原配置是否有效，或更新客户端后重试。')
        }
        $loadedCatalog = $checked.Out | ConvertFrom-Json
        if (@($loadedCatalog.models | Where-Object { $_.slug -ceq $modelName }).Count -ne 1) {
            throw (Get-UiText 'Codex could not load the generated company model catalog. Original files were not modified.' 'Codex 未能读取生成的公司模型目录，原文件未修改。')
        }
        if (-not $SkipProbe) { Test-GatewayCompatibility $apiBase $keyValue $modelName }
        else { Write-Host (Get-UiText 'Gateway compatibility checks skipped; connectivity has not been verified.' '已跳过网关兼容性检查；能否运行尚未验证。') -ForegroundColor Yellow }
        $currentConfig = if (Test-Path -LiteralPath $configPath) { [IO.File]::ReadAllText($configPath) } else { '' }
        if ($currentConfig -cne $original) {
            throw (Get-UiText 'The original configuration changed during validation. Setup stopped writing. Fully exit Codex and retry.' '检查期间原配置发生变化，已停止写入。请完全退出 Codex 后重新运行。')
        }
        if (-not (Test-Path -LiteralPath (Join-Path $initial 'manifest.json'))) { New-FileSnapshot $homePath $initial }
        New-FileSnapshot $homePath $snapshot
        try {
            Write-Utf8Atomic $catalogPath $catalogJson
            Write-Utf8Atomic $helperPath $script:AuthHelper
            Set-PrivateAcl $helperPath
            Write-Utf8Atomic $keyPath $encryptedKey
            Set-PrivateAcl $keyPath
            Write-Utf8Atomic $configPath $newConfig
        } catch {
            try { Restore-FileSnapshot $homePath $snapshot }
            catch { throw (Get-UiText "Writing and automatic rollback failed. Restore files from this backup: $snapshot" "写入失败，自动回滚也未完成。请从此备份恢复文件：$snapshot") }
            throw (Get-UiText 'Writing failed. Files were restored to their state before this setup run.' '写入失败，已恢复本次运行前的文件。')
        }
        Write-Host (Get-UiText "`nSetup complete: Company LiteLLM / $modelName" "`n配置完成：Company LiteLLM / $modelName") -ForegroundColor Green
        Write-Host (Get-UiText "Backup: $snapshot" "备份：$snapshot")
        Write-Host (Get-UiText 'Fully exit and reopen Codex, select the company model and start a new chat. Complete initialization if prompted on first launch.' '完全退出并重新打开 Codex，选择该公司模型并新建聊天。首次启动按客户端提示完成初始化。')
        Write-Host (Get-UiText 'Rerun setup to change models. Menu option 9 restores complete managed files from before the first setup.' '若需更换模型，重新运行本脚本；菜单 9 恢复首次配置前的完整文件。')
    } finally {
        $keyValue = $null
        # Only this randomly named, explicitly resolved temp directory is removed.
        $resolved = [IO.Path]::GetFullPath($work)
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
            [IO.Path]::GetFileName($resolved).StartsWith('codex-litellm-')) {
            Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-Setup }
    catch { Write-Host ((Get-UiText "`nSetup failed: " "`n配置失败：") + $_.Exception.Message) -ForegroundColor Red; exit 1 }
}
