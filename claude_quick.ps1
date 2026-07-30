<#
.SYNOPSIS
    Claude Desktop Multi-Instance Launcher & Auto Account Switcher for Windows
    Translated and expanded from stracker-phil/claude_quick.sh

.DESCRIPTION
    Uses Electron's --user-data-dir flag to run fully isolated Claude Desktop instances on Windows.
    Each instance gets its own data directory (config, sessions, plugins, usage logs, etc.).
    Includes automatic usage recalculation to auto-select and launch the instance with the most capacity remaining.

    Requires claude_common.ps1 and claude_diagnose.ps1 alongside this file.

.USAGE
    .\claude_quick.ps1                    # Show interactive menu
    .\claude_quick.ps1 auto               # Recalculate usage & auto-launch instance with most remaining capacity
    .\claude_quick.ps1 <instance>         # Launch named instance
    .\claude_quick.ps1 list               # List all instances
    .\claude_quick.ps1 usage              # View usage limits & reset timers for all accounts
    .\claude_quick.ps1 delete <name>      # Delete an instance
    .\claude_quick.ps1 shortcut <name>    # Create Desktop shortcut for instance
    .\claude_quick.ps1 diagnose           # Run read-only diagnostics
#>

param (
    [Parameter(Position=0)]
    [string]$Command,

    [Parameter(Position=1)]
    [string]$Name
)

$ErrorActionPreference = "Stop"

foreach ($dependency in @("claude_common.ps1", "claude_diagnose.ps1")) {
    $dependencyPath = Join-Path $PSScriptRoot $dependency
    if (-not (Test-Path $dependencyPath)) {
        Write-Host "[X] Required file '$dependency' is missing from $PSScriptRoot" -ForegroundColor Red
        Write-Host "    Download the full project, not just claude_quick.ps1." -ForegroundColor Yellow
        exit 1
    }
    . $dependencyPath
}

# Numbered picker over instances that actually exist on disk. Returns $null if cancelled.
function Select-ExistingInstance ($promptLabel) {
    if (-not $promptLabel) { $promptLabel = "Select instance" }

    $options = @("default") + (Get-InstanceList)

    Write-Host "`nClaude Desktop Instances" -ForegroundColor Cyan
    Write-Host "========================" -ForegroundColor Cyan
    Write-Host ""
    for ($i = 0; $i -lt $options.Count; $i++) {
        $label = if (Test-IsDefaultInstance $options[$i]) { "default (built-in default data directory)" } else { $options[$i] }
        Write-Host ("  {0}. {1}" -f ($i + 1), $label)
    }
    Write-Host ""
    Write-Host "  0. Cancel" -ForegroundColor Gray
    Write-Host ""

    $raw = (Read-Host "$promptLabel (0-$($options.Count))").Trim()
    if ($raw -eq "0" -or $raw -eq "") { return $null }

    $index = 0
    if (-not [int]::TryParse($raw, [ref]$index) -or $index -lt 1 -or $index -gt $options.Count) {
        Write-Host "[X] '$raw' is not one of the listed numbers." -ForegroundColor Red
        return $null
    }

    return $options[$index - 1]
}

function Create-DesktopShortcut ($instanceName, $displayName) {
    if (-not (Test-ValidInstanceName $instanceName)) {
        Write-Host "[X] Invalid instance name. Do not use path separators or special characters." -ForegroundColor Red
        return
    }

    $claudeExe = Ensure-ClaudeExe

    if (-not $displayName) {
        $displayName = $instanceName.Substring(0,1).ToUpper() + $instanceName.Substring(1)
    }

    $shortcutPath = Join-Path $DESKTOP_PATH "Claude - $displayName.lnk"

    if (Test-Path $shortcutPath) {
        $overwrite = Read-Host "Shortcut '$shortcutPath' already exists. Overwrite? (y/N)"
        if ($overwrite -notmatch '^[Yy]$') {
            return
        }
    }

    $instanceDir = Join-Path $INSTANCES_BASE $instanceName
    if (-not (Test-IsDefaultInstance $instanceName)) {
        New-Item -ItemType Directory -Force -Path $instanceDir | Out-Null
    }

    $wshShell = New-Object -ComObject WScript.Shell
    $shortcut = $wshShell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $claudeExe

    if (-not (Test-IsDefaultInstance $instanceName)) {
        $shortcut.Arguments = "--user-data-dir=`"$instanceDir`""
    }

    $shortcut.IconLocation = "$claudeExe,0"
    $shortcut.WorkingDirectory = [System.IO.Path]::GetDirectoryName($claudeExe)
    $shortcut.Save()

    Write-Host "[+] Shortcut created on Desktop: $shortcutPath" -ForegroundColor Green
}

function Confirm-CloseRunningClaude ($contextMsg) {
    if (Test-ClaudeIsRunning) {
        Write-Host "`n[!] Notice: Claude Desktop is currently running." -ForegroundColor Yellow
        if ($contextMsg) {
            Write-Host "    $contextMsg" -ForegroundColor Yellow
        }
        Write-Host "    Closing it avoids two instances competing for the same window focus." -ForegroundColor Yellow
        Write-Host "    Note: this does NOT redirect browser sign-in links. Claude re-registers itself" -ForegroundColor Yellow
        Write-Host "    as the claude:// handler on every launch, so those links land in the default" -ForegroundColor Yellow
        Write-Host "    profile regardless. Copy the sign-in code and paste it into the target window." -ForegroundColor Yellow
        $stopConfirm = Read-Host "Close running Claude Desktop processes now? (Y/n)"
        if ($stopConfirm -notmatch '^[Nn]$') {
            Stop-ClaudeProcesses
        }
    }
}

function Delete-Instance ($instanceName) {
    if (-not $instanceName) {
        $instanceName = Select-ExistingInstance "Instance to delete"
        if (-not $instanceName) { return }
    }

    $instanceName = Get-CleanInstanceName $instanceName

    if (-not (Test-ValidInstanceName $instanceName)) {
        Write-Host "[X] Invalid instance name." -ForegroundColor Red
        return
    }

    if (Test-IsDefaultInstance $instanceName) {
        Write-Host "[X] Cannot delete the default instance." -ForegroundColor Red
        return
    }

    $instanceDir = Join-Path $INSTANCES_BASE $instanceName
    if (-not (Test-Path $instanceDir)) {
        Write-Host "[X] Instance '$instanceName' does not exist." -ForegroundColor Red
        return
    }

    $shortcutPath = Join-Path $DESKTOP_PATH "Claude - $instanceName.lnk"

    Write-Host "[!] This will delete:" -ForegroundColor Yellow
    Write-Host "  - Data directory: $instanceDir" -ForegroundColor Yellow
    if (Test-Path $shortcutPath) {
        Write-Host "  - Desktop shortcut: $shortcutPath" -ForegroundColor Yellow
    }
    Write-Host ""
    $confirm = Read-Host "Type 'yes' to confirm deletion"

    if ($confirm -ne "yes") {
        Write-Host "Cancelled."
        return
    }

    Remove-Item -Recurse -Force $instanceDir
    if (Test-Path $shortcutPath) {
        Remove-Item -Force $shortcutPath
    }
    Write-Host "[+] Instance '$instanceName' deleted successfully." -ForegroundColor Green
}

function Launch-AutoInstance {
    Write-Host "`n[*] Recalculating usage statistics across all accounts..." -ForegroundColor Gray
    $ranked = Get-BestUsageInstance

    Write-Host "`nUsage Rankings:" -ForegroundColor Yellow
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
    Write-Host "    Reason: Highest 5-hour capacity remaining (5h score: $($best.FhScore)). If tied/full, highest weekly capacity remaining (7d score: $($best.SdScore))." -ForegroundColor Gray
    Launch-Instance $best.InstanceName
}

function Show-Usage {
    Write-Host "`nClaude Desktop Account Usage Limits & Status" -ForegroundColor Cyan
    Write-Host "=============================================" -ForegroundColor Cyan

    $instances = @("default") + (Get-InstanceList)

    foreach ($inst in $instances) {
        $stats = Get-InstanceUsageStats $inst
        Write-Host "`nInstance: $inst" -ForegroundColor Yellow
        Write-Host "Data Path: $($stats.DataDir)" -ForegroundColor Gray
        if ($stats.AccountUuid -ne "Unknown") {
            Write-Host "  Account UUID: $($stats.AccountUuid)" -ForegroundColor Gray
        }

        if ($stats.LastActiveTime -ne "Never") {
            Write-Host "  Last Active:                $($stats.LastActiveTime)"
            Write-Host "  5-Hour Activity Score (fh): $($stats.FhScore)"
            Write-Host "  7-Day Activity Score (sd):  $($stats.SdScore)"
            Write-Host "  5-Hour Window Status:       $($stats.StatusText)" -ForegroundColor Green
        } else {
            Write-Host "  5-Hour Window Status:       No usage history recorded yet (Full Capacity Ready)" -ForegroundColor Green
        }
    }
    Write-Host ""
}

# Main Script Logic
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "  Claude Desktop Multi-Instance Launcher" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan

$cmdLower = if ($Command) { $Command.ToLower() } else { "" }

switch ($cmdLower) {
    "auto" {
        Launch-AutoInstance
        exit 0
    }
    "best" {
        Launch-AutoInstance
        exit 0
    }
    "list" {
        List-Instances
        exit 0
    }
    "usage" {
        Show-Usage
        Write-Host ""
        Read-Host "Press Enter to exit..."
        exit 0
    }
    "delete" {
        Delete-Instance $Name
        exit 0
    }
    "shortcut" {
        if (-not $Name) {
            $Name = Select-ExistingInstance "Instance for shortcut"
        } else {
            $Name = Get-CleanInstanceName $Name
        }
        if ($Name) {
            Create-DesktopShortcut $Name
        }
        exit 0
    }
    "diagnose" {
        Show-Diagnostics
        Write-Host ""
        Read-Host "Press Enter to exit..."
        exit 0
    }
    Default {
        if ($Command) {
            Launch-Instance $Command
            exit 0
        }
    }
}

# Interactive Menu Loop
do {
    Write-Host ""
    Write-Host "1. Auto-select & launch instance with most usage remaining" -ForegroundColor Green
    Write-Host "2. Launch default instance"
    Write-Host "3. Select existing instance"
    Write-Host "4. Create new instance"
    Write-Host "5. View account usage limits & reset timers"
    Write-Host "6. Delete instance"
    Write-Host "7. Create Desktop shortcut"
    Write-Host "8. Diagnostics"
    Write-Host "9. Exit"
    Write-Host ""
    Write-Host "Tip: Browser sign-in links (claude://) always open the DEFAULT profile, because" -ForegroundColor Yellow
    Write-Host "     Claude re-registers itself as the claude:// handler on every launch. When" -ForegroundColor Yellow
    Write-Host "     signing into a new instance, copy the code and paste it into that window." -ForegroundColor Yellow
    Write-Host ""
    $choice = Read-Host "Select (1-9)"

    switch ($choice) {
        "1" {
            Launch-AutoInstance
            $loop = $false
        }
        "2" {
            Launch-Instance "default"
            $loop = $false
        }
        "3" {
            # Pick by number rather than retyping the name. Retyping is how a stray space or a
            # typo turns into a launch against a brand-new empty profile.
            $n = Select-ExistingInstance
            if ($n) {
                Confirm-CloseRunningClaude "Switching instance."
                Launch-Instance $n
                $loop = $false
            }
        }
        "4" {
            $n = Get-CleanInstanceName (Read-Host "New instance name")
            if (-not $n) {
                Write-Host "[X] No name provided." -ForegroundColor Red
            } elseif (Test-IsDefaultInstance $n) {
                Write-Host "[X] 'default' is reserved for the built-in instance." -ForegroundColor Red
            } elseif (-not (Test-ValidInstanceName $n)) {
                Write-Host "[X] Invalid instance name: '$n'" -ForegroundColor Red
                Write-Host "    Avoid path separators, special characters, reserved device names, and names over 64 chars." -ForegroundColor Gray
            } elseif (Test-InstanceExists $n) {
                Write-Host "[!] Instance '$(Resolve-InstanceName $n)' already exists." -ForegroundColor Yellow
                Write-Host "    Use option 3 to launch it. Nothing was changed." -ForegroundColor Gray
            } else {
                $createSc = Read-Host "Create a Desktop shortcut for '$n'? (Y/n)"
                if ($createSc -notmatch '^[Nn]$') {
                    Create-DesktopShortcut $n
                }
                Confirm-CloseRunningClaude "Creating and logging into a new instance."
                Write-Host "`n[*] Starting new instance '$n'. Complete sign-in in the launched window." -ForegroundColor Cyan
                Launch-Instance $n -AllowCreate
                $loop = $false
            }
        }
        "5" {
            Show-Usage
            Write-Host ""
            Read-Host "Press Enter to continue..."
            $loop = $true
        }
        "6" {
            Delete-Instance
            Write-Host ""
            Read-Host "Press Enter to continue..."
            $loop = $true
        }
        "7" {
            $n = Select-ExistingInstance "Instance for shortcut"
            if ($n) { Create-DesktopShortcut $n }
            Write-Host ""
            Read-Host "Press Enter to continue..."
            $loop = $true
        }
        "8" {
            Show-Diagnostics
            Write-Host ""
            Read-Host "Press Enter to continue..."
            $loop = $true
        }
        "9" {
            $loop = $false
        }
        Default {
            Write-Host "Invalid selection." -ForegroundColor Red
            $loop = $true
        }
    }
} while ($loop)
