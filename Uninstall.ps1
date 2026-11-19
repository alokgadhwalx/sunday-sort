<#
.SYNOPSIS
    Removes the weekly task and the installed scripts. Your files and folders are not touched.
    Undo logs and cleanup reports are kept unless you pass -RemoveLogs.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'SundaySort'),
    [string]$TaskName = 'SundaySort - weekly Downloads cleanup',
    [switch]$RemoveLogs
)
$ErrorActionPreference = 'Stop'

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Output "Removed scheduled task: $TaskName"
} else {
    Write-Output "No scheduled task named '$TaskName'."
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

foreach ($f in 'Sort-Downloads.ps1', 'Undo-LastSort.ps1', 'Find-Reclaimable.ps1', 'Remove-Reclaimable.ps1', 'rules.json', 'Uninstall.ps1') {
    $p = Join-Path $InstallDir $f
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p }
}
if ($RemoveLogs) {
    foreach ($d in 'logs', 'reports') {
        $p = Join-Path $InstallDir $d
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse }
    }
}
if ((Test-Path -LiteralPath $InstallDir) -and -not (Get-ChildItem -LiteralPath $InstallDir -Force)) { Remove-Item -LiteralPath $InstallDir }
Write-Output "SundaySort removed. Your sorted files stay where they are."
