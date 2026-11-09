# Runs the Tether server permanently on a Windows workstation as a scheduled task:
# starts at boot (no login needed, no console window), restarts if it exits, logs to data\server.log.
# Prereq: `npm run setup` done in server\. Run from an *elevated* PowerShell:
#   powershell -ExecutionPolicy Bypass -File workstation\install-windows.ps1            # install / reinstall
#   powershell -ExecutionPolicy Bypass -File workstation\install-windows.ps1 -Uninstall
param([switch]$Uninstall)
$ErrorActionPreference = 'Stop'
$TaskName = 'Tether Server'
$ServerDir = Split-Path -Parent $PSScriptRoot

if ($Uninstall) {
  Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  Write-Host "Removed scheduled task '$TaskName'."
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

Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 3

$port = (Select-String -Path "$ServerDir\.env" -Pattern '^PORT=(\d+)' | Select-Object -First 1).Matches.Groups[1].Value
if (-not $port) { $port = '8787' }
try {
  $h = Invoke-RestMethod -Uri "http://127.0.0.1:$port/healthz" -TimeoutSec 5
  Write-Host "Tether server running (version $($h.version)). Log: $ServerDir\data\server.log"
} catch {
  Write-Warning "Task registered but /healthz did not answer yet. Check $ServerDir\data\server.log"
}
