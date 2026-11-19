<#
.SYNOPSIS
    Moves the files listed in the latest cleanup report to the Recycle Bin, after you've reviewed it.
    Nothing is permanently deleted: you can restore anything from the Recycle Bin.

    Before moving each file it checks again that:
      - the file still exists and hasn't changed size since the report
      - for duplicates, the copy being kept still exists

.EXAMPLE
    .\Remove-Reclaimable.ps1 -ListOnly                  # show what would be moved, change nothing
    .\Remove-Reclaimable.ps1                            # asks once, then moves everything to the Recycle Bin
    .\Remove-Reclaimable.ps1 -Category Installer        # only the installers
#>
[CmdletBinding()]
param(
    [string]$ReportFile,
    [string]$ReportDir = (Join-Path $env:LOCALAPPDATA 'SundaySort\reports'),
    [ValidateSet('Installer', 'Extracted archive', 'Duplicate')]
    [string[]]$Category,
    # Show what would be moved, change nothing.
    [switch]$ListOnly,
    # Don't ask for confirmation.
    [switch]$Force
)
$ErrorActionPreference = 'Stop'

function Format-Size([double]$bytes) {
    if ($bytes -ge 1GB) { return '{0:N1} GB' -f ($bytes / 1GB) }
    if ($bytes -ge 1MB) { return '{0:N0} MB' -f ($bytes / 1MB) }
    '{0:N0} KB' -f [math]::Max(1, $bytes / 1KB)
}

if (-not $ReportFile) {
    $latest = Get-ChildItem -LiteralPath $ReportDir -Filter 'report-*.csv' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $latest) { Write-Output "No cleanup report found in $ReportDir. Run .\Find-Reclaimable.ps1 first."; return }
    $ReportFile = $latest.FullName
}

$rows = @(Import-Csv -LiteralPath $ReportFile)
if ($Category) { $rows = @($rows | Where-Object { $Category -contains $_.Category }) }

# Re-check everything before touching it
$ready = New-Object System.Collections.Generic.List[object]
foreach ($r in $rows) {
    $f = Get-Item -LiteralPath $r.Path -ErrorAction SilentlyContinue
    if (-not $f) { Write-Verbose "Gone already: $($r.Path)"; continue }
    if ($f.Length -ne [long]$r.Bytes) { Write-Warning "Changed since the report, skipped: $($r.Path)"; continue }
    if ($r.Category -eq 'Duplicate' -and -not (Test-Path -LiteralPath $r.KeptCopy)) { Write-Warning "The copy being kept is missing, skipped: $($r.Path)"; continue }
    $ready.Add($r)
}

if ($ready.Count -eq 0) { Write-Output 'Nothing to move.'; return }
$total = ($ready | ForEach-Object { [long]$_.Bytes } | Measure-Object -Sum).Sum

if ($ListOnly) {
    $ready | Select-Object Category, @{ n = 'Size'; e = { Format-Size $_.Bytes } }, Path
    Write-Output "$($ready.Count) files ($(Format-Size $total)) would be moved to the Recycle Bin. Nothing was changed."
    return
}

if (-not $Force) {
    $answer = Read-Host "Move $($ready.Count) files ($(Format-Size $total)) to the Recycle Bin? [y/N]"
    if ($answer -notmatch '^(y|yes)$') { Write-Output 'Cancelled. Nothing was changed.'; return }
}

Add-Type -AssemblyName Microsoft.VisualBasic
$moved = 0
foreach ($r in $ready) {
    try {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($r.Path, 'OnlyErrorDialogs', 'SendToRecycleBin')
        $moved++
    } catch { Write-Warning "Could not move $($r.Path): $($_.Exception.Message)" }
}
Write-Output "Moved $moved files ($(Format-Size $total)) to the Recycle Bin. Restore them from there if you need anything back."
