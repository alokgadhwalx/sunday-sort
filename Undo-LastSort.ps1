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
    [string]$LogDir = (Join-Path $env:LOCALAPPDATA 'SundaySort\logs'),
    # Show a Windows notification when done (used by the notification's Undo button).
    [switch]$Notify
)
$ErrorActionPreference = 'Stop'

function Show-Toast([string]$title, [string]$body) {
    try {
        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $esc = { param($s) [Security.SecurityElement]::Escape($s) }
        $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
        $doc.LoadXml(('<toast><visual><binding template="ToastGeneric"><text>{0}</text><text>{1}</text></binding></visual></toast>' -f (& $esc $title), (& $esc $body)))
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show((New-Object Windows.UI.Notifications.ToastNotification $doc))
    } catch { Write-Verbose "Notification not shown: $($_.Exception.Message)" }
}

if (-not $LogFile) {
    $latest = Get-ChildItem -LiteralPath $LogDir -Filter 'sort-*.csv' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '*.undone.csv' } | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $latest) {
        Write-Output "No sort logs found in $LogDir"
        if ($Notify) { Show-Toast 'SundaySort' 'Nothing to undo.' }
        return
    }
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
# Remove folders the sort created that are now empty (including empty parents like Documents\),
# never going above the folder that was sorted.
foreach ($m in (Import-Csv -LiteralPath $LogFile)) {
    $stop = Split-Path $m.From -Parent
    $dir  = Split-Path $m.To -Parent
    while ($dir -and $dir.Length -gt $stop.Length -and $dir.StartsWith($stop, [StringComparison]::OrdinalIgnoreCase)) {
        if ((Test-Path -LiteralPath $dir) -and -not (Get-ChildItem -LiteralPath $dir -Force)) { Remove-Item -LiteralPath $dir } else { break }
        $dir = Split-Path $dir -Parent
    }
}

Rename-Item -LiteralPath $LogFile -NewName ([IO.Path]::GetFileNameWithoutExtension($LogFile) + '.undone.csv')
Write-Output "Restored $restored files."
if ($Notify) { Show-Toast 'SundaySort undo complete' "Put $restored files back where they were." }
