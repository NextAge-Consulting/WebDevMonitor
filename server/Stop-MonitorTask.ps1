# Stop-MonitorTask.ps1
# Stops the WatchWdSessions monitor so you can update files

$taskName = "WebDevSessionMonitor"

Write-Host "Stopping scheduled task..."
Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

Write-Host "Killing any running monitor process..."
Get-WmiObject Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*WatchWdSessions*' } |
    ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Host "  Killed PID $($_.ProcessId)"
    }

Write-Host "Done. Copy your files, then run Install-MonitorTask.ps1 to restart." -ForegroundColor Green
