<#
.SYNOPSIS
    Puts files back where they were before the last sort (or before a sort log you choose).
.EXAMPLE
    .\Undo-LastSort.ps1
    .\Undo-LastSort.ps1 -LogFile "$env:LOCALAPPDATA\SundaySort\logs\sort-20260101-210000.csv"
#>
[CmdletBinding()]
param(
    [string]$LogFile,
    [string]$LogDir = (Join-Path $env:LOCALAPPDATA 'SundaySort\logs')
)
$ErrorActionPreference = 'Stop'

if (-not $LogFile) {
    $latest = Get-ChildItem -LiteralPath $LogDir -Filter 'sort-*.csv' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '*.undone.csv' } | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $latest) { Write-Output "No sort logs found in $LogDir"; return }
    $LogFile = $latest.FullName
}

Write-Output "Undoing: $LogFile"
$restored = 0
foreach ($m in (Import-Csv -LiteralPath $LogFile)) {
    if ((Test-Path -LiteralPath $m.To) -and -not (Test-Path -LiteralPath $m.From)) {
        Move-Item -LiteralPath $m.To -Destination $m.From
        $restored++
    } else {
        Write-Warning "Skipped (moved or renamed since): $($m.To)"
    }
}
# Remove folders the sort created that are now empty
Import-Csv -LiteralPath $LogFile | ForEach-Object { Split-Path $_.To -Parent } | Select-Object -Unique | Sort-Object Length -Descending |
    ForEach-Object { if ((Test-Path -LiteralPath $_) -and -not (Get-ChildItem -LiteralPath $_ -Force)) { Remove-Item -LiteralPath $_ } }

Rename-Item -LiteralPath $LogFile -NewName ([IO.Path]::GetFileNameWithoutExtension($LogFile) + '.undone.csv')
Write-Output "Restored $restored files."
