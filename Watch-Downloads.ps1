<#
.SYNOPSIS
    Live mode: watches your Downloads folder and sorts new files shortly after they finish downloading.
    Install.ps1 -Live starts this automatically when you log in. You can also run it by hand.

    How it decides a download is finished:
      - files still downloading (.crdownload, .part, ...) are never touched
      - a file must have been left alone for -SettleSeconds (default 2 minutes), so you have time
        to open it from your browser before it moves
      - files that are open in another app are skipped and tried again later

    Sorting itself is done by Sort-Downloads.ps1, so every live sort is logged and can be undone.

.EXAMPLE
    .\Watch-Downloads.ps1                         # watch Downloads until you close the window
    .\Watch-Downloads.ps1 -BySource -SettleSeconds 60
#>
[CmdletBinding()]
param(
    [string]$Path,
    [string]$RulesFile,
    [switch]$BySource,
    # How long a new file must stay unchanged before it's sorted.
    [ValidateRange(5, 86400)]
    [int]$SettleSeconds = 120,
    # Show a notification after each sort (each one replaces the previous, so they don't pile up).
    [switch]$Notify,
    [string]$LogDir = (Join-Path $env:LOCALAPPDATA 'SundaySort\logs'),
    # For testing: stop after this many seconds (0 = run until closed).
    [int]$MaxRunSeconds = 0,
    # For testing: shortest allowed wait (the normal minimum is 5 seconds).
    [Parameter(DontShow)] [int]$TestSettleSeconds = 0
)
$ErrorActionPreference = 'Stop'

function Get-DownloadsFolder {
    try {
        $p = (New-Object -ComObject Shell.Application).Namespace('shell:Downloads').Self.Path
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    } catch { }
    Join-Path $env:USERPROFILE 'Downloads'
}

if (-not $Path) { $Path = Get-DownloadsFolder }
if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Folder not found: $Path" }
$Path = (Resolve-Path -LiteralPath $Path).ProviderPath
# (A separate variable: PowerShell re-checks the 5-second minimum on any assignment to $SettleSeconds.)
$settle = if ($TestSettleSeconds -gt 0) { $TestSettleSeconds } else { $SettleSeconds }

# Only one watcher per folder
$mutexName = 'Local\SundaySortWatch_' + ([BitConverter]::ToString([Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($Path.ToLower()))) -replace '-', '').Substring(0, 16)
$mutex = New-Object Threading.Mutex($false, $mutexName)
if (-not $mutex.WaitOne(0)) { Write-Output "Already watching $Path"; return }

$sorter = Join-Path $PSScriptRoot 'Sort-Downloads.ps1'
$sortArgs = @{ Path = $Path; MinAgeMinutes = ($settle / 60.0); LogDir = $LogDir }
if ($RulesFile) { $sortArgs.RulesFile = $RulesFile }
if ($BySource)  { $sortArgs.BySource = $true }
if ($Notify)    { $sortArgs.Notify = $true }

$inProgress = @('.crdownload', '.part', '.partial', '.download', '.opdownload', '.tmp', '.!ut', '.!qb')
function Test-WaitingFiles {
    # Is there a loose, finished file that has been left alone long enough?
    $cutoff = (Get-Date).AddSeconds(-$settle)
    [bool](Get-ChildItem -LiteralPath $Path -File -Force -ErrorAction SilentlyContinue | Where-Object {
        -not ($_.Attributes -band [IO.FileAttributes]::Hidden) -and -not ($_.Attributes -band [IO.FileAttributes]::System) -and
        $_.Name -ne 'desktop.ini' -and $inProgress -notcontains $_.Extension.ToLower() -and $_.LastWriteTime -lt $cutoff
    } | Select-Object -First 1)
}

$watcher = New-Object IO.FileSystemWatcher $Path
$watcher.IncludeSubdirectories = $false
$watcher.NotifyFilter = [IO.NotifyFilters]'FileName, LastWrite, Size'

$started    = Get-Date
$lastChange = Get-Date
$lastRun    = [datetime]::MinValue
$pending    = $true          # check once at start for anything that arrived while we weren't running
$pollMs     = [math]::Min(15000, [math]::Max(1000, $settle * 250))
Write-Output "Watching $Path (files are sorted $settle seconds after they stop changing). Press Ctrl+C to stop."

try {
    while ($true) {
        if ($MaxRunSeconds -gt 0 -and ((Get-Date) - $started).TotalSeconds -ge $MaxRunSeconds) { break }

        $change = $watcher.WaitForChanged([IO.WatcherChangeTypes]::All, $pollMs)
        if (-not $change.TimedOut) {
            # Our own moves also show up here; that's fine, the next check just finds nothing to do.
            $lastChange = Get-Date
            $pending = $true
            continue
        }

        $quietFor = ((Get-Date) - $lastChange).TotalSeconds
        # Sort when things have gone quiet after a change, and every 10 minutes retry anything that was in use.
        $retryDue = ((Get-Date) - $lastRun).TotalMinutes -ge 10
        if (($pending -and $quietFor -ge $settle) -or $retryDue) {
            $pending = $false
            $lastRun = Get-Date
            if (Test-WaitingFiles) {
                try { & $sorter @sortArgs | Out-Null } catch { Write-Warning "Sort failed: $($_.Exception.Message)" }
            }
        }
    }
} finally {
    $watcher.Dispose()
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
