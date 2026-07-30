<#
.SYNOPSIS
    Claude Desktop Multi-Instance Launcher & Auto Account Switcher for Windows
    Translated and expanded from stracker-phil/claude_quick.sh

.DESCRIPTION
    Uses Electron's --user-data-dir flag to run fully isolated Claude Desktop instances on Windows.
    Each instance gets its own data directory (config, sessions, plugins, usage logs, etc.).
    Includes automatic usage recalculation to auto-select and launch the instance with the most capacity remaining.

.USAGE
    .\claude_quick.ps1                    # Show interactive menu
    .\claude_quick.ps1 auto               # Recalculate usage & auto-launch instance with most remaining capacity
    .\claude_quick.ps1 <instance>         # Launch named instance
    .\claude_quick.ps1 list               # List all instances
    .\claude_quick.ps1 usage              # View usage limits & reset timers for all accounts
    .\claude_quick.ps1 delete <name>      # Delete an instance
    .\claude_quick.ps1 shortcut <name>    # Create Desktop shortcut for instance
    .\claude_quick.ps1 diagnose           # Run diagnostics
#>

param (
    [Parameter(Position=0)]
    [string]$Command,

    [Parameter(Position=1)]
    [string]$Name
)

$ErrorActionPreference = "Stop"

$INSTANCES_BASE = Join-Path $HOME ".claude-instances"
$DESKTOP_PATH = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::Desktop)

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

    # Windows Store / MSIX installation.
    # Note: recursively searching $env:ProgramFiles\WindowsApps returns nothing for a
    # non-elevated user, because the directory ACL denies enumeration. Direct path access
    # to the same files works fine, so resolve the install location instead of searching.
    try {
        foreach ($pkg in (Get-AppxPackage -Name "*Claude*" -ErrorAction SilentlyContinue)) {
            if (-not $pkg.InstallLocation) { continue }
            foreach ($rel in @("app\Claude.exe", "Claude.exe")) {
                $msixExe = Join-Path $pkg.InstallLocation $rel
                if (Test-Path $msixExe) {
                    return $msixExe
                }
            }
        }
    } catch {}

    # Claude registers itself as the claude:// protocol handler on every launch, so this
    # key holds the exe path of whichever build is installed (including MSIX).
    try {
        $handler = (Get-ItemProperty -Path "Registry::HKEY_CLASSES_ROOT\claude\shell\open\command" -ErrorAction SilentlyContinue).'(default)'
        if ($handler -and $handler -match '^"([^"]+\.exe)"') {
            $handlerExe = $Matches[1]
            if (Test-Path $handlerExe) {
                return $handlerExe
            }
        }
    } catch {}

    # Last resort: enumerate WindowsApps. Only succeeds when running elevated.
    $winAppsClaude = Get-ChildItem -Path "$env:ProgramFiles\WindowsApps" -Filter "claude.exe" -Recurse -Depth 3 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName -First 1
    if ($winAppsClaude -and (Test-Path $winAppsClaude)) {
        return $winAppsClaude
    }

    # Saved custom path check
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

function Ensure-ClaudeExe {
    $exe = Get-ClaudeExePath
    if (-not $exe) {
        Write-Host "[!] Claude Desktop executable (Claude.exe) was not automatically found." -ForegroundColor Yellow
        Write-Host "If you have Claude Desktop installed in a custom path, please enter the full path to Claude.exe below."
        Write-Host "Otherwise, download and install Claude Desktop from https://claude.ai/download" -ForegroundColor Cyan
        Write-Host ""
        $rawInput = Read-Host "Enter full path to Claude.exe (or press Enter to cancel)"
        $inputPath = if ($rawInput) { $rawInput.Trim().Trim('"', "'").Trim() } else { "" }

        if ($inputPath -and (Test-Path $inputPath)) {
            New-Item -ItemType Directory -Force -Path $INSTANCES_BASE | Out-Null
            Set-Content -Path (Join-Path $INSTANCES_BASE "claude_exe_path.txt") -Value $inputPath
            return $inputPath
        } else {
            Write-Host "[X] Claude Desktop executable not found." -ForegroundColor Red
            exit 1
        }
    }
    return $exe
}

function Get-InstanceList {
    if (-not (Test-Path $INSTANCES_BASE)) {
        return @()
    }
    Get-ChildItem -Path $INSTANCES_BASE -Directory | Select-Object -ExpandProperty Name
}

function List-Instances {
    Write-Host "`nClaude Desktop Instances" -ForegroundColor Cyan
    Write-Host "========================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  - default (built-in default data directory)"

    $instances = Get-InstanceList
    foreach ($name in $instances) {
        $shortcutName = "Claude - $name.lnk"
        $hasShortcut = Test-Path (Join-Path $DESKTOP_PATH $shortcutName)
        $shortcutStatus = if ($hasShortcut) { "has shortcut" } else { "no shortcut" }
        Write-Host "  - $name ($shortcutStatus)"
    }
    Write-Host ""
}

function Test-IsDefaultInstance ($name) {
    return ($name -eq "default")
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

$RESERVED_DEVICE_NAMES = @(
    "CON","PRN","AUX","NUL",
    "COM1","COM2","COM3","COM4","COM5","COM6","COM7","COM8","COM9",
    "LPT1","LPT2","LPT3","LPT4","LPT5","LPT6","LPT7","LPT8","LPT9"
)

# Read-Host returns whatever was typed, including stray whitespace. An instance name with a
# leading space resolves to a DIFFERENT directory than the same name without it, which makes
# Claude launch against an empty profile. Always run user input through this.
function Get-CleanInstanceName ($name) {
    if ($null -eq $name) { return "" }
    return $name.Trim()
}

function Test-ValidInstanceName ($name) {
    if (-not $name) { return $false }

    # Reject anything that would be silently rewritten or would resolve elsewhere.
    if ($name -ne $name.Trim()) { return $false }
    if ($name -match '[\\/:*?"<>|]') { return $false }
    if ($name -match '[\x00-\x1f]') { return $false }
    if ($name -match '^\.+$') { return $false }
    if ($name.EndsWith(".")) { return $false }
    if ($name.Length -gt 64) { return $false }
    if ($RESERVED_DEVICE_NAMES -contains $name.ToUpper()) { return $false }

    return $true
}

function Test-InstanceExists ($instanceName) {
    if (Test-IsDefaultInstance $instanceName) { return $true }
    if (-not $instanceName) { return $false }
    return (Test-Path (Join-Path $INSTANCES_BASE $instanceName) -PathType Container)
}

# Returns the instance name as it is spelled on disk, so "LANGE" resolves to "Lange".
# Windows paths are case-insensitive but the display should match reality.
function Resolve-InstanceName ($instanceName) {
    if (Test-IsDefaultInstance $instanceName) { return "default" }
    foreach ($existing in (Get-InstanceList)) {
        if ($existing -eq $instanceName) { return $existing }
    }
    return $instanceName
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

# The Claude Code CLI binary is ALSO named claude.exe, and it installs itself inside instance
# data directories (e.g. ~\.claude-instances\<name>\claude-code\<ver>\claude.exe). Matching on
# process name alone therefore selects running Claude Code sessions as well, and force-killing
# those destroys the user's in-progress work.
#
# This deliberately errs toward missing a Claude Desktop process rather than ever selecting
# something else: a process is only returned when its executable path is readable AND matches
# the resolved Claude Desktop executable.
function Get-ClaudeDesktopProcesses {
    $desktopExe = Get-ClaudeExePath
    if (-not $desktopExe) { return @() }

    $procs = Get-Process -Name "claude" -ErrorAction SilentlyContinue
    if (-not $procs) { return @() }

    $matched = foreach ($p in $procs) {
        $procPath = try { $p.Path } catch { $null }
        if (-not $procPath) { continue }
        if ($procPath -like "*\claude-code\*") { continue }
        if ($procPath -eq $desktopExe) { $p }
    }

    return @($matched)
}

function Test-ClaudeIsRunning {
    return ((Get-ClaudeDesktopProcesses).Count -gt 0)
}

function Stop-ClaudeProcesses {
    $procs = Get-ClaudeDesktopProcesses
    if ($procs.Count -eq 0) { return }

    Write-Host "[*] Stopping $($procs.Count) running Claude Desktop process(es)..." -ForegroundColor Yellow
    foreach ($p in $procs) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 1
    Write-Host "[+] Running Claude Desktop processes stopped." -ForegroundColor Green
    Write-Host "    (Claude Code CLI sessions were left untouched.)" -ForegroundColor Gray
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

function Launch-Instance ($instanceName, [switch]$AllowCreate) {
    $instanceName = Get-CleanInstanceName $instanceName

    if (-not (Test-ValidInstanceName $instanceName)) {
        Write-Host "[X] Invalid instance name: '$instanceName'" -ForegroundColor Red
        Write-Host "    Avoid path separators, special characters, leading/trailing spaces," -ForegroundColor Gray
        Write-Host "    reserved device names (CON, PRN, AUX, NUL, COM1-9, LPT1-9), and names over 64 chars." -ForegroundColor Gray
        return
    }

    # Launching an instance must never silently create one. Passing a name that does not exist
    # (a typo, a stray space, a name that only differs by whitespace) used to create a fresh
    # empty data directory and start Claude against it, which presents as a signed-out
    # "wiped" profile with no indication that anything went wrong.
    if (-not (Test-InstanceExists $instanceName)) {
        if (-not $AllowCreate) {
            Write-Host "[X] Instance '$instanceName' does not exist." -ForegroundColor Red
            Write-Host "    Launching it would start Claude against an empty profile (signed out, no history)." -ForegroundColor Yellow
            Write-Host ""
            List-Instances
            Write-Host "    To create a new instance, use menu option 4." -ForegroundColor Gray
            return
        }
        Write-Host "[*] Creating new instance '$instanceName'." -ForegroundColor Cyan
    }

    $instanceName = Resolve-InstanceName $instanceName

    $claudeExe = Ensure-ClaudeExe

    Write-Host "`n[*] Launching Claude Desktop instance: $instanceName..." -ForegroundColor Cyan

    $outLog = Join-Path $env:TEMP "claude_app_out.log"
    $errLog = Join-Path $env:TEMP "claude_app_err.log"

    if (Test-IsDefaultInstance $instanceName) {
        Start-Process -FilePath $claudeExe -RedirectStandardOutput $outLog -RedirectStandardError $errLog
        Write-Host "[+] Claude Desktop launched (default instance)" -ForegroundColor Green
    } else {
        $instanceDir = Join-Path $INSTANCES_BASE $instanceName
        New-Item -ItemType Directory -Force -Path $instanceDir | Out-Null
        
        Start-Process -FilePath $claudeExe -ArgumentList "--user-data-dir=`"$instanceDir`"" -RedirectStandardOutput $outLog -RedirectStandardError $errLog
        Write-Host "[+] Claude Desktop launched (instance: $instanceName)" -ForegroundColor Green
        Write-Host "    Data Dir: $instanceDir" -ForegroundColor Gray
    }

    $shortcutName = "Claude - $instanceName.lnk"
    if (-not (Test-Path (Join-Path $DESKTOP_PATH $shortcutName))) {
        Write-Host "    Tip: Run '.\claude_quick.ps1 shortcut $instanceName' to create a Desktop shortcut." -ForegroundColor Yellow
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

function Show-Diagnostics {
    Write-Host "`nClaude Desktop Diagnostics (Windows)" -ForegroundColor Cyan
    Write-Host "====================================" -ForegroundColor Cyan

    $exe = Get-ClaudeExePath
    if ($exe) {
        Write-Host "[+] Claude.exe found: $exe" -ForegroundColor Green
    } else {
        Write-Host "[X] Claude.exe NOT found in standard locations." -ForegroundColor Red
        Write-Host "    Download from https://claude.ai/download" -ForegroundColor Yellow
    }

    Write-Host "`nInstance Directory Base: $INSTANCES_BASE"
    if (Test-Path $INSTANCES_BASE) {
        $instances = Get-InstanceList
        if ($instances.Count -gt 0) {
            foreach ($i in $instances) {
                Write-Host "  - $i"
            }
        } else {
            Write-Host "  (no custom instances found)"
        }
    } else {
        Write-Host "  (instances directory does not exist yet)"
    }

    Write-Host "`nDesktop Shortcuts:"
    $shortcuts = Get-ChildItem -Path $DESKTOP_PATH -Filter "Claude - *.lnk" -ErrorAction SilentlyContinue
    if ($shortcuts) {
        foreach ($s in $shortcuts) {
            Write-Host "  - $($s.Name)"
        }
    } else {
        Write-Host "  (none)"
    }
    Write-Host ""
}

function Get-DefaultInstanceDir {
    $candidates = @()

    # Standard Win32 APPDATA path
    $stdPath = Join-Path $env:APPDATA "Claude"
    $candidates += $stdPath

    # Windows Store / MSIX package sandboxed APPDATA paths
    $packagesBase = Join-Path $env:LOCALAPPDATA "Packages"
    if (Test-Path $packagesBase) {
        $storeDirs = Get-ChildItem -Path $packagesBase -Filter "Claude_*" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            Join-Path $_.FullName "LocalCache\Roaming\Claude"
        }
        if ($storeDirs) {
            $candidates += $storeDirs
        }
    }

    # Additional fallback
    $localPath = Join-Path $env:LOCALAPPDATA "Claude"
    if ($localPath -ne $stdPath) {
        $candidates += $localPath
    }

    # 1. Prefer candidate directory containing plan-usage-history.json
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c "plan-usage-history.json")) {
            return $c
        }
    }

    # 2. Prefer candidate directory containing config.json
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c "config.json")) {
            return $c
        }
    }

    # 3. Prefer first candidate directory that exists
    foreach ($c in $candidates) {
        if (Test-Path $c) {
            return $c
        }
    }

    return $stdPath
}

function Get-InstanceUsageStats ($inst) {
    $isDefault = Test-IsDefaultInstance $inst
    $dir = if ($isDefault) { Get-DefaultInstanceDir } else { Join-Path $INSTANCES_BASE $inst }
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
