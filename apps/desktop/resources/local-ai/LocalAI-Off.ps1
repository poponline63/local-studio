# LocalAI-Off.ps1 - turns ALL local AI off: unloads models, stops the extra servers from the private config, closes Local Studio (app, controller, resource monitor,
# agent sessions), stops Local Studio Docker engines, stops Ollama (tray app, server, runners), disables their
# autostart entries (recorded in state.json so LocalAI-On.ps1 can restore exactly those), then verifies.
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

# 5. Disable autostart entries for Ollama / Local Studio and record them.
if (-not $KeepAutostart) {
  $sh = New-Object -ComObject WScript.Shell
  foreach ($dir in @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup'))) {
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue)) {
      $target = ''; if ($f.Extension -eq '.lnk') { try { $target = $sh.CreateShortcut($f.FullName).TargetPath } catch {} }
      if ("$($f.Name) $target" -notmatch $AutostartPattern) { continue }
      $dest = Join-Path $DisabledDir ("{0}__{1}" -f (Get-Date -Format 'yyyyMMddHHmmss'), $f.Name)
      try { Move-Item -LiteralPath $f.FullName -Destination $dest -ErrorAction Stop; [void]$items.Add([pscustomobject]@{ type = 'startup'; original = $f.FullName; moved = $dest }); Save-OffState; Write-Host "  disabled Startup item $($f.FullName)" }
      catch { Write-Host "  COULD NOT disable Startup item $($f.FullName): $($_.Exception.Message)" -ForegroundColor Yellow }
    }
  }
  foreach ($key in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run') {
    $props = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue; if (-not $props) { continue }
    foreach ($n in $props.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' }) {
      if ("$($n.Name) $($n.Value)" -notmatch $AutostartPattern) { continue }
      try { Remove-ItemProperty -Path $key -Name $n.Name -ErrorAction Stop; [void]$items.Add([pscustomobject]@{ type = 'run'; key = $key; name = $n.Name; value = [string]$n.Value }); Save-OffState; Write-Host "  removed Run entry $key\$($n.Name)" }
      catch { Write-Host "  COULD NOT remove Run entry $key\$($n.Name) (needs admin?)" -ForegroundColor Yellow }
    }
  }
  foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.State -ne 'Disabled' })) {
    $exec = ($t.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' '
    if ($t.TaskName -notmatch $AutostartPattern -and $exec.IndexOf($OllamaDir, [StringComparison]::OrdinalIgnoreCase) -lt 0 -and $exec.IndexOf($StudioDir, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
    try { Disable-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction Stop | Out-Null; [void]$items.Add([pscustomobject]@{ type = 'task'; path = $t.TaskPath; name = $t.TaskName }); Save-OffState; Write-Host "  disabled scheduled task $($t.TaskPath)$($t.TaskName)" }
    catch { Write-Host "  COULD NOT disable task $($t.TaskName) (needs admin?)" -ForegroundColor Yellow }
  }
  foreach ($s in @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { "$($_.Name) $($_.DisplayName) $($_.PathName)" -match $AutostartPattern })) {
    if ($s.State -eq 'Running') { Stop-Service -Name $s.Name -Force -ErrorAction SilentlyContinue }
    if ($s.StartMode -ne 'Disabled') {
      try { Set-Service -Name $s.Name -StartupType Disabled -ErrorAction Stop; [void]$items.Add([pscustomobject]@{ type = 'service'; name = $s.Name; startMode = $s.StartMode }); Save-OffState; Write-Host "  disabled service $($s.Name)" }
      catch { Write-Host "  COULD NOT disable service $($s.Name) (needs admin)" -ForegroundColor Yellow }
    }
  }
}
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
