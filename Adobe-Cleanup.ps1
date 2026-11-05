<#
.SYNOPSIS
    Force-quits, uninstalls, and wipes all Adobe products (any year/version) from Windows.

.DESCRIPTION
    1. Self-elevates to Administrator
    2. Force-kills every Adobe process and stops/deletes Adobe services and scheduled tasks
    3. Detects installed Adobe products from the registry (any version) and Store/Appx packages,
       and force-uninstalls them silently
    4. Deletes leftover files, shortcuts, and registry keys (system-wide and for every user profile)

    WARNING: This is destructive. It also deletes Adobe user settings, presets, and caches.
    It does NOT delete your own project files unless they live inside an Adobe folder
    (e.g. Documents\Adobe).

.PARAMETER DryRun
    Show what would be removed without changing anything.

.PARAMETER Reboot
    Restart the computer when finished.

.PARAMETER KeepDocumentsAdobe
    Do not delete Documents\Adobe in user profiles (can contain user projects/presets).

.EXAMPLE
    # Pull and run from the cloud (elevated PowerShell):
    irm https://YOUR-HOST/Adobe-Cleanup.ps1 | iex

.EXAMPLE
    # Pull and run with parameters:
    & ([scriptblock]::Create((irm https://YOUR-HOST/Adobe-Cleanup.ps1))) -DryRun
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Reboot,
    [switch]$KeepDocumentsAdobe,
    # Internal: set when re-launched after self-elevation
    [string]$ScriptUrl
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

# ----------------------------------------------------------------------------
# Self-elevate (works when run from file; when piped via iex, re-downloads)
# ----------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host 'Not running as Administrator - relaunching elevated...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass')
    if ($PSCommandPath) {
        $argList += @('-File', "`"$PSCommandPath`"")
        if ($DryRun)             { $argList += '-DryRun' }
        if ($Reboot)             { $argList += '-Reboot' }
        if ($KeepDocumentsAdobe) { $argList += '-KeepDocumentsAdobe' }
    } else {
        Write-Host 'Script was piped in and cannot self-elevate. Open PowerShell as Administrator and run it again.' -ForegroundColor Red
        return
    }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    return
}

# ----------------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------------
$LogFile = Join-Path $env:TEMP ("AdobeCleanup_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
function Log {
    param([string]$Msg, [string]$Level = 'INFO')
    $color = switch ($Level) { 'WARN' {'Yellow'} 'ERR' {'Red'} 'OK' {'Green'} 'DRY' {'Cyan'} default {'Gray'} }
    $line = "[{0:HH:mm:ss}] [{1}] {2}" -f (Get-Date), $Level, $Msg
    Write-Host $line -ForegroundColor $color
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

function Act {
    # Run a scriptblock unless in dry-run mode
    param([string]$Description, [scriptblock]$Action)
    if ($DryRun) { Log "WOULD: $Description" 'DRY'; return }
    try { & $Action } catch { Log "FAILED: $Description - $($_.Exception.Message)" 'WARN' }
}

Log "Adobe cleanup starting. DryRun=$DryRun  Log=$LogFile"

# ----------------------------------------------------------------------------
# Patterns
# ----------------------------------------------------------------------------
# Process names that belong to Adobe (matched against process Name and Path)
$ProcessNamePattern = '^(Adobe|Acro|AGM|AGS|AIR|CCXProcess|CCLibrary|Creative Cloud|CoreSync|CRWindowsClientService|' +
                      'node$|armsvc|AdobeIPC|Photoshop|Illustrator|InDesign|Premiere|AfterFX|Audition|Animate|Dreamweaver|' +
                      'Bridge|Lightroom|Media Encoder|Character Animator|Prelude|Fuse|Dimension|XD|Substance|Acrobat|AcroRd|' +
                      'RdrCEF|Reader_sl|LogTransport|ACCStore|AdobeCollabSync|Adobe CEF Helper)'
$AdobePathPattern   = '\\Adobe(\\|$)|\\Common Files\\Adobe|\\Adobe Creative Cloud'

# ----------------------------------------------------------------------------
# 1. Force-quit everything Adobe
# ----------------------------------------------------------------------------
function Stop-AdobeProcesses {
    Log '--- Killing Adobe processes ---'
    $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $path = $null
        try { $path = $_.Path } catch {}
        ($_.ProcessName -match $ProcessNamePattern -and $_.ProcessName -ne 'node') -or
        ($path -and $path -match $AdobePathPattern) -or
        ($_.ProcessName -eq 'node' -and $path -match 'Adobe')
    }
    foreach ($p in $procs) {
        Act "Kill process $($p.ProcessName) (PID $($p.Id))" {
            Stop-Process -Id $p.Id -Force -ErrorAction Stop
            Log "Killed $($p.ProcessName) (PID $($p.Id))" 'OK'
        }
    }
    if (-not $DryRun) {
        # taskkill fallback for stubborn processes
        foreach ($p in $procs) { & taskkill.exe /F /T /PID $p.Id 2>&1 | Out-Null }
    }
}

function Stop-AdobeServices {
    Log '--- Stopping/removing Adobe services ---'
    $svcs = Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match '^(Adobe|AGM|AGS|ARMService|AdobeARM|AdobeUpdate|CCXProcess|CoreSync)' -or
        $_.DisplayName -match '^Adobe' -or
        $_.PathName -match '\\Adobe\\|\\Common Files\\Adobe'
    }
    foreach ($s in $svcs) {
        Act "Stop and delete service $($s.Name)" {
            & sc.exe stop $s.Name 2>&1 | Out-Null
            Start-Sleep -Milliseconds 500
            Get-Process -Id $s.ProcessId -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            & sc.exe delete $s.Name 2>&1 | Out-Null
            Log "Removed service $($s.Name)" 'OK'
        }
    }
}

function Remove-AdobeScheduledTasks {
    Log '--- Removing Adobe scheduled tasks ---'
    Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.TaskName -match 'Adobe|Acrobat|CCX|Creative Cloud' -or $_.TaskPath -match 'Adobe'
    } | ForEach-Object {
        $t = $_
        Act "Unregister scheduled task $($t.TaskPath)$($t.TaskName)" {
            Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false -ErrorAction Stop
            Log "Removed task $($t.TaskName)" 'OK'
        }
    }
}

# ----------------------------------------------------------------------------
# 2. Detect installed Adobe products (any year) and force uninstall
# ----------------------------------------------------------------------------
function Get-AdobeInstalls {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    # Include other loaded user hives
    Get-ChildItem Registry::HKEY_USERS -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'S-1-5-21-[\d-]+$' } | ForEach-Object {
            $roots += "Registry::$($_.Name)\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
        }

    foreach ($r in $roots) {
        Get-ItemProperty -Path $r -ErrorAction SilentlyContinue | Where-Object {
            $_.DisplayName -and (
                $_.Publisher -match 'Adobe' -or
                $_.DisplayName -match '^(Adobe|Acrobat|Photoshop|Illustrator|InDesign|Premiere|After Effects|Lightroom|Creative Cloud)'
            )
        } | ForEach-Object {
            [pscustomobject]@{
                Name        = $_.DisplayName
                Version     = $_.DisplayVersion
                Key         = $_.PSPath
                KeyName     = $_.PSChildName
                Uninstall   = $_.UninstallString
                QuietUninst = $_.QuietUninstallString
                IsMsi       = ($_.WindowsInstaller -eq 1) -or ($_.PSChildName -match '^\{[0-9A-Fa-f-]{36}\}$')
            }
        }
    }
}

function Invoke-Silent {
    # Start a process, wait up to $TimeoutSec, kill if it hangs
    param([string]$File, [string]$Args, [int]$TimeoutSec = 900)
    $p = Start-Process -FilePath $File -ArgumentList $Args -PassThru -WindowStyle Hidden -ErrorAction Stop
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        Log "Timed out: $File $Args - killing" 'WARN'
        & taskkill.exe /F /T /PID $p.Id 2>&1 | Out-Null
        return -1
    }
    return $p.ExitCode
}

function Uninstall-AdobeProducts {
    Log '--- Detecting and uninstalling Adobe products ---'

    # Creative Cloud's own uninstaller first (removes the CC desktop app cleanly)
    $ccUninst = @(
        "${env:ProgramFiles(x86)}\Adobe\Adobe Creative Cloud\Utils\Creative Cloud Uninstaller.exe",
        "${env:ProgramFiles}\Adobe\Adobe Creative Cloud\Utils\Creative Cloud Uninstaller.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($ccUninst) {
        Act "Run Creative Cloud Uninstaller" {
            $rc = Invoke-Silent -File $ccUninst -Args '-u' -TimeoutSec 600
            Log "Creative Cloud Uninstaller exit code: $rc"
        }
        Stop-AdobeProcesses
    }

    $installs = @(Get-AdobeInstalls | Sort-Object Name -Unique)
    if (-not $installs) { Log 'No Adobe products found in registry.' }
    else {
        Log ("Found {0} Adobe product(s):" -f $installs.Count)
        $installs | ForEach-Object { Log ("  - {0} {1}" -f $_.Name, $_.Version) }
    }

    foreach ($app in $installs) {
        Stop-AdobeProcesses   # make sure nothing is holding files before each uninstall
        Act "Uninstall $($app.Name) $($app.Version)" {
            $rc = $null
            if ($app.IsMsi -and $app.KeyName -match '^\{[0-9A-Fa-f-]{36}\}$') {
                $rc = Invoke-Silent -File 'msiexec.exe' -Args "/x $($app.KeyName) /qn /norestart REBOOT=ReallySuppress"
            }
            elseif ($app.QuietUninst) {
                $rc = Invoke-Silent -File 'cmd.exe' -Args "/c `"$($app.QuietUninst)`""
            }
            elseif ($app.Uninstall) {
                $u = $app.Uninstall
                if ($u -match 'msiexec' -and $u -match '(\{[0-9A-Fa-f-]{36}\})') {
                    $rc = Invoke-Silent -File 'msiexec.exe' -Args "/x $($Matches[1]) /qn /norestart REBOOT=ReallySuppress"
                }
                else {
                    # Adobe's own Setup.exe-style uninstallers and InstallShield/NSIS-style ones
                    $rc = Invoke-Silent -File 'cmd.exe' -Args "/c `"$u`" /S /silent /quiet /norestart" -TimeoutSec 600
                }
            }
            Log "$($app.Name): exit code $rc" ($(if ($rc -in 0,3010,1641) {'OK'} else {'WARN'}))
        }
    }

    # Microsoft Store / Appx versions (Adobe Express, Photoshop Express, Lightroom, etc.)
    Log '--- Removing Adobe Appx/Store packages ---'
    Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'Adobe' -or $_.Publisher -match 'Adobe' } | ForEach-Object {
            $pkg = $_
            Act "Remove Appx $($pkg.Name)" {
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
                Log "Removed Appx $($pkg.Name)" 'OK'
            }
        }
    Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match 'Adobe' } | ForEach-Object {
            $pp = $_
            Act "Remove provisioned Appx $($pp.DisplayName)" {
                Remove-AppxProvisionedPackage -Online -PackageName $pp.PackageName -ErrorAction Stop | Out-Null
            }
        }
}

# ----------------------------------------------------------------------------
# 3. Delete leftover files
# ----------------------------------------------------------------------------
function Remove-PathForce {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Act "Delete $Path" {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $Path) {
            # Take ownership + grant rights, then retry
            & takeown.exe /F "$Path" /R /D Y 2>&1 | Out-Null
            & icacls.exe "$Path" /grant "*S-1-5-32-544:(OI)(CI)F" /T /C /Q 2>&1 | Out-Null
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $Path) {
            & cmd.exe /c "rd /s /q `"$Path`"" 2>&1 | Out-Null
        }
        if (Test-Path -LiteralPath $Path) { Log "Could not fully delete (in use?): $Path - will need a reboot" 'WARN'; $script:NeedReboot = $true }
        else { Log "Deleted $Path" 'OK' }
    }
}

function Remove-AdobeFiles {
    Log '--- Deleting Adobe files ---'
    $pf   = $env:ProgramFiles
    $pf86 = ${env:ProgramFiles(x86)}
    $systemPaths = @(
        "$pf\Adobe", "$pf86\Adobe",
        "$pf\Common Files\Adobe", "$pf86\Common Files\Adobe",
        "$env:ProgramData\Adobe", "$env:ProgramData\Macromedia",
        "$env:ProgramData\Package Cache\Adobe",
        "$env:SystemDrive\AdobeTemp",
        "$env:windir\Temp\Adobe"
    )
    foreach ($p in $systemPaths) { Remove-PathForce $p }

    # Any other top-level Program Files folder named "Adobe ..." (e.g. "Adobe Photoshop 2024")
    foreach ($root in @($pf, $pf86)) {
        Get-ChildItem -LiteralPath $root -Directory -Filter 'Adobe*' -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-PathForce $_.FullName }
    }

    # Per-user data for every profile on the machine
    $profiles = Get-ChildItem 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin 'Public','Default','Default User','All Users' }
    foreach ($u in $profiles) {
        $up = $u.FullName
        $userPaths = @(
            "$up\AppData\Roaming\Adobe", "$up\AppData\Local\Adobe", "$up\AppData\LocalLow\Adobe",
            "$up\AppData\Roaming\Macromedia", "$up\AppData\Local\Macromedia",
            "$up\AppData\Local\Temp\Adobe", "$up\AppData\Local\Temp\CreativeCloud",
            "$up\AppData\Local\Packages\Adobe*",
            "$up\Creative Cloud Files"
        )
        if (-not $KeepDocumentsAdobe) { $userPaths += "$up\Documents\Adobe" }
        foreach ($p in $userPaths) {
            # Expand wildcards
            Get-Item -Path $p -Force -ErrorAction SilentlyContinue | ForEach-Object { Remove-PathForce $_.FullName }
        }
        # Adobe temp leftovers
        Get-ChildItem "$up\AppData\Local\Temp" -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(Adobe|ACROTMP|Acro|CreativeCloud|CEP)' } |
            ForEach-Object { Remove-PathForce $_.FullName }
    }

    # Shortcuts (Start Menu / Desktop)
    $shortcutRoots = @(
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs",
        "$env:PUBLIC\Desktop"
    ) + ($profiles | ForEach-Object {
        "$($_.FullName)\AppData\Roaming\Microsoft\Windows\Start Menu\Programs"
        "$($_.FullName)\Desktop"
    })
    foreach ($r in $shortcutRoots) {
        Get-ChildItem -LiteralPath $r -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(Adobe|Acrobat|Photoshop|Illustrator|InDesign|Premiere|After Effects|Lightroom|Creative Cloud)' } |
            ForEach-Object { Remove-PathForce $_.FullName }
    }
}

# ----------------------------------------------------------------------------
# 4. Registry cleanup
# ----------------------------------------------------------------------------
function Remove-AdobeRegistry {
    Log '--- Cleaning Adobe registry keys ---'
    $keys = @(
        'HKLM:\SOFTWARE\Adobe',
        'HKLM:\SOFTWARE\WOW6432Node\Adobe',
        'HKLM:\SOFTWARE\Macromedia',
        'HKLM:\SOFTWARE\WOW6432Node\Macromedia',
        'HKLM:\SOFTWARE\Policies\Adobe',
        'HKLM:\SOFTWARE\WOW6432Node\Policies\Adobe',
        'HKCU:\SOFTWARE\Adobe',
        'HKCU:\SOFTWARE\Macromedia',
        'HKCU:\SOFTWARE\Policies\Adobe',
        'HKLM:\SOFTWARE\Classes\Adobe*',
        'HKLM:\SYSTEM\CurrentControlSet\Services\Adobe*',
        'HKLM:\SYSTEM\CurrentControlSet\Services\AGS*',
        'HKLM:\SYSTEM\CurrentControlSet\Services\AGM*'
    )
    # All loaded user hives
    Get-ChildItem Registry::HKEY_USERS -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'S-1-5-21-[\d-]+$' } | ForEach-Object {
            $keys += "Registry::$($_.Name)\SOFTWARE\Adobe"
            $keys += "Registry::$($_.Name)\SOFTWARE\Macromedia"
        }

    foreach ($k in $keys) {
        Get-Item -Path $k -ErrorAction SilentlyContinue | ForEach-Object {
            $item = $_
            Act "Delete registry key $($item.Name)" {
                Remove-Item -LiteralPath $item.PSPath -Recurse -Force -ErrorAction Stop
                Log "Deleted key $($item.Name)" 'OK'
            }
        }
    }

    # Orphaned Uninstall entries published by Adobe
    Get-AdobeInstalls | ForEach-Object {
        $entry = $_
        Act "Delete uninstall entry $($entry.Name)" {
            Remove-Item -LiteralPath $entry.Key -Recurse -Force -ErrorAction Stop
        }
    }

    # Startup (Run) entries
    $runKeys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
               'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
               'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    foreach ($rk in $runKeys) {
        $props = Get-ItemProperty -Path $rk -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        $props.PSObject.Properties | Where-Object {
            $_.Name -notmatch '^PS' -and ($_.Name -match 'Adobe|Acrobat|CCXProcess' -or "$($_.Value)" -match '\\Adobe\\')
        } | ForEach-Object {
            $name = $_.Name
            Act "Delete startup entry $name" {
                Remove-ItemProperty -Path $rk -Name $name -ErrorAction Stop
                Log "Deleted startup entry $name" 'OK'
            }
        }
    }
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
$script:NeedReboot = $false

Stop-AdobeProcesses
Stop-AdobeServices
Remove-AdobeScheduledTasks
Uninstall-AdobeProducts
Stop-AdobeProcesses        # uninstallers sometimes relaunch helpers
Stop-AdobeServices
Remove-AdobeScheduledTasks
Remove-AdobeFiles
Remove-AdobeRegistry

# Verification
Log '--- Verification ---'
$left = @(Get-AdobeInstalls)
if ($left.Count) { $left | ForEach-Object { Log "Still registered: $($_.Name)" 'WARN' } }
else             { Log 'No Adobe products remain registered.' 'OK' }

Log "Done. Log saved to $LogFile"
if ($script:NeedReboot) { Log 'Some files were locked - reboot and run the script again to finish.' 'WARN' }

if ($Reboot -and -not $DryRun) {
    Log 'Rebooting in 30 seconds...' 'WARN'
    & shutdown.exe /r /t 30 /c 'Adobe cleanup complete - restarting'
}
