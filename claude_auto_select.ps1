<#
.SYNOPSIS
    Claude Desktop Auto-Account Selector (Most Usage Remaining)
    Part of claude-account-switcher

.DESCRIPTION
    Scans all Claude Desktop instances (default + custom instances in ~/.claude-instances),
    evaluates their 5-hour and 7-day plan usage windows, recalculates current usage scores,
    and automatically selects and launches the instance with the most remaining capacity.

.USAGE
    .\claude_auto_select.ps1              # Recalculates usage, selects, and launches best account
    .\claude_auto_select.ps1 -SelectOnly  # Returns best instance object/name without launching
#>

[CmdletBinding()]
param (
    [switch]$SelectOnly
)

$ErrorActionPreference = "Stop"

$INSTANCES_BASE = Join-Path $HOME ".claude-instances"

function Test-IsDefaultInstance ($name) {
    return ($name -eq "default")
}

function Get-InstanceList {
    if (-not (Test-Path $INSTANCES_BASE)) {
        return @()
    }
    Get-ChildItem -Path $INSTANCES_BASE -Directory | Select-Object -ExpandProperty Name
}

function Get-ClaudeExePath {
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\Claude\Claude.exe",
        "$env:LOCALAPPDATA\Claude\Claude.exe",
        "$env:LOCALAPPDATA\AnthropicClaude\Claude.exe",
        "$env:LOCALAPPDATA\Programs\claude-desktop\Claude.exe",
        "$env:ProgramFiles\Claude\Claude.exe",
        "${env:ProgramFiles(x86)}\Claude\Claude.exe"
    )

    foreach ($path in $candidates) {
        if (Test-Path $path) {
            return $path
        }
    }

    $winAppsClaude = Get-ChildItem -Path "$env:ProgramFiles\WindowsApps" -Filter "claude.exe" -Recurse -Depth 3 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName -First 1
    if ($winAppsClaude -and (Test-Path $winAppsClaude)) {
        return $winAppsClaude
    }

    $configPath = Join-Path $INSTANCES_BASE "claude_exe_path.txt"
    if (Test-Path $configPath) {
        $rawContent = Get-Content $configPath -Raw
        if ($rawContent) {
            $savedPath = $rawContent.Trim().Trim('"', "'").Trim()
            if ($savedPath -and (Test-Path $savedPath)) {
                return $savedPath
            }
        }
    }

    return $null
}

function Get-InstanceUsageStats ($inst) {
    $isDefault = Test-IsDefaultInstance $inst
    $dir = if ($isDefault) { Join-Path $env:APPDATA "Claude" } else { Join-Path $INSTANCES_BASE $inst }
    $usageFile = Join-Path $dir "plan-usage-history.json"
    $configFile = Join-Path $dir "config.json"

    $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $fiveHoursMs = 5 * 60 * 60 * 1000

    $stats = [PSCustomObject]@{
        InstanceName      = $inst
        DataDir           = $dir
        AccountUuid       = "Unknown"
        FhScore           = 0
        SdScore           = 0
        LastActiveMs      = 0
        LastActiveTime    = "Never"
        WindowActive      = $false
        ResetTime         = $null
        StatusText        = "Full Capacity / Idle"
    }

    if (Test-Path $configFile) {
        try {
            $cfg = Get-Content $configFile -Raw | ConvertFrom-Json
            if ($cfg.lastKnownAccountUuid) {
                $stats.AccountUuid = $cfg.lastKnownAccountUuid
            }
        } catch {}
    }

    if (Test-Path $usageFile) {
        try {
            $data = Get-Content $usageFile -Raw | ConvertFrom-Json
            if ($data.samples -and $data.samples.Count -gt 0) {
                $latest = $data.samples | Select-Object -Last 1
                $stats.LastActiveMs = $latest.t
                $stats.LastActiveTime = [DateTimeOffset]::FromUnixTimeMilliseconds($latest.t).LocalDateTime.ToString("g")
                $stats.SdScore = if ($latest.u.sd) { [int]$latest.u.sd } else { 0 }

                $recentSamples = $data.samples | Where-Object { ($nowMs - $_.t) -le $fiveHoursMs }
                $activeSamples = $recentSamples | Where-Object { $_.u.fh -gt 0 }

                if ($activeSamples) {
                    $firstActive = $activeSamples[0]
                    $firstActiveTime = [DateTimeOffset]::FromUnixTimeMilliseconds($firstActive.t).LocalDateTime
                    $resetTime = $firstActiveTime.AddHours(5)
                    $timeRemaining = $resetTime - [DateTime]::Now

                    if ($timeRemaining.TotalSeconds -gt 0) {
                        $stats.WindowActive = $true
                        $stats.FhScore = if ($latest.u.fh) { [int]$latest.u.fh } else { 0 }
                        $stats.ResetTime = $resetTime
                        $hours = [math]::Floor($timeRemaining.TotalHours)
                        $mins = $timeRemaining.Minutes
                        $stats.StatusText = "Active ($($stats.FhScore) 5h-score, reset in $hours`h $mins`m)"
                    } else {
                        $stats.FhScore = 0
                        $stats.StatusText = "Window Reset / Full Capacity"
                    }
                }
            }
        } catch {}
    }

    return $stats
}

function Get-BestUsageInstance {
    $instances = @("default") + (Get-InstanceList)
    $allStats = foreach ($inst in $instances) {
        Get-InstanceUsageStats $inst
    }

    # Rank by:
    # 1. FhScore ascending (lowest 5-hour activity score)
    # 2. SdScore ascending (lowest 7-day activity score)
    # 3. LastActiveMs ascending (longest idle time)
    $sorted = $allStats | Sort-Object FhScore, SdScore, LastActiveMs
    return $sorted
}

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Claude Auto-Account Selector (Usage Based) " -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "[*] Recalculating current usage for all instances..." -ForegroundColor Gray

$ranked = Get-BestUsageInstance

Write-Host "`nInstance Usage Rankings:" -ForegroundColor Yellow
Write-Host ("{0,-15} {1,-10} {2,-10} {3,-20} {4}" -f "Instance", "5h Score", "7d Score", "Last Active", "Status") -ForegroundColor Gray
Write-Host ("{0,-15} {1,-10} {2,-10} {3,-20} {4}" -f "--------", "--------", "--------", "-----------", "------") -ForegroundColor Gray

foreach ($stat in $ranked) {
    $isTop = ($stat.InstanceName -eq $ranked[0].InstanceName)
    $color = if ($isTop) { "Green" } else { "White" }
    $prefix = if ($isTop) { "-> " } else { "   " }
    $nameDisplay = $prefix + $stat.InstanceName
    Write-Host ("{0,-15} {1,-10} {2,-10} {3,-20} {4}" -f $nameDisplay, $stat.FhScore, $stat.SdScore, $stat.LastActiveTime, $stat.StatusText) -ForegroundColor $color
}

$best = $ranked[0]

Write-Host "`n[+] Selected Instance with Most Usage Remaining: '$($best.InstanceName)'" -ForegroundColor Green
if ($best.AccountUuid -ne "Unknown") {
    Write-Host "    Account UUID: $($best.AccountUuid)" -ForegroundColor Gray
}
Write-Host "    Reason: Lowest active 5-hour usage score ($($best.FhScore)) & lowest 7-day score ($($best.SdScore))" -ForegroundColor Gray

if ($SelectOnly) {
    return $best
}

# Launch the selected instance
$claudeExe = Get-ClaudeExePath
if (-not $claudeExe) {
    Write-Host "[!] Claude Desktop executable not found." -ForegroundColor Red
    exit 1
}

Write-Host "`n[*] Launching Claude Desktop instance: $($best.InstanceName)..." -ForegroundColor Cyan
if (Test-IsDefaultInstance $best.InstanceName) {
    Start-Process -FilePath $claudeExe
    Write-Host "[+] Claude Desktop launched (default instance)" -ForegroundColor Green
} else {
    $instanceDir = Join-Path $INSTANCES_BASE $best.InstanceName
    Start-Process -FilePath $claudeExe -ArgumentList "--user-data-dir=`"$instanceDir`""
    Write-Host "[+] Claude Desktop launched (instance: $($best.InstanceName))" -ForegroundColor Green
    Write-Host "    Data Dir: $instanceDir" -ForegroundColor Gray
}
