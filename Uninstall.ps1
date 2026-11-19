<#
.SYNOPSIS
    Removes the scheduled tasks, the right-click menu entry and the installed scripts.
    Your files and folders are not touched.
    Undo logs and cleanup reports are kept unless you pass -RemoveLogs.
#>
[CmdletBinding()]
param(
    # The folder SundaySort is installed in. Defaults to the folder this script is in.
    [string]$InstallDir,
    # Where undo logs and cleanup reports are kept.
    [string]$DataDir = (Join-Path $env:LOCALAPPDATA 'SundaySort'),
    [string]$TaskName = 'SundaySort - weekly Downloads cleanup',
    [string]$LiveTaskName = 'SundaySort - live Downloads sorting',
    [switch]$RemoveLogs
)
$ErrorActionPreference = 'Stop'
# (Set here, not as the parameter default: $PSScriptRoot is empty in parameter defaults under "powershell -File".)
if (-not $InstallDir) { $InstallDir = $PSScriptRoot }

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Output "Removed scheduled task: $TaskName"
} else {
    Write-Output "No scheduled task named '$TaskName'."
}

if (Get-ScheduledTask -TaskName $LiveTaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $LiveTaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $LiveTaskName -Confirm:$false
    Write-Output "Stopped and removed live mode: $LiveTaskName"
}

$key = 'HKCU:\Software\Classes\sundaysort'
if (Test-Path $key) {
    $cmd = (Get-Item "$key\shell\open\command" -ErrorAction SilentlyContinue).GetValue('')
    if ($cmd -and $cmd -like "*$InstallDir*") { Remove-Item -Path $key -Recurse; Write-Output 'Removed the sundaysort: link used by the Undo button.' }
}

foreach ($base in 'HKCU:\Software\Classes\Directory\shell\SundaySort', 'HKCU:\Software\Classes\Directory\Background\shell\SundaySort') {
    if (Test-Path $base) {
        $cmd = (Get-Item "$base\command" -ErrorAction SilentlyContinue).GetValue('')
        if ($cmd -and $cmd -like "*$InstallDir*") { Remove-Item -Path $base -Recurse; $removedMenu = $true }
    }
}
if ($removedMenu) { Write-Output 'Removed "Tidy with SundaySort" from the right-click menu.' }

# The app: close it, remove it and its Start menu entry
$appExe = Join-Path $InstallDir 'SundaySort.exe'
Get-Process SundaySort -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $appExe } | Stop-Process -Force -ErrorAction SilentlyContinue
$lnk = Join-Path ([Environment]::GetFolderPath('Programs')) 'SundaySort.lnk'
if (Test-Path -LiteralPath $lnk) {
    $target = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk).TargetPath
    if ($target -eq $appExe) { Remove-Item -LiteralPath $lnk; Write-Output 'Removed SundaySort from the Start menu.' }
}
Start-Sleep -Milliseconds 500

foreach ($f in 'SundaySort.exe', 'Sort-Downloads.ps1', 'Undo-LastSort.ps1', 'Find-Reclaimable.ps1', 'Remove-Reclaimable.ps1', 'Watch-Downloads.ps1', 'rules.json', 'Uninstall.ps1') {
    $p = Join-Path $InstallDir $f
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p }
}
if ($RemoveLogs) {
    foreach ($base in @($DataDir, $InstallDir) | Select-Object -Unique) {
        foreach ($d in 'logs', 'reports') {
            $p = Join-Path $base $d
            if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse; Write-Output "Removed $p" }
        }
    }
    if ((Test-Path -LiteralPath $DataDir) -and -not (Get-ChildItem -LiteralPath $DataDir -Force)) { Remove-Item -LiteralPath $DataDir }
}
if ((Test-Path -LiteralPath $InstallDir) -and -not (Get-ChildItem -LiteralPath $InstallDir -Force)) { Remove-Item -LiteralPath $InstallDir }
Write-Output "SundaySort removed. Your sorted files stay where they are."
