<#
.SYNOPSIS
    Claude Desktop Multi-Instance Launcher for Windows
    Translated from stracker-phil/claude_quick.sh

.DESCRIPTION
    Uses Electron's --user-data-dir flag to run fully isolated Claude Desktop instances on Windows.
    Each instance gets its own data directory (config, sessions, plugins, etc.).

.USAGE
    .\claude_quick.ps1                    # Show interactive menu
    .\claude_quick.ps1 <instance>         # Launch named instance
    .\claude_quick.ps1 list               # List all instances
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

    # Search WindowsApps (MSIX/Store installation)
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

function Test-ValidInstanceName ($name) {
    if (-not $name) { return $false }
    if ($name -match '[\\/:*?"<>|]' -or $name -eq "." -or $name -eq "..") {
        return $false
    }
    return $true
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

function Launch-Instance ($instanceName) {
    if (-not (Test-ValidInstanceName $instanceName)) {
        Write-Host "[X] Invalid instance name. Do not use path separators or special characters." -ForegroundColor Red
        return
    }

    $claudeExe = Ensure-ClaudeExe

    Write-Host "`n[*] Launching Claude Desktop instance: $instanceName..." -ForegroundColor Cyan

    if (Test-IsDefaultInstance $instanceName) {
        Start-Process -FilePath $claudeExe
        Write-Host "[+] Claude Desktop launched (default instance)" -ForegroundColor Green
    } else {
        $instanceDir = Join-Path $INSTANCES_BASE $instanceName
        New-Item -ItemType Directory -Force -Path $instanceDir | Out-Null
        
        Start-Process -FilePath $claudeExe -ArgumentList "--user-data-dir=`"$instanceDir`""
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
        List-Instances
        $instanceName = Read-Host "Instance name to delete"
    }

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

# Main Script Logic
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "  Claude Desktop Multi-Instance Launcher" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan

$cmdLower = if ($Command) { $Command.ToLower() } else { "" }

switch ($cmdLower) {
    "list" {
        List-Instances
        exit 0
    }
    "delete" {
        Delete-Instance $Name
        exit 0
    }
    "shortcut" {
        if (-not $Name) {
            List-Instances
            $Name = Read-Host "Instance name for shortcut"
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
    Write-Host "1. Launch default instance"
    Write-Host "2. Select existing instance"
    Write-Host "3. Create new instance"
    Write-Host "4. Delete instance"
    Write-Host "5. Create Desktop shortcut"
    Write-Host "6. Diagnostics"
    Write-Host "7. Exit"
    Write-Host ""
    Write-Host "Tip: When logging into a new instance for the first time via browser SSO," -ForegroundColor Yellow
    Write-Host "     keep other Claude instances closed so the callback opens in the active instance." -ForegroundColor Yellow
    Write-Host ""
    $choice = Read-Host "Select (1-7)"

    switch ($choice) {
        "1" {
            Launch-Instance "default"
            $loop = $false
        }
        "2" {
            List-Instances
            $n = Read-Host "Instance name"
            if ($n) {
                Launch-Instance $n
                $loop = $false
            }
        }
        "3" {
            $n = Read-Host "New instance name"
            if (-not $n) {
                Write-Host "[X] No name provided." -ForegroundColor Red
            } elseif (Test-IsDefaultInstance $n) {
                Write-Host "[X] 'default' is reserved for the built-in instance." -ForegroundColor Red
            } else {
                Launch-Instance $n
                $createSc = Read-Host "Create a Desktop shortcut for '$n'? (Y/n)"
                if ($createSc -notmatch '^[Nn]$') {
                    Create-DesktopShortcut $n
                }
                $loop = $false
            }
        }
        "4" {
            Delete-Instance
            Write-Host ""
            Read-Host "Press Enter to continue..."
            $loop = $true
        }
        "5" {
            List-Instances
            $n = Read-Host "Instance name for shortcut"
            if ($n) { Create-DesktopShortcut $n }
            Write-Host ""
            Read-Host "Press Enter to continue..."
            $loop = $true
        }
        "6" {
            Show-Diagnostics
            Write-Host ""
            Read-Host "Press Enter to continue..."
            $loop = $true
        }
        "7" {
            $loop = $false
        }
        Default {
            Write-Host "Invalid selection." -ForegroundColor Red
            $loop = $true
        }
    }
} while ($loop)
