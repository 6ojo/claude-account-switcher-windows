<#
.SYNOPSIS
    Read-only diagnostics for claude-account-switcher.

.DESCRIPTION
    Dot-sourced by claude_quick.ps1 and reached via 'claude_quick.ps1 diagnose' or
    menu option 8. Requires claude_common.ps1 to be dot-sourced first.

    Reports every environment fact this tool depends on so a machine that misbehaves
    can be diagnosed from its output alone, without remote access. Prints no secrets:
    token and account fields are reported as present/absent booleans only.
#>

function Show-Diagnostics {
    $warnings = New-Object System.Collections.ArrayList

    function Add-Warn ($msg) { [void]$warnings.Add($msg) }
    function Write-Section ($title) {
        Write-Host ""
        Write-Host $title -ForegroundColor Cyan
        Write-Host ("-" * $title.Length) -ForegroundColor Cyan
    }
    function Write-Field ($label, $value, $color) {
        if (-not $color) { $color = "Gray" }
        Write-Host ("  {0,-24} {1}" -f "$label :", $value) -ForegroundColor $color
    }

    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "  Claude Account Switcher - Diagnostics (read-only)" -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan

    # ---------------------------------------------------------------- environment
    Write-Section "1. Environment"
    Write-Field "Timestamp" (Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz")
    Write-Field "OS" "$([System.Environment]::OSVersion.VersionString) ($(if([Environment]::Is64BitOperatingSystem){'x64'}else{'x86'}))"
    Write-Field "PowerShell" "$($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Write-Field "Elevated" $isAdmin
    Write-Field "Locale" (Get-Culture).Name

    try {
        $policies = Get-ExecutionPolicy -List | Where-Object { $_.ExecutionPolicy -ne "Undefined" }
        if ($policies) {
            foreach ($p in $policies) { Write-Field "ExecPolicy $($p.Scope)" $p.ExecutionPolicy }
            $blocking = $policies | Where-Object { $_.Scope -in @("MachinePolicy","UserPolicy") -and $_.ExecutionPolicy -in @("AllSigned","Restricted") }
            if ($blocking) { Add-Warn "Group Policy sets execution policy to '$($blocking[0].ExecutionPolicy)'. The -ExecutionPolicy Bypass flag in claude_quick.bat CANNOT override a Group Policy scope, so this tool may refuse to run." }
        }
    } catch { Write-Field "ExecPolicy" "could not read" "Yellow" }

    # ---------------------------------------------------------------- paths
    Write-Section "2. Paths"
    Write-Field "`$HOME" $HOME
    Write-Field "USERPROFILE" $env:USERPROFILE
    Write-Field "HOMEDRIVE" $env:HOMEDRIVE
    Write-Field "HOMEPATH" $env:HOMEPATH
    Write-Field "HOMESHARE" $(if ($env:HOMESHARE) { $env:HOMESHARE } else { "(not set)" })
    if ($HOME -ne $env:USERPROFILE) {
        Write-Field "HOME == USERPROFILE" "NO - MISMATCH" "Red"
        Add-Warn "`$HOME ('$HOME') differs from USERPROFILE ('$env:USERPROFILE'). Instance directories are built from `$HOME, so they may not be where you expect, and could move between runs."
    } else {
        Write-Field "HOME == USERPROFILE" "yes" "Green"
    }

    Write-Field "Instances base" $INSTANCES_BASE
    Write-Field "  exists" (Test-Path $INSTANCES_BASE)
    Write-Field "Desktop" $DESKTOP_PATH
    Write-Field "  exists" (Test-Path $DESKTOP_PATH)
    if (-not (Test-Path $DESKTOP_PATH)) {
        Add-Warn "Desktop path '$DESKTOP_PATH' does not exist or is unreachable. Shortcut creation and detection will fail."
    }

    # ---------------------------------------------------------------- install
    Write-Section "3. Claude Desktop installation"
    $detail = Get-ClaudeExeDetail
    if ($detail) {
        Write-Field "Executable" $detail.Path "Green"
        Write-Field "Located via" $detail.Source
    } else {
        Write-Field "Executable" "NOT FOUND" "Red"
        Add-Warn "Claude Desktop executable could not be located. You will be prompted to enter its path. Install from https://claude.ai/download"
    }

    try {
        $pkgs = @(Get-AppxPackage -Name "*Claude*" -ErrorAction SilentlyContinue)
        if ($pkgs.Count -gt 0) {
            foreach ($p in $pkgs) { Write-Field "MSIX package" "$($p.Name) $($p.Version)" }
            Write-Field "Install type" "Windows Store / MSIX"
        } else {
            Write-Field "Install type" "classic installer (no MSIX package found)"
        }
    } catch { Write-Field "MSIX query" "Get-AppxPackage unavailable" "Yellow" }

    Write-Host "  Standard candidate paths probed:" -ForegroundColor Gray
    foreach ($c in (Get-ClaudeExeCandidatePaths)) {
        $hit = Test-Path $c
        Write-Host ("    [{0}] {1}" -f $(if ($hit) { "x" } else { " " }), $c) -ForegroundColor $(if ($hit) { "Green" } else { "DarkGray" })
    }

    # ---------------------------------------------------------------- processes
    Write-Section "4. Running processes named 'claude'"
    $allProcs = @(Get-Process -Name "claude" -ErrorAction SilentlyContinue)
    if ($allProcs.Count -eq 0) {
        Write-Host "  (none running)" -ForegroundColor Gray
    } else {
        $desktopProcs = Get-ClaudeDesktopProcesses
        $desktopIds = @($desktopProcs | ForEach-Object { $_.Id })
        $unreadable = 0
        foreach ($p in $allProcs) {
            $path = try { $p.Path } catch { $null }
            if (-not $path) { $unreadable++; Write-Host ("    PID {0,-7} <path unreadable>" -f $p.Id) -ForegroundColor DarkYellow; continue }
            $tag = if ($desktopIds -contains $p.Id) { "DESKTOP (would be closed)" }
                   elseif ($path -like "*\claude-code\*") { "Claude Code CLI (protected)" }
                   else { "other claude.exe (left alone)" }
            $col = if ($desktopIds -contains $p.Id) { "White" } else { "Green" }
            Write-Host ("    PID {0,-7} {1,-28} {2}" -f $p.Id, $tag, $path) -ForegroundColor $col
        }
        Write-Field "Total" $allProcs.Count
        Write-Field "Claude Desktop" $desktopProcs.Count
        if ($unreadable -gt 0) {
            Add-Warn "$unreadable process(es) named 'claude' have an unreadable executable path (likely elevated or another user). They are never selected for closing, so the close prompt may not appear when it should."
        }
    }

    # ---------------------------------------------------------------- default data dir
    Write-Section "5. Default account data directory"
    $selected = Get-DefaultInstanceDir
    $candidates = New-Object System.Collections.ArrayList
    [void]$candidates.Add((Join-Path $env:APPDATA "Claude"))
    $packagesBase = Join-Path $env:LOCALAPPDATA "Packages"
    if (Test-Path $packagesBase) {
        Get-ChildItem -Path $packagesBase -Filter "Claude_*" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            [void]$candidates.Add((Join-Path $_.FullName "LocalCache\Roaming\Claude"))
        }
    }
    $localPath = Join-Path $env:LOCALAPPDATA "Claude"
    if ($localPath -ne (Join-Path $env:APPDATA "Claude")) { [void]$candidates.Add($localPath) }

    # Only directories that actually hold usage history are relevant to the stale-profile
    # question. A directory that merely exists but is empty is not a competing profile.
    $withUsage = New-Object System.Collections.ArrayList
    foreach ($c in $candidates) {
        $exists = Test-Path $c
        $marker = if ($c -eq $selected) { "-> " } else { "   " }
        Write-Host ("  {0}{1}" -f $marker, $c) -ForegroundColor $(if ($c -eq $selected) { "Green" } else { "Gray" })
        if (-not $exists) { Write-Host "       (does not exist)" -ForegroundColor DarkGray; continue }

        $usagePath = Join-Path $c "plan-usage-history.json"
        if (Test-Path $usagePath) {
            $ui = Get-Item $usagePath
            [void]$withUsage.Add([PSCustomObject]@{ Dir = $c; Key = "$($ui.Length)/$($ui.LastWriteTime.Ticks)" })
        }

        foreach ($f in @("plan-usage-history.json","config.json")) {
            $fp = Join-Path $c $f
            if (Test-Path $fp) {
                $fi = Get-Item $fp
                Write-Host ("       {0,-26} {1,9} bytes  modified {2}" -f $f, $fi.Length, $fi.LastWriteTime) -ForegroundColor DarkGray
            } else {
                Write-Host ("       {0,-26} missing" -f $f) -ForegroundColor DarkGray
            }
        }
    }
    Write-Field "Selected" $selected "Green"

    if ($withUsage.Count -gt 1) {
        $distinct = @($withUsage | Select-Object -ExpandProperty Key -Unique)
        if ($distinct.Count -gt 1) {
            Write-Field "Competing profiles" "$($withUsage.Count), CONTENTS DIFFER" "Red"
            Add-Warn "Found $($withUsage.Count) default data directories with DIFFERENT usage history. Usage stats and auto-select read only the first one found, which may be a stale profile from a previous install. Directories: $(($withUsage | ForEach-Object { $_.Dir }) -join ' | ')"
        } else {
            Write-Field "Competing profiles" "$($withUsage.Count), contents identical (same underlying files)" "Green"
        }
    }

    # ---------------------------------------------------------------- instances
    Write-Section "6. Instances"
    $instances = @(Get-InstanceList)
    if ($instances.Count -eq 0) {
        Write-Host "  (no custom instances yet)" -ForegroundColor Gray
    }
    foreach ($name in $instances) {
        $dir = Join-Path $INSTANCES_BASE $name
        $cfgPath = Join-Path $dir "config.json"
        $hasToken = $false
        $hasAcct = $false
        $cfgOk = $false
        if (Test-Path $cfgPath) {
            try {
                $j = Get-Content $cfgPath -Raw | ConvertFrom-Json
                $cfgOk = $true
                $hasToken = [bool]($j.'oauth:tokenCacheV2' -or $j.'oauth:tokenCache')
                $hasAcct = [bool]$j.lastKnownAccountUuid
            } catch {}
        }
        $shortcut = Test-Path (Join-Path $DESKTOP_PATH "Claude - $name.lnk")

        Write-Host "  - $name" -ForegroundColor White
        Write-Host ("      dir            : {0}" -f $dir) -ForegroundColor DarkGray
        Write-Host ("      config.json    : {0}" -f $(if ($cfgOk) { "ok" } elseif (Test-Path $cfgPath) { "PRESENT BUT UNPARSEABLE" } else { "missing" })) -ForegroundColor $(if ($cfgOk) { "DarkGray" } else { "Yellow" })
        Write-Host ("      signed in      : {0}" -f $(if ($hasToken) { "yes (token present)" } else { "NO - no oauth token stored" })) -ForegroundColor $(if ($hasToken) { "Green" } else { "Red" })
        Write-Host ("      account id set : {0}" -f $hasAcct) -ForegroundColor DarkGray
        Write-Host ("      desktop shortcut: {0}" -f $shortcut) -ForegroundColor DarkGray

        if (-not $hasToken) {
            Add-Warn "Instance '$name' has no stored oauth token, so it will open signed out. If you expected it to be signed in, the sign-in code was never redeemed into this profile."
        }
        if ($name -ne $name.Trim() -or -not (Test-ValidInstanceName $name)) {
            Add-Warn "Instance directory name '$name' contains characters this tool now rejects (stray whitespace, trailing dot, or similar). It was probably created by a typo and may be a duplicate of another instance."
        }
    }

    # ---------------------------------------------------------------- protocol handler
    Write-Section "7. claude:// protocol handler"
    try {
        $cmd = (Get-ItemProperty -Path "Registry::HKEY_CLASSES_ROOT\claude\shell\open\command" -ErrorAction SilentlyContinue).'(default)'
        if ($cmd) {
            Write-Host "  $cmd" -ForegroundColor Gray
            if ($cmd -match '--user-data-dir') {
                Write-Field "Targets an instance" "yes" "Green"
            } else {
                Write-Field "Targets an instance" "no - default profile only" "Yellow"
                Write-Host "  Browser sign-in links will open the DEFAULT profile. Claude re-registers this" -ForegroundColor Yellow
                Write-Host "  key on every launch, so this is expected. Paste the sign-in code manually." -ForegroundColor Yellow
            }
        } else {
            Write-Field "Registration" "none found" "Yellow"
            Add-Warn "No claude:// handler is registered. Browser sign-in links will not open Claude at all."
        }
    } catch { Write-Field "Registration" "could not read" "Yellow" }

    # ---------------------------------------------------------------- shortcuts
    Write-Section "8. Desktop shortcuts"
    $shortcuts = @(Get-ChildItem -Path $DESKTOP_PATH -Filter "Claude*.lnk" -ErrorAction SilentlyContinue)
    if ($shortcuts.Count -eq 0) {
        Write-Host "  (none)" -ForegroundColor Gray
    } else {
        $wsh = $null
        try { $wsh = New-Object -ComObject WScript.Shell } catch {
            Add-Warn "Could not create a WScript.Shell COM object. Shortcut creation will fail on this machine (often a lockdown or antivirus policy)."
        }
        foreach ($s in $shortcuts) {
            Write-Host "  - $($s.Name)" -ForegroundColor White
            if ($wsh) {
                try {
                    $sc = $wsh.CreateShortcut($s.FullName)
                    Write-Host ("      target : {0}" -f $sc.TargetPath) -ForegroundColor DarkGray
                    Write-Host ("      args   : {0}" -f $(if ($sc.Arguments) { $sc.Arguments } else { "(none - default profile)" })) -ForegroundColor DarkGray
                } catch {}
            }
        }
        if ($wsh) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($wsh) }
    }

    # ---------------------------------------------------------------- summary
    Write-Host ""
    if ($warnings.Count -eq 0) {
        Write-Host "==================================================" -ForegroundColor Green
        Write-Host "  No problems detected." -ForegroundColor Green
        Write-Host "==================================================" -ForegroundColor Green
    } else {
        Write-Host "==================================================" -ForegroundColor Yellow
        Write-Host "  $($warnings.Count) issue(s) detected" -ForegroundColor Yellow
        Write-Host "==================================================" -ForegroundColor Yellow
        $n = 1
        foreach ($w in $warnings) {
            Write-Host ""
            Write-Host "  $n. $w" -ForegroundColor Yellow
            $n++
        }
    }
    Write-Host ""
    Write-Host "  Paste this entire output into a bug report. It contains no tokens or secrets." -ForegroundColor Gray
    Write-Host ""
}
