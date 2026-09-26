# WatchWdSessions.ps1 - v4.5
# Monitors WD*Session.exe processes for runaway memory and/or CPU usage
# Supports monitor-only mode for safe observation before enabling kills
# Configuration loaded from config.json (same directory as script)

# ===== LOAD CONFIGURATION =====
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $scriptDir "config.json"

if (-not (Test-Path $configPath)) {
    Write-Error "Config file not found: $configPath"
    exit 1
}

try {
    $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
} catch {
    Write-Error "Failed to parse config.json: $($_.Exception.Message)"
    exit 1
}

$processPattern    = $cfg.processPattern
$basePath          = $cfg.basePath
$mode              = $cfg.mode
$logLevel          = $cfg.logLevel
$memKillImmediate  = [int]$cfg.memKillImmediate
$memKillSustained  = [int]$cfg.memKillSustained
$cpuThresholdPct   = [int]$cfg.cpuThresholdPct
$confirmSeconds    = [int]$cfg.confirmSeconds
$checkIntervalMs   = [int]$cfg.checkIntervalMs
$memCheckIntervalMs = [int]$cfg.memCheckIntervalMs   # 0/missing = no fast memory pass
$staleMinutes      = [int]$cfg.staleMinutes
$wmiTimeoutSec     = [int]$cfg.wmiTimeoutSec
$heartbeatMinutes  = [int]$cfg.heartbeatMinutes
$logMaxMB          = [int]$cfg.logMaxMB
$dailySummary      = [bool]$cfg.dailySummary
$detailsOnKill     = [bool]$cfg.detailsOnKill
$nonWdCpuGapPct    = [int]$cfg.nonWdCpuGapPct
$nonWdCpuTopN      = [int]$cfg.nonWdCpuTopN
# ===== END CONFIGURATION =====

$logFile  = Join-Path $basePath "wd_sessions.log"
$numCores = [Environment]::ProcessorCount
$detailsOnKillSamples = [math]::Ceiling(($heartbeatMinutes * 60) / ($checkIntervalMs / 1000))

# Ensure log directory exists
if (-not (Test-Path $basePath)) {
    New-Item -Path $basePath -ItemType Directory -Force | Out-Null
}

# State
# PID -> @{ FirstSeen = [datetime]; Reason = [string]; State = "tracking" | "would-kill" }
$tracking = @{}
$lastHeartbeat = Get-Date

# Heartbeat/daily counters
$spikeCount = 0       # FIRST-SIGHTING events since last heartbeat
$killCount = 0        # Kills since last heartbeat
$dailySpikes = 0      # FIRST-SIGHTING events today
$dailyKills = 0       # Kills today
$dailyUniquePids = @{} # Unique PIDs seen today
$dailyPeakMem = 0     # Peak memory seen today (MB)
$dailyPeakPid = 0     # PID with peak memory today
$lastDate = (Get-Date).Date

# Details-on-kill ring buffer: PID -> [array of @{ Time; CPU; Mem }]
$ringBuffer = @{}

function Rotate-Log {
    if ($logMaxMB -gt 0 -and (Test-Path $logFile)) {
        $size = (Get-Item $logFile -ErrorAction SilentlyContinue).Length
        if ($size -ge ($logMaxMB * 1MB)) {
            $bakFile = "$logFile.bak"
            Move-Item -Path $logFile -Destination $bakFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-Log($message) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logFile -Value "$ts $message" -ErrorAction SilentlyContinue
}

function Add-RingSample($procId, $cpu, $mem) {
    if (-not $detailsOnKill) { return }
    if (-not $ringBuffer.ContainsKey($procId)) {
        $ringBuffer[$procId] = [System.Collections.ArrayList]::new()
    }
    $buf = $ringBuffer[$procId]
    [void]$buf.Add(@{ Time = (Get-Date); CPU = $cpu; Mem = $mem })
    while ($buf.Count -gt $detailsOnKillSamples) { $buf.RemoveAt(0) }
}

function Write-KillDetails($procId) {
    if (-not $detailsOnKill) { return }
    if (-not $ringBuffer.ContainsKey($procId)) { return }
    $buf = $ringBuffer[$procId]
    if ($buf.Count -eq 0) { return }

    $spikes = ($buf | Where-Object { $_.CPU -ge $cpuThresholdPct -or $_.Mem -ge $memKillSustained }).Count
    $peakCpu = ($buf | Measure-Object -Property CPU -Maximum).Maximum
    $peakMem = ($buf | Measure-Object -Property Mem -Maximum).Maximum
    Write-Log "  DETAIL PID:$procId SAMPLES:$($buf.Count) SPIKES:$spikes PEAK_CPU:$peakCpu% PEAK_MEM:${peakMem}MB"

    foreach ($sample in $buf) {
        Write-Log "  SAMPLE PID:$procId TIME:$(($sample.Time).ToString('HH:mm:ss')) CPU:$($sample.CPU)% MEM:$($sample.Mem)MB"
    }
}

function Remove-RingPid($procId) {
    if ($detailsOnKill -and $ringBuffer.ContainsKey($procId)) {
        $ringBuffer.Remove($procId)
    }
}

function Get-ProcessAge($procId) {
    try {
        $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if ($p -and $p.StartTime) {
            $age = (Get-Date) - $p.StartTime
            if ($age.TotalHours -ge 1) {
                return "$([math]::Floor($age.TotalHours))h$([math]::Floor($age.Minutes))m"
            }
            return "$([math]::Floor($age.TotalMinutes))m"
        }
    } catch { }
    return "unknown"
}

# Log startup
# Fast memory pass runs only when it is faster than the full cycle and there is an immediate threshold to check
$fastMemPass = ($memCheckIntervalMs -gt 0) -and ($memCheckIntervalMs -lt $checkIntervalMs) -and ($memKillImmediate -gt 0)

Write-Log "MONITOR STARTED v4.5 (Fast Memory Check)"
Write-Log "CONFIG PATTERN:$processPattern MODE:$mode LOGLEVEL:$logLevel MEM_IMMEDIATE:${memKillImmediate}MB MEM_SUSTAINED:${memKillSustained}MB CPU:${cpuThresholdPct}% CONFIRM:${confirmSeconds}s CORES:$numCores DETAILS_ON_KILL:$detailsOnKill($detailsOnKillSamples samples)"
Write-Log "CONFIG CHECK_INTERVAL:${checkIntervalMs}ms MEM_CHECK_INTERVAL:$(if ($fastMemPass) { "${memCheckIntervalMs}ms" } else { 'off' })"
Write-Log "CONFIG NON_WD_CPU_GAP:${nonWdCpuGapPct}% NON_WD_CPU_TOPN:$nonWdCpuTopN"
Write-Log "CONFIG_FILE:$configPath"

# Startup notes for disabled thresholds
if ($memKillImmediate -eq 0) { Write-Log "NOTE MEM_IMMEDIATE:DISABLED" }
if ($memKillSustained -eq 0) { Write-Log "NOTE MEM_SUSTAINED:DISABLED" }
if ($cpuThresholdPct -eq 0)  { Write-Log "NOTE CPU_THRESHOLD:DISABLED" }
if ($nonWdCpuGapPct -eq 0)   { Write-Log "NOTE NON_WD_CPU_GAP:DISABLED" }

try {
    while ($true) {
        $now = Get-Date

        # Daily summary at date boundary
        if ($dailySummary -and $now.Date -ne $lastDate) {
            $peakStr = if ($dailyPeakPid -gt 0) { "PID:$dailyPeakPid/${dailyPeakMem}MB" } else { "none" }
            Write-Log "DAILY-SUMMARY DATE:$($lastDate.ToString('yyyy-MM-dd')) SPIKES:$dailySpikes KILLS:$dailyKills UNIQUE_PIDS:$($dailyUniquePids.Count) PEAK_MEM:$peakStr"
            # Reset daily counters
            $dailySpikes = 0
            $dailyKills = 0
            $dailyUniquePids = @{}
            $dailyPeakMem = 0
            $dailyPeakPid = 0
            $lastDate = $now.Date
        }

        # 1. Clean stale tracking entries (only "tracking" state, not "would-kill")
        $stalePids = @($tracking.Keys | Where-Object {
            $tracking[$_].State -eq "tracking" -and ($now - $tracking[$_].FirstSeen).TotalMinutes -gt $staleMinutes
        })
        foreach ($procId in $stalePids) { $tracking.Remove($procId) }

        # 2. Get process memory via Get-Process
        $procs = @()
        try {
            $procs = @(Get-Process -Name $processPattern -ErrorAction SilentlyContinue)
        }
        catch { }

        # 3. Get CPU % from Windows performance counters (same source as Task Manager)
        $cpuByPid = @{}
        if ($cpuThresholdPct -gt 0) {
            try {
                $cimOpts = New-CimSessionOption -Protocol Dcom
                $cimSess = New-CimSession -SessionOption $cimOpts -OperationTimeoutSec $wmiTimeoutSec -ErrorAction Stop
                try {
                    Get-CimInstance Win32_PerfFormattedData_PerfProc_Process `
                        -Filter "Name LIKE 'WD%Session%'" `
                        -CimSession $cimSess `
                        -OperationTimeoutSec $wmiTimeoutSec `
                        -ErrorAction SilentlyContinue |
                    ForEach-Object {
                        $cpuByPid[[int]$_.IDProcess] = [math]::Round($_.PercentProcessorTime / $numCores, 1)
                    }
                }
                finally {
                    Remove-CimSession $cimSess -ErrorAction SilentlyContinue
                }
            }
            catch [Microsoft.Management.Infrastructure.CimException] {
                Write-Log "WMI-TIMEOUT CPU query exceeded ${wmiTimeoutSec}s - memory monitoring continues"
            }
            catch {
                $errMsg = $_.Exception.Message
                if ($errMsg.Length -gt 80) { $errMsg = $errMsg.Substring(0, 80) }
                Write-Log "WMI-ERROR $errMsg"
            }
        }

        $activePids = @{}

        # 4. Evaluate each process
        foreach ($proc in $procs) {
            if ($null -eq $proc) { continue }
            $procId = $proc.Id
            $activePids[$procId] = $true

            $memMB  = [math]::Round($proc.WorkingSet64 / 1MB, 1)
            $cpuPct = if ($cpuByPid.ContainsKey($procId)) { $cpuByPid[$procId] } else { 0 }

            # Record to ring buffer (if detailsOnKill enabled)
            Add-RingSample $procId $cpuPct $memMB

            # Track peak memory for daily summary
            if ($memMB -gt $dailyPeakMem) {
                $dailyPeakMem = $memMB
                $dailyPeakPid = $procId
            }

            # Check two-tier memory thresholds
            $memImmediate = ($memKillImmediate -gt 0) -and ($memMB -ge $memKillImmediate)
            $memSustained = ($memKillSustained -gt 0) -and ($memMB -ge $memKillSustained)
            $cpuViolation = ($cpuThresholdPct -gt 0) -and ($cpuPct -ge $cpuThresholdPct)

            if ($memImmediate) {
                # Immediate kill — no confirm window
                $reason = if ($cpuViolation) { "MEMORY+CPU" } else { "MEMORY" }
                $age = Get-ProcessAge $procId
                $dailyUniquePids[$procId] = $true

                if ($mode -eq "kill") {
                    Write-Log "KILLING PID:$procId MEM:${memMB}MB CPU:$cpuPct REASON:$reason AGE:$age (IMMEDIATE)"
                    Write-KillDetails $procId
                    try {
                        Stop-Process -Id $procId -Force -ErrorAction Stop
                        Write-Log "KILLED PID:$procId"
                        $killCount++
                        $dailyKills++
                    }
                    catch {
                        $errMsg = $_.Exception.Message
                        if ($errMsg.Length -gt 80) { $errMsg = $errMsg.Substring(0, 80) }
                        Write-Log "KILL-FAILED PID:$procId $errMsg"
                    }
                    $tracking.Remove($procId)
                    Remove-RingPid $procId
                }
                else {
                    # Monitor mode: log WOULD-KILL once, then track for RECOVERED/PROCESS-GONE
                    if (-not $tracking.ContainsKey($procId)) {
                        $tracking[$procId] = @{ FirstSeen = $now; Reason = $reason; State = "would-kill" }
                        $spikeCount++
                        $dailySpikes++
                        Write-Log "WOULD-KILL PID:$procId MEM:${memMB}MB CPU:$cpuPct REASON:$reason AGE:$age (IMMEDIATE, MONITOR MODE)"
                        Write-KillDetails $procId
                    }
                    elseif ($tracking[$procId].State -ne "would-kill") {
                        $tracking[$procId].State = "would-kill"
                        $tracking[$procId].Reason = $reason
                        Write-Log "WOULD-KILL PID:$procId MEM:${memMB}MB CPU:$cpuPct REASON:$reason AGE:$age (IMMEDIATE, MONITOR MODE)"
                        Write-KillDetails $procId
                    }
                    # Already in would-kill state: no additional log
                }
                continue
            }

            if ($memSustained -or $cpuViolation) {
                # Determine reason
                if ($memSustained -and $cpuViolation) { $reason = "MEMORY+CPU" }
                elseif ($memSustained)                { $reason = "MEMORY" }
                else                                  { $reason = "CPU" }

                if (-not $tracking.ContainsKey($procId)) {
                    # First sighting
                    $tracking[$procId] = @{ FirstSeen = $now; Reason = $reason; State = "tracking" }
                    $spikeCount++
                    $dailySpikes++
                    $dailyUniquePids[$procId] = $true
                    if ($logLevel -eq "detail") {
                        Write-Log "FIRST-SIGHTING PID:$procId MEM:${memMB}MB CPU:$cpuPct REASON:$reason"
                    }
                }
                else {
                    $entry = $tracking[$procId]

                    # If was in would-kill state and still above threshold, no additional log
                    if ($entry.State -eq "would-kill") { continue }

                    # Already tracked - check sustained duration
                    $duration = [math]::Round(($now - $entry.FirstSeen).TotalSeconds, 1)

                    if ($duration -ge $confirmSeconds) {
                        $age = Get-ProcessAge $procId

                        if ($mode -eq "kill") {
                            Write-Log "KILLING PID:$procId MEM:${memMB}MB DUR:${duration}s CPU:$cpuPct REASON:$reason AGE:$age"
                            Write-KillDetails $procId
                            try {
                                Stop-Process -Id $procId -Force -ErrorAction Stop
                                Write-Log "KILLED PID:$procId"
                                $killCount++
                                $dailyKills++
                            }
                            catch {
                                $errMsg = $_.Exception.Message
                                if ($errMsg.Length -gt 80) { $errMsg = $errMsg.Substring(0, 80) }
                                Write-Log "KILL-FAILED PID:$procId $errMsg"
                            }
                            $tracking.Remove($procId)
                            Remove-RingPid $procId
                        }
                        else {
                            Write-Log "WOULD-KILL PID:$procId MEM:${memMB}MB DUR:${duration}s CPU:$cpuPct REASON:$reason AGE:$age (MONITOR MODE)"
                            Write-KillDetails $procId
                            # Don't remove — set state to would-kill
                            $tracking[$procId].State = "would-kill"
                            $tracking[$procId].Reason = $reason
                        }
                    }
                }
            }
            else {
                # Below all thresholds
                if ($tracking.ContainsKey($procId)) {
                    $entry = $tracking[$procId]
                    if ($entry.State -eq "would-kill") {
                        $wouldKillDur = [math]::Round(($now - $entry.FirstSeen).TotalSeconds, 1)
                        $durStr = if ($wouldKillDur -ge 60) { "$([math]::Floor($wouldKillDur / 60))m$([math]::Floor($wouldKillDur % 60))s" } else { "${wouldKillDur}s" }
                        Write-Log "RECOVERED PID:$procId MEM:${memMB}MB CPU:$cpuPct (was: WOULD-KILL for $durStr)"
                    }
                    else {
                        if ($logLevel -eq "detail") {
                            Write-Log "DROPPED-BELOW PID:$procId MEM:${memMB}MB CPU:$cpuPct"
                        }
                    }
                    $tracking.Remove($procId)
                    Remove-RingPid $procId
                }
            }
        }

        # 5. Clean up tracked PIDs that no longer exist
        $gonePids = @($tracking.Keys | Where-Object { -not $activePids.ContainsKey($_) })
        foreach ($procId in $gonePids) {
            $entry = $tracking[$procId]
            if ($entry.State -eq "would-kill") {
                $wouldKillDur = [math]::Round(($now - $entry.FirstSeen).TotalSeconds, 1)
                $durStr = if ($wouldKillDur -ge 60) { "$([math]::Floor($wouldKillDur / 60))m$([math]::Floor($wouldKillDur % 60))s" } else { "${wouldKillDur}s" }
                Write-Log "PROCESS-GONE PID:$procId (was: WOULD-KILL for $durStr)"
            }
            elseif ($logLevel -eq "detail") {
                Write-Log "PROCESS-GONE PID:$procId (was: TRACKING)"
            }
            $tracking.Remove($procId)
            Remove-RingPid $procId
        }

        # 5b. Clean stale ring buffer entries for PIDs no longer in the process list
        if ($detailsOnKill) {
            $staleRingPids = @($ringBuffer.Keys | Where-Object { -not $activePids.ContainsKey($_) })
            foreach ($procId in $staleRingPids) { $ringBuffer.Remove($procId) }
        }

        # 6. Heartbeat and log rotation
        if (($now - $lastHeartbeat).TotalMinutes -ge [math]::Max($heartbeatMinutes, 5)) {
            if ($heartbeatMinutes -gt 0) {
                $count = $procs.Count
                $topMem = "TOP_MEM:none"
                if ($count -gt 0) {
                    $top = $procs | Sort-Object WorkingSet64 -Descending | Select-Object -First 1
                    $topMem = "TOP_MEM:PID:$($top.Id)/$([math]::Round($top.WorkingSet64 / 1MB, 1))MB"
                }
                $topCpu = "TOP_CPU:none"
                $topCpuPid = $cpuByPid.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
                if ($topCpuPid) {
                    $topCpu = "TOP_CPU:PID:$($topCpuPid.Key)/$($topCpuPid.Value)%"
                }

                # WD aggregate CPU
                $wdCpuTotal = 0
                foreach ($v in $cpuByPid.Values) { $wdCpuTotal += $v }
                $wdCpuTotal = [math]::Round($wdCpuTotal, 1)

                # WD aggregate memory
                $wdMemTotal = 0
                foreach ($p in $procs) {
                    if ($null -ne $p) { $wdMemTotal += $p.WorkingSet64 }
                }
                $wdMemGB = [math]::Round($wdMemTotal / 1GB, 1)

                # System health indicators
                $sysCpu = "SYS_CPU:n/a-WD:$wdCpuTotal%"
                $sysMem = "SYS_MEM:n/a-WD:${wdMemGB}GB"
                try {
                    $cpuLoad = [math]::Round((Get-CimInstance Win32_Processor -ErrorAction Stop | Measure-Object -Property LoadPercentage -Average).Average, 1)
                    $sysCpu = "SYS_CPU:$cpuLoad%-WD:$wdCpuTotal%"
                } catch { }
                try {
                    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
                    $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
                    $usedGB  = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 1)
                    $memPct  = [math]::Round(($usedGB / $totalGB) * 100, 1)
                    $wdMemPct = [math]::Round(($wdMemGB / $totalGB) * 100, 1)
                    $sysMem = "SYS_MEM:$usedGB/${totalGB}GB($memPct%)-WD:${wdMemGB}GB($wdMemPct%)"
                } catch { }

                # CPU distribution buckets
                $cpuIdle = 0; $cpuNormal = 0; $cpuHot = 0
                foreach ($p in $procs) {
                    if ($null -eq $p) { continue }
                    $c = if ($cpuByPid.ContainsKey($p.Id)) { $cpuByPid[$p.Id] } else { 0 }
                    if ($c -lt 1)                    { $cpuIdle++ }
                    elseif ($c -lt $cpuThresholdPct) { $cpuNormal++ }
                    else                             { $cpuHot++ }
                }

                Write-Log "HEARTBEAT PROCS:$count $topMem $topCpu $sysCpu $sysMem TRACKING:$($tracking.Count) SPIKES:$spikeCount KILLS:$killCount"
                Write-Log "  DIST CPU_IDLE(<1%):$cpuIdle CPU_NORMAL(1-$cpuThresholdPct%):$cpuNormal CPU_HOT(>=$cpuThresholdPct%):$cpuHot"

                # Non-WD CPU spike detection
                if ($nonWdCpuGapPct -gt 0 -and $null -ne $cpuLoad) {
                    $cpuGap = [math]::Round($cpuLoad - $wdCpuTotal, 1)
                    if ($cpuGap -ge $nonWdCpuGapPct) {
                        Write-Log "  NON_WD_SPIKE SYS_CPU:$cpuLoad% WD_CPU:$wdCpuTotal% GAP:${cpuGap}%"
                        if ($nonWdCpuTopN -gt 0) {
                            try {
                                # Build set of WD PIDs to exclude
                                $wdPids = @{}
                                foreach ($p in $procs) { if ($null -ne $p) { $wdPids[$p.Id] = $true } }

                                # Query all process CPU via WMI
                                $nwCimOpts = New-CimSessionOption -Protocol Dcom
                                $nwCimSess = New-CimSession -SessionOption $nwCimOpts -OperationTimeoutSec $wmiTimeoutSec -ErrorAction Stop
                                try {
                                    $topNonWd = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process `
                                        -CimSession $nwCimSess `
                                        -OperationTimeoutSec $wmiTimeoutSec `
                                        -ErrorAction SilentlyContinue |
                                    Where-Object {
                                        $_.IDProcess -ne 0 -and
                                        $_.Name -ne '_Total' -and
                                        $_.Name -ne 'Idle' -and
                                        -not $wdPids.ContainsKey([int]$_.IDProcess)
                                    } |
                                    Sort-Object PercentProcessorTime -Descending |
                                    Select-Object -First $nonWdCpuTopN

                                    # Batch-fetch command lines for the top N PIDs
                                    $cmdLines = @{}
                                    if ($topNonWd) {
                                        $pidList = ($topNonWd | ForEach-Object { $_.IDProcess }) -join ' OR ProcessId = '
                                        $wmiFilter = "ProcessId = $pidList"
                                        try {
                                            Get-CimInstance Win32_Process -Filter $wmiFilter -ErrorAction SilentlyContinue |
                                            ForEach-Object { $cmdLines[[int]$_.ProcessId] = $_.CommandLine }
                                        } catch { }
                                    }

                                    foreach ($nwProc in $topNonWd) {
                                        $pCpu = [math]::Round($nwProc.PercentProcessorTime / $numCores, 1)
                                        $pMem = [math]::Round($nwProc.WorkingSetPrivate / 1MB, 1)
                                        $pName = $nwProc.Name
                                        $pPid = $nwProc.IDProcess
                                        $cmdLine = if ($cmdLines.ContainsKey([int]$pPid)) { $cmdLines[[int]$pPid] } else { "" }
                                        if ($null -eq $cmdLine) { $cmdLine = "" }
                                        if ($cmdLine.Length -gt 120) { $cmdLine = $cmdLine.Substring(0, 120) + "..." }
                                        Write-Log "  NON_WD PID:$pPid NAME:$pName CPU:$pCpu% MEM:${pMem}MB CMD:$cmdLine"
                                    }
                                }
                                finally {
                                    Remove-CimSession $nwCimSess -ErrorAction SilentlyContinue
                                }
                            }
                            catch {
                                Write-Log "  NON_WD_QUERY_ERROR $($_.Exception.Message)"
                            }
                        }
                    }
                }
            }
            Rotate-Log
            $lastHeartbeat = $now
            # Reset heartbeat counters
            $spikeCount = 0
            $killCount = 0
        }

        # 7. Wait for the next full cycle. With a fast memory pass enabled, wake every
        #    memCheckIntervalMs meanwhile and apply ONLY the immediate memory threshold:
        #    Get-Process is cheap, no WMI. CPU, sustained memory, tracking and heartbeats
        #    stay on the full cycle above, unchanged. A memory bomb goes from normal to
        #    multi-GB between two full cycles, so this catches it seconds sooner.
        $nextFullCycle = (Get-Date).AddMilliseconds($checkIntervalMs)
        if (-not $fastMemPass) {
            Start-Sleep -Milliseconds $checkIntervalMs
            continue
        }
        while ($true) {
            $remainingMs = ($nextFullCycle - (Get-Date)).TotalMilliseconds
            if ($remainingMs -le 0) { break }
            Start-Sleep -Milliseconds ([int][math]::Min($memCheckIntervalMs, $remainingMs))
            if ((Get-Date) -ge $nextFullCycle) { break }

            $fastProcs = @()
            try {
                $fastProcs = @(Get-Process -Name $processPattern -ErrorAction SilentlyContinue)
            }
            catch { }

            foreach ($proc in $fastProcs) {
                if ($null -eq $proc) { continue }
                $memMB = [math]::Round($proc.WorkingSet64 / 1MB, 1)
                if ($memMB -lt $memKillImmediate) { continue }

                $procId = $proc.Id
                # Monitor mode: already flagged, the full cycle is tracking it
                if ($mode -ne "kill" -and $tracking.ContainsKey($procId) -and $tracking[$procId].State -eq "would-kill") { continue }
                # CPU is the last full-cycle reading; the fast pass never queries WMI
                $cpuPct = if ($cpuByPid.ContainsKey($procId)) { $cpuByPid[$procId] } else { 0 }
                $cpuViolation = ($cpuThresholdPct -gt 0) -and ($cpuPct -ge $cpuThresholdPct)
                $reason = if ($cpuViolation) { "MEMORY+CPU" } else { "MEMORY" }

                if ($memMB -gt $dailyPeakMem) {
                    $dailyPeakMem = $memMB
                    $dailyPeakPid = $procId
                }
                # So the forensic dump ends with the sample that triggered the kill
                Add-RingSample $procId $cpuPct $memMB

                # Same handling as the immediate branch of the full cycle
                $age = Get-ProcessAge $procId
                $dailyUniquePids[$procId] = $true

                if ($mode -eq "kill") {
                    Write-Log "KILLING PID:$procId MEM:${memMB}MB CPU:$cpuPct REASON:$reason AGE:$age (IMMEDIATE)"
                    Write-KillDetails $procId
                    try {
                        Stop-Process -Id $procId -Force -ErrorAction Stop
                        Write-Log "KILLED PID:$procId"
                        $killCount++
                        $dailyKills++
                    }
                    catch {
                        $errMsg = $_.Exception.Message
                        if ($errMsg.Length -gt 80) { $errMsg = $errMsg.Substring(0, 80) }
                        Write-Log "KILL-FAILED PID:$procId $errMsg"
                    }
                    $tracking.Remove($procId)
                    Remove-RingPid $procId
                }
                else {
                    # Monitor mode: log WOULD-KILL once, then the full cycle tracks RECOVERED/PROCESS-GONE
                    if (-not $tracking.ContainsKey($procId)) {
                        $tracking[$procId] = @{ FirstSeen = (Get-Date); Reason = $reason; State = "would-kill" }
                        $spikeCount++
                        $dailySpikes++
                        Write-Log "WOULD-KILL PID:$procId MEM:${memMB}MB CPU:$cpuPct REASON:$reason AGE:$age (IMMEDIATE, MONITOR MODE)"
                        Write-KillDetails $procId
                    }
                    elseif ($tracking[$procId].State -ne "would-kill") {
                        $tracking[$procId].State = "would-kill"
                        $tracking[$procId].Reason = $reason
                        Write-Log "WOULD-KILL PID:$procId MEM:${memMB}MB CPU:$cpuPct REASON:$reason AGE:$age (IMMEDIATE, MONITOR MODE)"
                        Write-KillDetails $procId
                    }
                }
            }
        }
    }
}
catch {
    $errTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logFile -Value "$errTime FATAL-ERROR $($_.Exception.Message)" -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5
}
