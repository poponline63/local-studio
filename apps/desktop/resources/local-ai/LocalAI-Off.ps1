# LocalAI-Off.ps1 - turns ALL local AI off: unloads models, stops the extra servers from the private config, closes Local Studio (app, controller, resource monitor,
# agent sessions), stops Local Studio Docker engines, stops Ollama (tray app, server, runners), disables their
# autostart entries (permanently - LocalAI-On.ps1 never restores them; state.json keeps a record), then verifies.
# -AfterExit <pid>: wait for that process (Local Studio's main process, when the in-app switch is used) to exit first.
param([switch]$Pause, [switch]$KeepAutostart, [int]$AfterExit = 0)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'LocalAI-Common.ps1')
New-Item -ItemType Directory -Force $LogDir, $DisabledDir | Out-Null
Start-Transcript -Path (Join-Path $LogDir 'last-off.log') -Force | Out-Null
Write-Host "== Local AI OFF ==  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
if ($AfterExit -gt 0) {
  Write-Host "  waiting for Local Studio (pid $AfterExit) to quit"
  for ($i = 0; $i -lt 60 -and (Get-Process -Id $AfterExit -ErrorAction SilentlyContinue); $i++) { Start-Sleep 1 }
}

# 0. Remember which extra servers were running, so On (without -Extra) only restarts those.
$prev = Read-State
$running = @(Get-LocalAIProcesses)
$extraWasRunning = @($ExtraServers | Where-Object { $n = $_.name; (Test-PortOpen ([int]$_.port)) -or @($running | Where-Object { $_.Role -like "Extra server*: $n" }).Count -gt 0 } | ForEach-Object { [string]$_.name })
if (-not $extraWasRunning -and $prev -and $prev.state -eq 'off' -and $prev.extraWasRunning) { $extraWasRunning = @($prev.extraWasRunning) }
if ($ExtraServers) { Write-Host "  extra servers running before Off: $(if ($extraWasRunning) { $extraWasRunning -join ', ' } else { 'none' })" }
$items = New-Object System.Collections.ArrayList
if ($prev -and $prev.disabled) { foreach ($x in $prev.disabled) { if ($x) { [void]$items.Add($x) } } }
function Save-OffState { [IO.File]::WriteAllText($StateFile, ([pscustomobject]@{ state = 'off'; changedAt = (Get-Date).ToString('s'); extraWasRunning = @($extraWasRunning); disabled = @($items) } | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false)) }
Save-OffState

# 1. Unload models from VRAM while the server is still up.
if (Test-PortOpen 11434) {
  try {
    foreach ($m in @((Invoke-RestMethod 'http://127.0.0.1:11434/api/ps' -TimeoutSec 5).models)) {
      Write-Host "  unloading model $($m.name)"; & $OllamaExe stop $m.name 2>&1 | Out-Null
    }
  } catch { Write-Host "  (could not list loaded models: $($_.Exception.Message))" }
}

# 2. Stop Local Studio-launched Docker engines (label local-studio-t3.job only).
foreach ($cid in Get-StudioContainers) { Write-Host "  stopping Local Studio container $cid"; docker stop -t 15 $cid 2>&1 | Out-Null }

# 3. Graceful close.
$procs = Get-LocalAIProcesses
foreach ($p in $procs | Where-Object { $_.Role -eq 'Local Studio' -and $_.Name -eq 'Local Studio.exe' }) {
  $gp = Get-Process -Id $p.Id -ErrorAction SilentlyContinue
  if ($gp -and $gp.MainWindowHandle -ne 0) { Write-Host "  closing Local Studio window (pid $($p.Id))"; [void]$gp.CloseMainWindow() }
}
foreach ($p in $procs | Where-Object { $_.Name -eq 'ollama app.exe' }) { Write-Host "  asking Ollama tray app to quit (pid $($p.Id))"; & taskkill.exe /PID $p.Id 2>&1 | Out-Null }
for ($i = 0; $i -lt 8 -and (Get-Process 'Local Studio','ollama app' -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$StudioDir*" -or $_.Path -like "$OllamaDir*" }); $i++) { Start-Sleep 1 }

# 4. Force-kill whatever is left (up to 4 rounds, in case something respawns).
for ($round = 1; $round -le 4; $round++) {
  $left = Get-LocalAIProcesses
  if (-not $left) { break }
  # tray app first so it can't respawn the server
  foreach ($p in ($left | Sort-Object @{e = { if ($_.Name -eq 'ollama app.exe') { 0 } elseif ($_.Name -eq 'Local Studio.exe') { 1 } else { 2 } } })) {
    Write-Host ("  force-stopping {0} (pid {1}) [{2}]" -f $p.Name, $p.Id, $p.Role)
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    if (Get-Process -Id $p.Id -ErrorAction SilentlyContinue) { & taskkill.exe /F /T /PID $p.Id 2>&1 | Out-Null }
  }
  Start-Sleep 2
}

# 5. Disable/remove autostart entries for Ollama / Local Studio / extra servers (kept off permanently; recorded in state.json).
if (-not $KeepAutostart) { foreach ($x in @(Disable-LocalAIAutostart -StopServices)) { [void]$items.Add($x) } }
Save-OffState

# 6. Verify.
Start-Sleep 1
$left = Get-LocalAIProcesses
$lsn = Get-PortListeners
$open = @($Ports | Where-Object { Test-PortOpen $_ })
$cont = @(Get-StudioContainers)
Write-Host ""
Write-Host "Autostart entries disabled by this tool: $($items.Count)"
if (-not $left -and -not $lsn -and -not $open -and -not $cont) {
  Write-Host "OK - Local AI is OFF. No Local Studio / Ollama / extra-server / Pi processes; ports $($Ports -join ', ') are closed." -ForegroundColor Green
  $rc = 0
} else {
  Write-Host "WARNING - still running:" -ForegroundColor Red
  $left | Format-Table Id, Name, Role -AutoSize | Out-String | Write-Host
  $lsn | Format-Table -AutoSize | Out-String | Write-Host
  if ($open) { Write-Host "  ports still answering: $($open -join ', ')" }
  if ($cont) { Write-Host "  Local Studio containers still running: $($cont -join ', ')" }
  $rc = 1
}
Stop-Transcript | Out-Null
if ($Pause) { Read-Host 'Press Enter to close' | Out-Null }
exit $rc
