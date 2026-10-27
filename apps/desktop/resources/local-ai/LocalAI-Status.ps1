# LocalAI-Status.ps1 - shows whether local AI is ON or OFF, its processes, ports, loaded models and VRAM.
param([switch]$Pause)
. (Join-Path $PSScriptRoot 'LocalAI-Common.ps1')
$procs = Get-LocalAIProcesses
$lsn = Get-PortListeners
$open  = @($Ports | Where-Object { Test-PortOpen $_ })
$cont  = @(Get-StudioContainers)
$state = Read-State
$status = if (-not $procs -and -not $open -and -not $lsn -and -not $cont) { 'OFF' } elseif ((Test-PortOpen 11434) -and (Test-PortOpen 18091)) { 'ON' } else { 'PARTIAL' }
$color = @{ OFF = 'Yellow'; ON = 'Green'; PARTIAL = 'Red' }[$status]
Write-Host "== Local AI status: $status ==  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor $color
Write-Host ""
Write-Host "Processes ($(@($procs).Count)):"
if ($procs) { $procs | ForEach-Object { $gp = Get-Process -Id $_.Id -ErrorAction SilentlyContinue; [pscustomobject]@{ Pid = $_.Id; Name = $_.Name; Role = $_.Role; 'RAM MB' = [int]($gp.WorkingSet64 / 1MB) } } | Format-Table -AutoSize | Out-String -Width 200 | Write-Host } else { Write-Host "  none" }
Write-Host "Ports:"
foreach ($p in $Ports) { $l = $lsn | Where-Object Port -eq $p; Write-Host ("  {0,-6} {1}" -f $p, $(if ($l) { "LISTENING ($($l.Address), pid $($l.Pid) $($l.Process))" } elseif ($open -contains $p) { 'answering' } else { 'closed' })) }
if ($cont) { Write-Host "Local Studio Docker engines running: $($cont -join ', ')" }
if (Test-PortOpen 11434) {
  try { $loaded = @((Invoke-RestMethod 'http://127.0.0.1:11434/api/ps' -TimeoutSec 5).models); Write-Host "Models loaded in memory: $(if ($loaded) { ($loaded | ForEach-Object { '{0} ({1:N1} GB VRAM)' -f $_.name, ($_.size_vram / 1GB) }) -join ', ' } else { 'none' })" } catch {}
}
$auto = @(Get-LocalAIAutostart)
Write-Host "Autostart entries for local AI: $(if ($auto) { $auto -join '; ' } else { 'none (nothing starts with Windows)' })"
Write-Host "Autostart entries ever disabled by LocalAI (record): $(@($state.disabled | Where-Object { $_ }).Count)"
$smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if ($smi) {
  Write-Host "GPU:"
  & nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv,noheader | ForEach-Object { Write-Host "  $_" }
} else { Write-Host "GPU: nvidia-smi not found" }
if ($Pause) { Read-Host 'Press Enter to close' | Out-Null }
