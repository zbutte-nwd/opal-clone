# Runs the Tether server permanently on a Windows workstation as a scheduled task:
# starts at boot (no login needed, no console window), restarts if it exits, logs to data\server.log.
# Prereq: `npm run setup` done in server\. Run from an *elevated* PowerShell:
#   powershell -ExecutionPolicy Bypass -File workstation\install-windows.ps1            # install / reinstall
#   powershell -ExecutionPolicy Bypass -File workstation\install-windows.ps1 -Restart   # restart (after .env change / update)
#   powershell -ExecutionPolicy Bypass -File workstation\install-windows.ps1 -Stop      # stop until -Restart / reboot (backups)
#   powershell -ExecutionPolicy Bypass -File workstation\install-windows.ps1 -Uninstall
param([switch]$Uninstall, [switch]$Restart, [switch]$Stop)
$ErrorActionPreference = 'Stop'
$TaskName = 'Tether Server'
$ServerDir = Split-Path -Parent $PSScriptRoot

# PORT from .env (setup writes it; users may change it), default 8787.
$Port = 8787
if (Test-Path "$ServerDir\.env") {
  $m = Select-String -Path "$ServerDir\.env" -Pattern '^PORT=(\d+)\s*$' | Select-Object -First 1
  if ($m) { $Port = [int]$m.Matches[0].Groups[1].Value }
}

# Stop-ScheduledTask only ends the cmd.exe wrapper; its node child survives and keeps the port,
# so a "restarted" task can't bind. Also stop the node process listening on our port.
function Stop-TetherServer {
  Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  $owners = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty OwningProcess -Unique
  foreach ($procId in $owners) {
    $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if ($p -and $p.ProcessName -eq 'node') { Stop-Process -Id $procId -Force }
    elseif ($p) { Write-Warning "Port $Port is held by '$($p.ProcessName)' (PID $procId), not Tether - left alone. Set PORT in .env." }
  }
  for ($i = 0; $i -lt 10 -and (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 500 }
}

function Test-TetherHealth([string]$what) {
  Start-Sleep -Seconds 3
  try {
    $h = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/healthz" -TimeoutSec 5
    Write-Host "Tether server running on 127.0.0.1:$Port (version $($h.version)). Log: $ServerDir\data\server.log"
  } catch {
    Write-Warning "$what but http://127.0.0.1:$Port/healthz did not answer yet. Check $ServerDir\data\server.log"
  }
}

if ($Uninstall) {
  Stop-TetherServer
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  Write-Host "Removed scheduled task '$TaskName'."
  exit 0
}

if ($Stop) {
  Stop-TetherServer
  Write-Host "Stopped '$TaskName' (starts again at boot or with -Restart)."
  exit 0
}

if ($Restart) {
  if (-not (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) { throw "No task '$TaskName' - run this script without -Restart first." }
  Stop-TetherServer
  Start-ScheduledTask -TaskName $TaskName
  Test-TetherHealth 'Task restarted'
  exit 0
}

$node = (Get-Command node -ErrorAction Stop).Source
if (-not (Test-Path "$ServerDir\.env")) { throw "Missing $ServerDir\.env - run 'npm run setup' first." }
if (-not (Test-Path "$ServerDir\dist\index.js")) { throw "Missing dist\index.js - run 'npm run build' first." }
New-Item -ItemType Directory -Force "$ServerDir\data" | Out-Null

# cmd.exe only to redirect output; it returns node's exit code so a crash counts as a failure (-> restart).
$action = New-ScheduledTaskAction -Execute 'cmd.exe' `
  -Argument "/c `"`"$node`" dist\index.js >> data\server.log 2>&1`"" -WorkingDirectory $ServerDir
$trigger = New-ScheduledTaskTrigger -AtStartup
# S4U = run whether or not the user is logged on, without storing a password (local access only, which is all we need).
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
  -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -MultipleInstances IgnoreNew

Stop-TetherServer
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
Test-TetherHealth 'Task registered'
