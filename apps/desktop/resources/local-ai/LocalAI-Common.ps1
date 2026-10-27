# Shared helpers for LocalAI-On / LocalAI-Off / LocalAI-Status. Dot-sourced; do not run directly.
# State/logs/Pi live in %USERPROFILE%\LocalAI (override with LOCALAI_HOME). The scripts themselves may run from
# there or from Local Studio's resources\local-ai folder (the in-app Local AI switch).
$LocalAI     = if ($env:LOCALAI_HOME) { $env:LOCALAI_HOME } else { Join-Path $env:USERPROFILE 'LocalAI' }
$StateFile   = Join-Path $LocalAI 'state.json'
$DisabledDir = Join-Path $LocalAI 'disabled-autostart'
$LogDir      = Join-Path $LocalAI 'logs'
$OllamaDir   = Join-Path $env:LOCALAPPDATA 'Programs\Ollama'
$OllamaExe   = Join-Path $OllamaDir 'ollama.exe'
$StudioDir   = Join-Path $env:LOCALAPPDATA 'Programs\local-studio'
$StudioExe   = Join-Path $StudioDir 'Local Studio.exe'
$PiDir       = Join-Path $LocalAI 'pi'
$BinDir      = Join-Path $LocalAI 'bin'
# Optional extra local model servers (llama.cpp llama-server, vLLM, ...) come from a PRIVATE per-user config that is
# never part of this repo: %USERPROFILE%\.local-studio-t3\local-ai-extra.json (override with LOCALAI_EXTRA_CONFIG).
# See local-ai-extra.example.json next to these scripts for the format.
$ExtraConfigPath = if ($env:LOCALAI_EXTRA_CONFIG) { $env:LOCALAI_EXTRA_CONFIG } else { Join-Path $env:USERPROFILE '.local-studio-t3\local-ai-extra.json' }
function Expand-LocalAIPath([string]$p) { if (-not $p) { return $p }; [Environment]::ExpandEnvironmentVariables($p) }
function Get-ExtraConfig {
  if (-not (Test-Path -LiteralPath $ExtraConfigPath)) { return $null }
  try { Get-Content -LiteralPath $ExtraConfigPath -Raw | ConvertFrom-Json } catch { Write-Host "  (could not read $ExtraConfigPath : $($_.Exception.Message))" -ForegroundColor Yellow; $null }
}
$ExtraConfig  = Get-ExtraConfig
$ExtraServers = @(@($ExtraConfig.servers) | Where-Object { $_ -and $_.name -and $_.port })
$Ports       = @(@(11434, 18091) + @($ExtraServers | ForEach-Object { [int]$_.port }))   # Ollama, Local Studio controller, extra servers
# Autostart entries are only touched if their name/target matches this (Ollama or Local Studio).
$AutostartPattern = 'ollama|local[ -]?studio'
$DockerLabel = 'local-studio-t3.job'

function Test-PortOpen([int]$Port) {
  $c = New-Object Net.Sockets.TcpClient
  try { $iar = $c.BeginConnect('127.0.0.1', $Port, $null, $null); if ($iar.AsyncWaitHandle.WaitOne(800)) { $c.EndConnect($iar); return $true } ; return $false }
  catch { return $false } finally { $c.Close() }
}

function Get-PortListeners {
  @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $Ports -contains $_.LocalPort -and @('127.0.0.1','0.0.0.0','::','::1') -contains $_.LocalAddress } |
    Sort-Object LocalPort -Unique | ForEach-Object {
      $p = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
      [pscustomobject]@{ Port = $_.LocalPort; Address = $_.LocalAddress; Pid = $_.OwningProcess; Process = $p.Name } })
}

# Every process that belongs to the local-AI stack:
#  - anything running from the Local Studio or Ollama install dirs (app, controller, resource monitor, ollama app, ollama serve, llama-server runners)
#  - the isolated local Pi agent (%USERPROFILE%\LocalAI\pi) and its wrapper
#  - every descendant of Local Studio (agent sessions, terminals it opened), plus orphaned git.exe it left on .local-studio-t3
#  - extra servers from the private config: processes under their processPathPrefixes or matching commandLinePatterns
#  - whatever owns one of $Ports on loopback/any (listeners bound only to another interface, e.g. a VPN proxy, are ignored)
function Get-LocalAIProcesses {
  $all = @(Get-CimInstance Win32_Process)
  $byParent = @{}
  foreach ($p in $all) { $k = [string]$p.ParentProcessId; if (-not $byParent.ContainsKey($k)) { $byParent[$k] = New-Object System.Collections.ArrayList }; [void]$byParent[$k].Add($p) }
  $ids = @{}; foreach ($p in $all) { $ids[[string]$p.ProcessId] = $true }
  $hit = @{}
  foreach ($p in $all) {
    $path = [string]$p.ExecutablePath; $cmd = [string]$p.CommandLine; $why = $null
    if ($path -and $path.StartsWith($StudioDir, [StringComparison]::OrdinalIgnoreCase)) { $why = 'Local Studio' }
    elseif ($path -and $path.StartsWith($OllamaDir, [StringComparison]::OrdinalIgnoreCase)) { $why = 'Ollama' }
    elseif ($cmd.IndexOf($PiDir + '\', [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $cmd -match 'pi-local\.cmd') { $why = 'Pi agent (local)' }
    elseif ($cmd -match 'LocalAI-On\.ps1') { $why = 'Local AI On script' }
    elseif ($p.Name -eq 'git.exe' -and $cmd.IndexOf('.local-studio-t3', [StringComparison]::OrdinalIgnoreCase) -ge 0 -and -not $ids.ContainsKey([string]$p.ParentProcessId)) { $why = 'Local Studio orphan (git)' }
    if (-not $why) {
      foreach ($x in $ExtraServers) {
        foreach ($pre in @($x.processPathPrefixes)) { $pre = Expand-LocalAIPath $pre; if ($pre -and $path -and $path.StartsWith($pre, [StringComparison]::OrdinalIgnoreCase)) { $why = "Extra server: $($x.name)"; break } }
        if (-not $why) { foreach ($pat in @($x.commandLinePatterns)) { if ($pat -and $cmd -match $pat) { $why = "Extra server launcher: $($x.name)"; break } } }
        if ($why) { break }
      }
    }
    if ($why) { $hit[[string]$p.ProcessId] = [pscustomobject]@{ Id = [int]$p.ProcessId; Name = $p.Name; Role = $why; Path = $path } }
  }
  $queue = New-Object System.Collections.Queue
  foreach ($h in @($hit.Values | Where-Object { $_.Role -eq 'Local Studio' })) { $queue.Enqueue([string]$h.Id) }
  while ($queue.Count -gt 0) {
    $id = $queue.Dequeue()
    if (-not $byParent.ContainsKey($id)) { continue }
    foreach ($c in $byParent[$id]) {
      $k = [string]$c.ProcessId
      if ($hit.ContainsKey($k) -or $k -eq $id) { continue }
      $hit[$k] = [pscustomobject]@{ Id = [int]$c.ProcessId; Name = $c.Name; Role = 'Local Studio child'; Path = [string]$c.ExecutablePath }
      $queue.Enqueue($k)
    }
  }
  foreach ($l in Get-PortListeners) {
    $k = [string]$l.Pid
    if ($l.Pid -gt 4 -and -not $hit.ContainsKey($k)) { $hit[$k] = [pscustomobject]@{ Id = [int]$l.Pid; Name = $l.Process; Role = "listener on :$($l.Port)"; Path = '' } }
  }
  @($hit.Values | Where-Object { $_.Id -ne $PID } | Sort-Object Role, Id)
}

function Get-StudioContainers {
  # Local Studio registry launches run as Docker containers labelled local-studio-t3.job. Never touches other containers.
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return @() }
  if (-not (Get-Process 'com.docker.backend','Docker Desktop','dockerd' -ErrorAction SilentlyContinue)) { return @() }
  $j = Start-Job { param($lbl) docker ps -q --filter "label=$lbl" 2>$null } -ArgumentList $DockerLabel
  if (Wait-Job $j -Timeout 15) { $ids = @(Receive-Job $j | Where-Object { $_ }) } else { $ids = @() }
  Remove-Job $j -Force
  $ids
}

function Read-State { if (Test-Path $StateFile) { Get-Content $StateFile -Raw | ConvertFrom-Json } else { $null } }
function Get-ModelsFromController {
  $cfgPath = Join-Path $env:USERPROFILE '.local-studio-t3\config.json'
  if (-not (Test-Path $cfgPath)) { return $null }
  $key = (Get-Content $cfgPath -Raw | ConvertFrom-Json).fleetKey   # never printed
  try { @((Invoke-RestMethod 'http://127.0.0.1:18091/v1/models' -Headers @{ Authorization = "Bearer $key" } -TimeoutSec 5).data.id) } catch { $null }
}

# Builds the allowlisted lsof shim (lets the Local Studio controller discover Ollama, extra servers and 18100-18299 on Windows).
function Initialize-LsofShim {
  $exe = Join-Path $BinDir 'lsof.exe'
  $src = @((Join-Path $PSScriptRoot 'lsof-shim.cs'), (Join-Path $BinDir 'lsof-shim.cs')) | Where-Object { Test-Path $_ } | Select-Object -First 1
  if ((Test-Path $exe) -and (-not $src -or (Get-Item $exe).LastWriteTime -ge (Get-Item $src).LastWriteTime)) { return }
  $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
  if (-not $src -or -not (Test-Path $csc)) { Write-Host '  (lsof shim not built: csc.exe or lsof-shim.cs missing)'; return }
  New-Item -ItemType Directory -Force $BinDir | Out-Null
  & $csc /nologo /optimize /out:$exe $src | Out-Null
  if (Test-Path $exe) { Write-Host "  built $exe" }
}

# Starts one extra server from the private config (start.file: .vbs via wscript, .cmd/.bat via cmd, else the exe itself).
function Start-ExtraServer($x) {
  $file = Expand-LocalAIPath ([string]$x.start.file)
  if (-not $file -or -not (Test-Path -LiteralPath $file)) { Write-Host "  $($x.name): start.file not found ($file)" -ForegroundColor Yellow; return $false }
  $argv = @(@($x.start.args) | Where-Object { $_ } | ForEach-Object { Expand-LocalAIPath ([string]$_) })
  $ext = [IO.Path]::GetExtension($file).ToLowerInvariant()
  $wd = Split-Path -Parent $file
  if ($ext -eq '.vbs') { Start-Process -FilePath "$env:WINDIR\System32\wscript.exe" -ArgumentList (@('"' + $file + '"') + $argv) -WorkingDirectory $wd }
  elseif ($ext -in '.cmd', '.bat') { Start-Process -FilePath $env:ComSpec -ArgumentList (@('/c', '"' + $file + '"') + $argv) -WorkingDirectory $wd -WindowStyle Hidden }
  else { if ($argv) { Start-Process -FilePath $file -ArgumentList $argv -WorkingDirectory $wd -WindowStyle Hidden } else { Start-Process -FilePath $file -WorkingDirectory $wd -WindowStyle Hidden } }
  $true
}
function Test-ExtraServerReady($x) {
  $path = if ($x.readyPath) { [string]$x.readyPath } else { '/v1/models' }
  try { $r = Invoke-WebRequest ("http://127.0.0.1:{0}{1}" -f [int]$x.port, $path) -UseBasicParsing -TimeoutSec 3; $r.StatusCode -eq 200 } catch { $false }
}
