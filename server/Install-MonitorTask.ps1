# Install-MonitorTask.ps1
# Registers WatchWdSessions.ps1 as a Windows Scheduled Task
# Auto-detects path from script location - just place both files in the same directory

$taskName   = "WebDevSessionMonitor"
$scriptPath = Join-Path $PSScriptRoot "WatchWdSessions.ps1"

if (-not (Test-Path $scriptPath)) {
    Write-Host "ERROR: $scriptPath not found" -ForegroundColor Red
    exit 1
}

Write-Host "Removing old task if exists..."
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

Write-Host "Killing any running monitor process..."
Get-WmiObject Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*WatchWdSessions*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

$action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""
$trigger   = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "Monitors WD*Session runaway memory/CPU" | Out-Null

Write-Host "SUCCESS: Task '$taskName' installed" -ForegroundColor Green
Write-Host "  Script: $scriptPath" -ForegroundColor Cyan
Write-Host "  Verify: taskschd.msc" -ForegroundColor Cyan
