<#
.SYNOPSIS
    Claude Desktop Auto-Account Selector (Most Usage Remaining)
    Part of claude-account-switcher

.DESCRIPTION
    Scans all Claude Desktop instances (default + custom instances in ~/.claude-instances),
    evaluates their 5-hour and 7-day plan usage windows, recalculates current usage scores,
    and automatically selects and launches the instance with the most remaining capacity.

    Priority Logic:
    1. Highest 5-hour capacity remaining (lowest 5h activity score 'fh')
    2. Highest weekly capacity remaining (lowest 7d activity score 'sd') if 5h scores are tied / full
    3. Longest idle duration if both 5h and 7d scores are tied

    Requires claude_common.ps1 alongside this file.

.USAGE
    .\claude_auto_select.ps1              # Recalculates usage, selects, and launches best account
    .\claude_auto_select.ps1 -SelectOnly  # Returns best instance object/name without launching
#>

[CmdletBinding()]
param (
    [switch]$SelectOnly
)

$ErrorActionPreference = "Stop"

$commonPath = Join-Path $PSScriptRoot "claude_common.ps1"
if (-not (Test-Path $commonPath)) {
    Write-Host "[X] Required file 'claude_common.ps1' is missing from $PSScriptRoot" -ForegroundColor Red
    Write-Host "    Download the full project, not just claude_auto_select.ps1." -ForegroundColor Yellow
    exit 1
}
. $commonPath

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
Write-Host "    Reason: Highest 5-hour capacity remaining (5h score: $($best.FhScore)). If tied/full, highest weekly capacity remaining (7d score: $($best.SdScore))." -ForegroundColor Gray

if ($SelectOnly) {
    return $best
}

Launch-Instance $best.InstanceName
