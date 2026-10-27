# Regenerates the Pi local-only model list from the running Ollama (excludes :cloud and embedding models), plus one
# provider per extra server in the private config (%USERPROFILE%\.local-studio-t3\local-ai-extra.json, "pi" block).
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LocalAI-Common.ps1')
$zero = [ordered]@{ input = 0; output = 0; cacheRead = 0; cacheWrite = 0 }
$compat = [ordered]@{ supportsDeveloperRole = $false; supportsStore = $false; supportsReasoningEffort = $false; maxTokensField = 'max_tokens' }
$reasoningPattern = if ($ExtraConfig -and $ExtraConfig.ollamaReasoningPattern) { [string]$ExtraConfig.ollamaReasoningPattern } else { 'qwen|deepseek-r1' }
$tags = (Invoke-RestMethod http://127.0.0.1:11434/api/tags -TimeoutSec 10).models
$models = @()
foreach ($m in ($tags | Sort-Object name)) {
  if ($m.name -match ':cloud$' -or $m.remote_host -or $m.name -match 'embed') { continue }
  $fam = "$($m.details.family) $($m.details.families -join ' ')"
  if ($fam -match 'bert') { continue }
  $id = $m.name -replace ':latest$', ''
  $models += [ordered]@{ id = $id; name = "$id (local)"; contextWindow = 32768; maxTokens = 8192; reasoning = [bool]($id -match $reasoningPattern); input = @('text'); cost = $zero }
}
$providers = [ordered]@{ 'local-ollama' = [ordered]@{ name = 'Local Ollama (this PC)'; baseUrl = 'http://127.0.0.1:11434/v1'; api = 'openai-completions'; apiKey = 'ollama'; compat = $compat; models = $models } }
foreach ($x in $ExtraServers) {
  if (-not $x.pi) { continue }
  $pid_ = if ($x.pi.provider) { [string]$x.pi.provider } else { 'local-' + ([string]$x.name -replace '[^A-Za-z0-9-]', '-').ToLowerInvariant() }
  $base = if ($x.gatewayBaseUrl) { [string]$x.gatewayBaseUrl } else { "http://127.0.0.1:$([int]$x.port)/v1" }
  $pm = @(@($x.pi.models) | Where-Object { $_.id } | ForEach-Object {
    [ordered]@{ id = [string]$_.id; name = $(if ($_.name) { [string]$_.name } else { "$($_.id) (local)" }); contextWindow = $(if ($_.contextWindow) { [int]$_.contextWindow } else { 16384 }); maxTokens = $(if ($_.maxTokens) { [int]$_.maxTokens } else { 4096 }); reasoning = [bool]$_.reasoning; input = $(if ($_.input) { @($_.input) } else { @('text') }); cost = $zero } })
  $providers[$pid_] = [ordered]@{ name = $(if ($x.pi.name) { [string]$x.pi.name } else { "$($x.name) (this PC, :$($x.port))" }); baseUrl = $base; api = 'openai-completions'; apiKey = 'none'; compat = $compat; models = $pm }
}
$dir = Join-Path $LocalAI 'pi-agent'
New-Item -ItemType Directory -Force $dir | Out-Null
[IO.File]::WriteAllText("$dir\models.json", ([ordered]@{ providers = $providers } | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding $false))
$s = "$dir\settings.json"
if (-not (Test-Path $s) -and $models) {
  [IO.File]::WriteAllText($s, (([ordered]@{ defaultProvider = 'local-ollama'; defaultModel = [string]$models[0].id; enabledModels = @($providers.Keys | ForEach-Object { "$_/*" }); enableInstallTelemetry = $false } | ConvertTo-Json)), (New-Object Text.UTF8Encoding $false))
}
"Pi local models: " + (@($providers.Keys | ForEach-Object { $k = $_; @($providers[$k].models) | ForEach-Object { "$k/$($_.id)" } }) -join ', ')
