# LocalAI-On.ps1 - starts the local-AI stack for this session only (never re-enables autostart): Ollama (headless
# 'ollama serve', cloud disabled, never the tray app) and Local Studio, and waits until 11434 (Ollama) and 18091 (Local Studio controller) answer.
# Extra servers (private config, see LocalAI-Common.ps1): -Extra starts those with startOnLaunch (default true),
# -NoExtra starts none; default = only those that were running when Off ran.
# -NoStudio is used by Local Studio itself (the in-app Local AI switch runs this at launch).
param([switch]$Pause, [switch]$NoStudio, [switch]$Extra, [switch]$NoExtra)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'LocalAI-Common.ps1')
New-Item -ItemType Directory -Force $LogDir | Out-Null
Start-Transcript -Path (Join-Path $LogDir 'last-on.log') -Force | Out-Null
Write-Host "== Local AI ON ==  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
$rc = 0

# 1. Never restore autostart entries: Local AI only runs while Local Studio is open (or when started by hand) and never
#    starts with Windows. The 'disabled' list in state.json is kept as a record only.
$state = Read-State
$record = @(@($state.disabled) | Where-Object { $_ })
function Save-OnState { [IO.File]::WriteAllText($StateFile, ([pscustomobject]@{ state = 'on'; changedAt = (Get-Date).ToString('s'); extraWasRunning = @($state.extraWasRunning); disabled = @($record) } | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false)) }
Save-OnState

# Environment for everything started from here: local-only discovery shim on PATH, Ollama cloud disabled.
Initialize-LsofShim
if (($env:Path -split ';') -notcontains $BinDir) { $env:Path = "$BinDir;$env:Path" }
$env:OLLAMA_NO_CLOUD = '1'

# 2. Ollama server (headless, no tray app).
if (-not (Test-PortOpen 11434)) {
  Write-Host "  starting ollama serve (OLLAMA_NO_CLOUD=1)"
  $log = Join-Path $LogDir 'ollama-serve.log'
  Start-Process -FilePath $env:ComSpec -ArgumentList "/c `"`"$OllamaExe`" serve > `"$log`" 2>&1`"" -WindowStyle Hidden
} else { Write-Host "  Ollama already listening on 11434" }
for ($i = 0; $i -lt 60 -and -not (Test-PortOpen 11434); $i++) { Start-Sleep 1 }
if (Test-PortOpen 11434) {
  $ver = $null; for ($i = 0; $i -lt 15 -and -not $ver; $i++) { try { $ver = (Invoke-RestMethod 'http://127.0.0.1:11434/api/version' -TimeoutSec 5).version } catch { Start-Sleep 1 } }
  Write-Host "  Ollama $ver is up on 11434" -ForegroundColor Green
  try { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Update-PiModels.ps1') | Write-Host } catch {}
} else { Write-Host "  Ollama did NOT come up on 11434 (see $LogDir\ollama-serve.log)" -ForegroundColor Red; $rc = 1 }

# 2b. Extra local servers from the private config.
$wantExtra = @()
if (-not $NoExtra) {
  if ($Extra) { $wantExtra = @($ExtraServers | Where-Object { $_.startOnLaunch -ne $false }) }
  elseif ($state -and $state.extraWasRunning) { $was = @($state.extraWasRunning); $wantExtra = @($ExtraServers | Where-Object { $was -contains [string]$_.name }) }
}
foreach ($x in $wantExtra) {
  if (-not (Test-PortOpen ([int]$x.port))) { Write-Host "  starting extra server $($x.name) (port $($x.port))"; if (-not (Start-ExtraServer $x)) { $rc = 1; continue } }
  # wait until it really serves (readyPath, default /v1/models); otherwise the Local Studio controller may cache it as "not a model server"
  $timeout = if ($x.readyTimeoutSec) { [int]$x.readyTimeoutSec } else { 300 }
  $ready = $false; for ($k = 0; $k -lt $timeout -and -not $ready; $k++) { $ready = Test-ExtraServerReady $x; if (-not $ready) { Start-Sleep 1 } }
  if ($ready) { Write-Host "  $($x.name) is up on $($x.port)" -ForegroundColor Green } else { Write-Host "  $($x.name) did NOT come up on $($x.port)" -ForegroundColor Red; $rc = 1 }
}
if ($ExtraServers -and -not $wantExtra) { Write-Host "  extra servers: none started (not requested / not running before Off)" }

# 3. Local Studio (starts its controller on 18091).
if (-not $NoStudio) {
  if (-not (Get-Process 'Local Studio' -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$StudioDir*" })) { Write-Host "  starting Local Studio"; Start-Process -FilePath $StudioExe }
  for ($i = 0; $i -lt 90 -and -not (Test-PortOpen 18091); $i++) { Start-Sleep 1 }
  if (Test-PortOpen 18091) {
    Write-Host "  Local Studio controller is up on 18091" -ForegroundColor Green
    $models = $null
    for ($i = 0; $i -lt 20; $i++) { $models = Get-ModelsFromController; if ($models.Count -gt 1) { break }; Start-Sleep 2 }
    Write-Host "  controller /v1/models: $(@($models) -join ', ')"
  } else { Write-Host "  Local Studio controller did NOT come up on 18091" -ForegroundColor Red; $rc = 1 }
}
# 4. Anything started above (or an Ollama update/installer) must not have (re)created an autostart entry.
$new = @(Disable-LocalAIAutostart)
if ($new) { $record = @($record) + $new; Save-OnState }
$left = @(Get-LocalAIAutostart)
if ($left) { Write-Host "  WARNING - autostart entries still present: $($left -join '; ')" -ForegroundColor Yellow } else { Write-Host "  autostart: none (Local AI will not start with Windows)" }
Write-Host ""
if ($rc -eq 0) { Write-Host "OK - Local AI is ON." -ForegroundColor Green } else { Write-Host "Local AI started with problems (see above)." -ForegroundColor Red }
Stop-Transcript | Out-Null
if ($Pause) { Read-Host 'Press Enter to close' | Out-Null }
exit $rc
