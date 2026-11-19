<#
.SYNOPSIS
    Finds files in your Downloads folder that are probably safe to delete, and writes a report.
    It only looks. Nothing is moved or deleted.

    It finds:
      - Installers for apps that are already installed on this PC (same or older version)
      - Zip files you've already unzipped (the folder next to them holds every file in the zip)
      - Exact duplicates anywhere in the folder, including the subfolders SundaySort created

.EXAMPLE
    .\Find-Reclaimable.ps1                 # scan Downloads, print a summary, write an HTML + CSV report
    .\Find-Reclaimable.ps1 -PassThru       # also return the items as objects
    .\Remove-Reclaimable.ps1               # after reviewing: move them to the Recycle Bin
#>
[CmdletBinding()]
param(
    # Folder to scan. Defaults to your Downloads folder.
    [string]$Path,
    # Where the HTML and CSV reports go.
    [string]$ReportDir = (Join-Path $env:LOCALAPPDATA 'SundaySort\reports'),
    # Don't write report files.
    [switch]$NoReport,
    # Return every item found.
    [switch]$PassThru,
    # Return only a summary object (used by Sort-Downloads.ps1).
    [switch]$Summary,
    # Also look inside your own subfolders (unzipped apps, projects...). Off by default, because
    # two apps can legitimately contain identical files, and removing one could break an app.
    [switch]$IncludeAllFolders,
    # More top-level folders that SundaySort sorts into (from your rules). Folders named "From ..." are always included.
    [string[]]$ExtraFolders,
    # For testing: use this list (objects with Name and Version) instead of the installed-programs list in the registry.
    [object[]]$InstalledPrograms
)

$ErrorActionPreference = 'Stop'

function Get-DownloadsFolder {
    try {
        $p = (New-Object -ComObject Shell.Application).Namespace('shell:Downloads').Self.Path
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    } catch { }
    Join-Path $env:USERPROFILE 'Downloads'
}

function Format-Size([double]$bytes) {
    if ($bytes -ge 1GB) { return '{0:N1} GB' -f ($bytes / 1GB) }
    if ($bytes -ge 1MB) { return '{0:N0} MB' -f ($bytes / 1MB) }
    '{0:N0} KB' -f [math]::Max(1, $bytes / 1KB)
}

function Get-Plural([int]$n, [string]$one, [string]$many) { if ($n -eq 1) { "1 $one" } else { "$n $many" } }

if (-not $Path) { $Path = Get-DownloadsFolder }
if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Folder not found: $Path" }
$Path = (Resolve-Path -LiteralPath $Path).ProviderPath

# ---------------------------------------------------------------------------
# Name matching helpers
# ---------------------------------------------------------------------------
$noise = @('setup', 'installer', 'install', 'latest', 'x64', 'x86', 'amd64', 'arm64', 'win64', 'win32', 'win', 'windows',
           'user', 'users', 'bin', 'release', 'stable', 'full', 'offline', 'online', 'web', 'international', 'dch', 'whql',
           'bit', 'the', 'for', 'client', 'edition', 'version', 'exe', 'msi', 'tm', 'notebook', 'portable')
$vendors = @('microsoft', 'google', 'nvidia', 'amd', 'intel', 'adobe', 'apple', 'corporation', 'inc', 'ltd', 'llc')

# Installer file names that don't look like the app's installed name
$aliases = [ordered]@{
    '^vs ?code'          = 'visual studio code'
    '^jdk'               = 'java se development kit'
    '^ea ?app'           = 'ea app'
    '^epic ?installer'   = 'epic games launcher'
    '^lsb ?setup'        = 'lenovo service bridge'
    '^chrome ?setup'     = 'google chrome'
    '^discord ?setup'    = 'discord'
    '^spotify ?setup'    = 'spotify'
    '^zoom ?installer'   = 'zoom'
    '^obs[- ]studio'     = 'obs studio'
}

# "VSCodeUserSetup-x64-1.108.0" -> "vs code"; "Python 3.14.2 (64-bit)" -> "python"
function Get-Core([string]$text) {
    if (-not $text) { return '' }
    $t = $text -creplace '(?<=[a-z])(?=[A-Z])', ' ' -creplace '(?<=[A-Z])(?=[A-Z][a-z])', ' '
    $t = $t.ToLower() -replace '\(.*?\)', ' '
    $tokens = $t -split '[^a-z0-9]+' | Where-Object { $_ -and $noise -notcontains $_ -and $_ -notmatch '^v?\d' }
    (@($tokens) -join ' ').Trim()
}

function Get-VersionText([string]$text) {
    if ($text -match '(?<![\d.])(\d+(?:\.\d+){1,3})') { return $matches[1] }
    $null
}

function ConvertTo-Ver([string]$v) {
    if (-not $v) { return $null }
    $parts = @($v -split '\.' | Select-Object -First 4)
    if ($parts.Count -lt 2) { return $null }
    try { [version]($parts -join '.') } catch { $null }
}

# Compare only as many parts as both versions have, so "3.14.3" vs "3.14.2" works.
function Compare-Ver([version]$a, [version]$b) {
    $n = [math]::Min(@($a.ToString() -split '\.').Count, @($b.ToString() -split '\.').Count)
    $pa = @($a.ToString() -split '\.')[0..($n - 1)] | ForEach-Object { [int]$_ }
    $pb = @($b.ToString() -split '\.')[0..($n - 1)] | ForEach-Object { [int]$_ }
    for ($i = 0; $i -lt $n; $i++) { if ($pa[$i] -ne $pb[$i]) { return [math]::Sign($pa[$i] - $pb[$i]) } }
    0
}

function Get-Installed {
    if ($InstalledPrograms) {
        return @($InstalledPrograms | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Version = $_.Version; Core = (Get-Core $_.Name) } })
    }
    $keys = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    @(Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName } |
        ForEach-Object { [pscustomobject]@{ Name = $_.DisplayName; Version = $_.DisplayVersion; Core = (Get-Core $_.DisplayName) } } |
        Where-Object { $_.Core })
}

function Get-MsiProductName([string]$file) {
    try {
        $wi = New-Object -ComObject WindowsInstaller.Installer
        $db = $wi.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $wi, @($file, 0))
        $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @("SELECT Value FROM Property WHERE Property='ProductName'"))
        $null = $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
        $rec = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
        if ($rec) { return $rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, 1) }
    } catch { }
    $null
}

function Find-InstalledMatch([string[]]$candidates, [object[]]$installed) {
    foreach ($c in ($candidates | Where-Object { $_ } | Select-Object -Unique)) {
        $significant = @($c -split ' ' | Where-Object { $_.Length -ge 3 -and $vendors -notcontains $_ })
        if ($significant.Count -eq 0) { continue }
        $hits = @($installed | Where-Object { (" $($_.Core) ").Contains(" $c ") -or ($_.Core.Length -ge 4 -and (" $c ").Contains(" $($_.Core) ")) })
        if ($hits.Count) {
            # Prefer the closest name: "NVIDIA Broadcast" over "NVIDIA Broadcast Voice Driver"
            $exact = @($hits | Where-Object { $_.Core -eq $c })
            if ($exact.Count) { return $exact[0] }
            return ($hits | Sort-Object { [math]::Abs($_.Core.Length - $c.Length) } | Select-Object -First 1)
        }
    }
    $null
}

function Get-AliasCore([string]$fileBase) {
    $flat = ($fileBase.ToLower() -replace '[_\-.]+', ' ').Trim()
    foreach ($k in $aliases.Keys) { if ($flat -match $k) { return $aliases[$k] } }
    $null
}

# ---------------------------------------------------------------------------
# Scan
# ---------------------------------------------------------------------------
# By default only loose files and the folders SundaySort creates are checked, never your own subfolders.
$sortFolders = @('Documents', 'Images', 'Design', 'Videos', 'Audio', 'Archives', 'Installers', 'Disk Images', 'Code',
                 'Fonts', 'Torrents', 'Other', '_Duplicates (check, then delete)')
function Test-InScope([string]$full) {
    if ($IncludeAllFolders) { return $true }
    $rel = $full.Substring($Path.Length).TrimStart('\')
    if ($rel -notmatch '\\') { return $true }
    $top = ($rel -split '\\')[0]
    ($sortFolders -contains $top) -or ($ExtraFolders -contains $top) -or ($top -like 'From *')
}
$all = @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue | Where-Object {
    -not ($_.Attributes -band [IO.FileAttributes]::Hidden) -and -not ($_.Attributes -band [IO.FileAttributes]::System) -and
    $_.Name -ne 'desktop.ini' -and $_.Length -gt 0 -and (Test-InScope $_.FullName)
})
$items   = New-Object System.Collections.Generic.List[object]
$flagged = @{}
function Add-Item($file, [string]$category, [string]$reason, [string]$kept = '') {
    $items.Add([pscustomobject]@{ Category = $category; Path = $file.FullName; Bytes = $file.Length; Reason = $reason; KeptCopy = $kept })
    $flagged[$file.FullName] = $true
}
function Get-Rel([string]$p) { $p.Substring($Path.Length).TrimStart('\') }

# 1) Exact duplicates (same size + same SHA-256). Keep the copy that is NOT in the duplicates folder,
#    then the shortest name, then the oldest.
$all | Group-Object Length | Where-Object Count -gt 1 | ForEach-Object { $_.Group } |
    Group-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } | Where-Object Count -gt 1 |
    ForEach-Object {
        $sorted = @($_.Group | Sort-Object { $_.FullName -like '*\_Duplicates*' }, { $_.Name.Length }, LastWriteTime)
        $keep = $sorted[0]
        $sorted | Select-Object -Skip 1 | ForEach-Object { Add-Item $_ 'Duplicate' ("Identical to " + (Get-Rel $keep.FullName)) $keep.FullName }
    }

# 2) Installers for apps that are already installed
$installerExt = '.exe', '.msi', '.msix', '.msixbundle'
$installers = @($all | Where-Object { $installerExt -contains $_.Extension.ToLower() -and -not $flagged.ContainsKey($_.FullName) })
if ($installers.Count) {
    $installed = Get-Installed
    foreach ($f in $installers) {
        $info = $null
        if ($f.Extension -ieq '.exe') { try { $info = $f.VersionInfo } catch { } }
        $product = if ($f.Extension -ieq '.msi') { Get-MsiProductName $f.FullName } elseif ($info) { $info.ProductName } else { $null }
        $candidates = @((Get-AliasCore $f.BaseName), (Get-Core $f.BaseName), (Get-Core $product))
        if ($info) { $candidates += Get-Core $info.FileDescription }
        $match = Find-InstalledMatch $candidates $installed
        if (-not $match) { continue }

        $iv = Get-VersionText $f.BaseName
        if (-not $iv -and $info) { $iv = Get-VersionText $info.ProductVersion }
        $installedV = Get-VersionText $match.Name
        if (-not $installedV) { $installedV = Get-VersionText $match.Version }

        $a = ConvertTo-Ver $iv; $b = ConvertTo-Ver $installedV
        if ($a -and $b) {
            $cmp = Compare-Ver $a $b
            if ($cmp -gt 0) { continue }   # newer than what's installed: might be an update you still want
            $label = if ($match.Name -like "*$installedV*") { $match.Name } else { "$($match.Name) $installedV" }
            $reason = if ($cmp -eq 0) { "$label is installed (same version)" } else { "$label is installed (this installer is older: $iv)" }
        } else {
            $reason = "$($match.Name) is already installed"
        }
        Add-Item $f 'Installer' $reason
    }
}

# 3) Archives that were already extracted
try { Add-Type -AssemblyName System.IO.Compression.FileSystem } catch { }
$folders = @(Get-ChildItem -LiteralPath $Path -Directory -Recurse -Depth 1 -Force -ErrorAction SilentlyContinue)
foreach ($a in ($all | Where-Object { $_.Extension -in '.zip', '.rar', '.7z' -and -not $flagged.ContainsKey($_.FullName) })) {
    $base = $a.BaseName -replace ' \(\d+\)$', ''
    $dir = $folders | Where-Object { $_.Name -ieq $base -or $_.Name -ieq $a.BaseName } | Select-Object -First 1
    if (-not $dir) { continue }
    if ($a.Extension -ieq '.zip') {
        try {
            $zip = [IO.Compression.ZipFile]::OpenRead($a.FullName)
            try {
                $entries = @($zip.Entries | Where-Object { $_.Name } | ForEach-Object { $_.FullName -replace '/', '\' })
            } finally { $zip.Dispose() }
        } catch { continue }
        if ($entries.Count -eq 0) { continue }
        $found = @($entries | Where-Object {
            (Test-Path -LiteralPath (Join-Path $dir.FullName $_)) -or
            (($_ -match '^[^\\]+\\(.+)$') -and (Test-Path -LiteralPath (Join-Path $dir.FullName $matches[1])))
        }).Count
        if ($found -ne $entries.Count) { continue }
        Add-Item $a 'Extracted archive' ("All $($entries.Count) files are already in " + (Get-Rel $dir.FullName))
    } else {
        Add-Item $a 'Extracted archive' ("A folder with the same name exists: " + (Get-Rel $dir.FullName) + " (contents not checked)")
    }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
$total = [double]($items | Measure-Object Bytes -Sum).Sum
$count = @{ Installer = 0; 'Extracted archive' = 0; Duplicate = 0 }
$items | Group-Object Category | ForEach-Object { $count[$_.Name] = $_.Count }

$htmlFile = $null; $csvFile = $null
if (-not $NoReport -and $items.Count) {
    New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
    $stamp = '{0:yyyyMMdd-HHmmss}' -f (Get-Date)
    $csvFile  = Join-Path $ReportDir "report-$stamp.csv"
    $htmlFile = Join-Path $ReportDir "report-$stamp.html"
    $items | Export-Csv -LiteralPath $csvFile -NoTypeInformation -Encoding UTF8

    $enc = { param($s) [Net.WebUtility]::HtmlEncode([string]$s) }
    $sections = foreach ($cat in 'Installer', 'Extracted archive', 'Duplicate') {
        $rows = @($items | Where-Object Category -eq $cat | Sort-Object Bytes -Descending)
        if (-not $rows.Count) { continue }
        $title = @{ Installer = 'Installers for apps you already have'; 'Extracted archive' = "Archives you've already unzipped"; Duplicate = 'Duplicate files' }[$cat]
        $sum = Format-Size (($rows | Measure-Object Bytes -Sum).Sum)
        $tr = ($rows | ForEach-Object {
            $folderUri = ([Uri](Split-Path $_.Path -Parent)).AbsoluteUri
            "<tr><td><a href=""$folderUri"">$(& $enc (Split-Path $_.Path -Leaf))</a><div class=""sub"">$(& $enc (Get-Rel $_.Path))</div></td><td class=""num"">$(Format-Size $_.Bytes)</td><td>$(& $enc $_.Reason)</td></tr>"
        }) -join "`n"
        "<h2>$title <span class=""pill"">$($rows.Count) &middot; $sum</span></h2><table><tr><th>File</th><th>Size</th><th>Why it's probably safe to delete</th></tr>$tr</table>"
    }
    $removeCmd = "& `"$(Join-Path $PSScriptRoot 'Remove-Reclaimable.ps1')`""
    $html = @"
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>SundaySort cleanup report</title>
<style>
:root { --bg:#ffffff; --fg:#1f2328; --muted:#59636e; --line:#d1d9e0; --accent:#0969da; --pill:#ddf4ff; }
@media (prefers-color-scheme: dark) { :root { --bg:#0d1117; --fg:#e6edf3; --muted:#9198a1; --line:#30363d; --accent:#4493f8; --pill:#121d2f; } }
body { margin:0; background:var(--bg); color:var(--fg); font:15px/1.5 "Segoe UI", system-ui, sans-serif; }
main { max-width:1000px; margin:0 auto; padding:32px 16px 64px; }
h1 { margin:0 0 4px; font-size:28px; } h2 { font-size:18px; margin:36px 0 10px; }
.lead { color:var(--muted); margin:0 0 20px; }
.big { font-size:40px; font-weight:700; color:var(--accent); }
.pill { font-size:13px; font-weight:600; background:var(--pill); color:var(--accent); padding:2px 10px; border-radius:99px; margin-left:6px; }
table { width:100%; border-collapse:collapse; } th, td { text-align:left; padding:8px 10px; border-bottom:1px solid var(--line); vertical-align:top; }
th { font-size:13px; color:var(--muted); font-weight:600; } td.num { white-space:nowrap; }
a { color:var(--accent); text-decoration:none; } a:hover { text-decoration:underline; }
.sub { font-size:12px; color:var(--muted); word-break:break-all; }
pre { background:var(--pill); padding:12px 14px; border-radius:8px; overflow-x:auto; font-size:13px; }
</style></head><body><main>
<h1>SundaySort cleanup report</h1>
<p class="lead">$(& $enc $Path) &middot; $(Get-Date -Format 'dddd d MMMM yyyy, HH:mm')</p>
<div class="big">$(Format-Size $total)</div>
<p class="lead">could be freed: $(Get-Plural $count.Installer 'installer' 'installers'), $(Get-Plural $count.'Extracted archive' 'unzipped archive' 'unzipped archives'), $(Get-Plural $count.Duplicate 'duplicate' 'duplicates'). Nothing has been deleted.</p>
<p>Click a file name to open its folder. When you're happy with the list, run this in PowerShell to move everything to the <b>Recycle Bin</b> (you can still restore from there):</p>
<pre>$(& $enc $removeCmd)</pre>
$($sections -join "`n")
</main></body></html>
"@
    [IO.File]::WriteAllText($htmlFile, $html, (New-Object Text.UTF8Encoding $false))
}

if ($Summary) {
    return [pscustomobject]@{
        Count = $items.Count; Bytes = $total
        Installers = $count.Installer; Archives = $count.'Extracted archive'; Duplicates = $count.Duplicate
        ReportHtml = $htmlFile; ReportCsv = $csvFile
    }
}

if ($items.Count -eq 0) {
    Write-Output "Nothing reclaimable found in $Path"
} else {
    Write-Output ("{0} could be freed: {1} for apps you have, {2}, {3}." -f (Format-Size $total),
        (Get-Plural $count.Installer 'installer' 'installers'), (Get-Plural $count.'Extracted archive' 'unzipped archive' 'unzipped archives'),
        (Get-Plural $count.Duplicate 'duplicate' 'duplicates'))
    if ($htmlFile) { Write-Output "Report: $htmlFile" }
    Write-Output 'Nothing was deleted. Review the report, then run .\Remove-Reclaimable.ps1 to move these to the Recycle Bin.'
}
if ($PassThru) { $items }
