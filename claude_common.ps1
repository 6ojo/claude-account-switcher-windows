<#
.SYNOPSIS
    Shared helpers for claude-account-switcher.

.DESCRIPTION
    Dot-sourced by claude_quick.ps1, claude_auto_select.ps1, and claude_diagnose.ps1.
    Holds everything more than one entry point needs: path constants, Claude Desktop
    executable resolution, instance discovery and name validation, process filtering,
    usage statistics, and instance launching.

    This file previously existed as copy-pasted duplicates in each entry point, which
    had already started to drift. It is not meant to be run directly.
#>

$INSTANCES_BASE = Join-Path $HOME ".claude-instances"
$DESKTOP_PATH = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::Desktop)

$RESERVED_DEVICE_NAMES = @(
    "CON","PRN","AUX","NUL",
    "COM1","COM2","COM3","COM4","COM5","COM6","COM7","COM8","COM9",
    "LPT1","LPT2","LPT3","LPT4","LPT5","LPT6","LPT7","LPT8","LPT9"
)

# ---------------------------------------------------------------------------
# Claude Desktop executable resolution
# ---------------------------------------------------------------------------

# Cache: Get-AppxPackage costs a few hundred ms and this is called repeatedly.
# Only successful lookups are cached, so Ensure-ClaudeExe saving a custom path still takes effect.
$script:ClaudeExeDetail = $null

function Get-ClaudeExeCandidatePaths {
    return @(
        "$env:LOCALAPPDATA\Programs\Claude\Claude.exe",
        "$env:LOCALAPPDATA\Claude\Claude.exe",
        "$env:LOCALAPPDATA\AnthropicClaude\Claude.exe",
        "$env:LOCALAPPDATA\Programs\claude-desktop\Claude.exe",
        "$env:ProgramFiles\Claude\Claude.exe",
        "${env:ProgramFiles(x86)}\Claude\Claude.exe"
    )
}

# Returns @{ Path; Source } describing how the executable was located, or $null.
# Show-Diagnostics reports Source so a failing machine can be diagnosed remotely.
function Get-ClaudeExeDetail {
    if ($script:ClaudeExeDetail) { return $script:ClaudeExeDetail }

    $found = $null

    foreach ($path in (Get-ClaudeExeCandidatePaths)) {
        if (Test-Path $path) {
            $found = [PSCustomObject]@{ Path = $path; Source = "standard install path" }
            break
        }
    }

    # Windows Store / MSIX installation.
    # Note: recursively searching $env:ProgramFiles\WindowsApps returns nothing for a
    # non-elevated user, because the directory ACL denies enumeration. Direct path access
    # to the same files works fine, so resolve the install location instead of searching.
    if (-not $found) {
        try {
            foreach ($pkg in (Get-AppxPackage -Name "*Claude*" -ErrorAction SilentlyContinue)) {
                if (-not $pkg.InstallLocation) { continue }
                foreach ($rel in @("app\Claude.exe", "Claude.exe")) {
                    $msixExe = Join-Path $pkg.InstallLocation $rel
                    if (Test-Path $msixExe) {
                        $found = [PSCustomObject]@{ Path = $msixExe; Source = "MSIX package $($pkg.Name) $($pkg.Version)" }
                        break
                    }
                }
                if ($found) { break }
            }
        } catch {}
    }

    # Claude registers itself as the claude:// protocol handler on every launch, so this
    # key holds the exe path of whichever build is installed (including MSIX).
    if (-not $found) {
        try {
            $handler = (Get-ItemProperty -Path "Registry::HKEY_CLASSES_ROOT\claude\shell\open\command" -ErrorAction SilentlyContinue).'(default)'
            if ($handler -and $handler -match '^"([^"]+\.exe)"') {
                $handlerExe = $Matches[1]
                if (Test-Path $handlerExe) {
                    $found = [PSCustomObject]@{ Path = $handlerExe; Source = "claude:// protocol handler registry key" }
                }
            }
        } catch {}
    }

    # Last resort: enumerate WindowsApps. Only succeeds when running elevated.
    if (-not $found) {
        $winAppsClaude = Get-ChildItem -Path "$env:ProgramFiles\WindowsApps" -Filter "claude.exe" -Recurse -Depth 3 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName -First 1
        if ($winAppsClaude -and (Test-Path $winAppsClaude)) {
            $found = [PSCustomObject]@{ Path = $winAppsClaude; Source = "WindowsApps search (elevated)" }
        }
    }

    if (-not $found) {
        $configPath = Join-Path $INSTANCES_BASE "claude_exe_path.txt"
        if (Test-Path $configPath) {
            $rawContent = Get-Content $configPath -Raw
            if ($rawContent) {
                $savedPath = $rawContent.Trim().Trim('"', "'").Trim()
                if ($savedPath -and (Test-Path $savedPath)) {
                    $found = [PSCustomObject]@{ Path = $savedPath; Source = "saved custom path (claude_exe_path.txt)" }
                }
            }
        }
    }

    if ($found) { $script:ClaudeExeDetail = $found }
    return $found
}

function Get-ClaudeExePath {
    $detail = Get-ClaudeExeDetail
    if ($detail) { return $detail.Path }
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

# ---------------------------------------------------------------------------
# Instance discovery and name handling
# ---------------------------------------------------------------------------

function Get-InstanceList {
    if (-not (Test-Path $INSTANCES_BASE)) {
        return @()
    }
    Get-ChildItem -Path $INSTANCES_BASE -Directory | Select-Object -ExpandProperty Name
}

function Test-IsDefaultInstance ($name) {
    return ($name -eq "default")
}

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

# ---------------------------------------------------------------------------
# Process handling
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Launching
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Usage statistics
# ---------------------------------------------------------------------------

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
