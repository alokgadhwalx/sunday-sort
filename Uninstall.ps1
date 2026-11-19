<#
.SYNOPSIS
    Removes the weekly task and the installed scripts. Your files and folders are not touched.
    Undo logs are kept unless you pass -RemoveLogs.
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

foreach ($f in 'Sort-Downloads.ps1', 'Undo-LastSort.ps1', 'rules.json', 'Uninstall.ps1') {
    $p = Join-Path $InstallDir $f
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p }
}
$logs = Join-Path $InstallDir 'logs'
if ($RemoveLogs -and (Test-Path -LiteralPath $logs)) { Remove-Item -LiteralPath $logs -Recurse }
if ((Test-Path -LiteralPath $InstallDir) -and -not (Get-ChildItem -LiteralPath $InstallDir -Force)) { Remove-Item -LiteralPath $InstallDir }
Write-Output "SundaySort removed. Your sorted files stay where they are."
