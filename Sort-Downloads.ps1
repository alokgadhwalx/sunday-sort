<#
.SYNOPSIS
    Sorts the loose files in your Downloads folder into subfolders by type.
    Never deletes anything. Every move is logged so it can be undone.

.EXAMPLE
    .\Sort-Downloads.ps1 -DryRun          # preview only, moves nothing
    .\Sort-Downloads.ps1                  # sort your Downloads folder
    .\Sort-Downloads.ps1 -Path D:\Inbox   # sort another folder
    .\Sort-Downloads.ps1 -RulesFile .\my-rules.json
#>
[CmdletBinding()]
param(
    # Folder to sort. Defaults to your Downloads folder (even if you moved it).
    [string]$Path,
    # Show what would happen without moving anything.
    [switch]$DryRun,
    # Leave files alone that changed in the last N minutes (downloads still in progress).
    [int]$MinAgeMinutes = 10,
    # Optional JSON file that adds or overrides folder rules. See examples\rules.example.json.
    [string]$RulesFile,
    # Don't look for exact duplicate files.
    [switch]$NoDuplicateCheck,
    # Where the undo logs are written.
    [string]$LogDir = (Join-Path $env:LOCALAPPDATA 'SundaySort\logs'),
    # Show a Windows notification with a summary (used by the weekly task).
    [switch]$Notify
)

$ErrorActionPreference = 'Stop'

function Get-DownloadsFolder {
    try {
        $p = (New-Object -ComObject Shell.Application).Namespace('shell:Downloads').Self.Path
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    } catch { }
    Join-Path $env:USERPROFILE 'Downloads'
}

function Get-FreeName([string]$dir, [string]$name) {
    $target = Join-Path $dir $name
    if (-not (Test-Path -LiteralPath $target)) { return $target }
    $base = [IO.Path]::GetFileNameWithoutExtension($name)
    $ext  = [IO.Path]::GetExtension($name)
    $i = 2
    while (Test-Path -LiteralPath (Join-Path $dir "$base ($i)$ext")) { $i++ }
    Join-Path $dir "$base ($i)$ext"
}

function Format-Size([double]$bytes) {
    if ($bytes -ge 1GB) { return '{0:N1} GB' -f ($bytes / 1GB) }
    if ($bytes -ge 1MB) { return '{0:N0} MB' -f ($bytes / 1MB) }
    '{0:N0} KB' -f [math]::Max(1, $bytes / 1KB)
}

function Show-Toast([string]$title, [string]$body, [object[]]$buttons) {
    # Windows notification. Silently does nothing where toasts aren't available.
    try {
        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $esc = { param($s) [Security.SecurityElement]::Escape($s) }
        $actions = ($buttons | ForEach-Object {
            '<action content="{0}" activationType="protocol" arguments="{1}"/>' -f (& $esc $_.Label), (& $esc $_.Uri)
        }) -join ''
        $xml = '<toast><visual><binding template="ToastGeneric"><text>{0}</text><text>{1}</text></binding></visual><actions>{2}</actions></toast>' -f (& $esc $title), (& $esc $body), $actions
        $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
        $doc.LoadXml($xml)
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show((New-Object Windows.UI.Notifications.ToastNotification $doc))
    } catch {
        Write-Verbose "Notification not shown: $($_.Exception.Message)"
    }
}

function Test-SafeSubfolder([string]$name) {
    -not ([IO.Path]::IsPathRooted($name) -or $name -match '(^|[\\/])\.\.([\\/]|$)' -or $name.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0)
}

if (-not $Path) { $Path = Get-DownloadsFolder }
if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Folder not found: $Path" }
$Path = (Resolve-Path -LiteralPath $Path).ProviderPath

# ---------- Rules: subfolder -> file extensions ----------
$rules = [ordered]@{
    'Documents\PDFs'          = @('.pdf')
    'Documents\Word'          = @('.doc', '.docx', '.odt', '.rtf', '.pages')
    'Documents\Slides'        = @('.ppt', '.pptx', '.odp', '.key')
    'Documents\Spreadsheets'  = @('.xls', '.xlsx', '.xlsm', '.ods', '.csv', '.tsv', '.numbers')
    'Documents\Text & Notes'  = @('.txt', '.md', '.log')
    'Documents\eBooks'        = @('.epub', '.mobi', '.azw3')
    'Images'                  = @('.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.svg', '.heic', '.tif', '.tiff', '.ico', '.avif')
    'Design'                  = @('.psd', '.ai', '.fig', '.xd', '.sketch', '.afdesign', '.afphoto', '.blend')
    'Videos'                  = @('.mp4', '.mkv', '.mov', '.avi', '.webm', '.wmv', '.m4v')
    'Audio'                   = @('.mp3', '.wav', '.m4a', '.flac', '.ogg', '.aac', '.wma')
    'Archives'                = @('.zip', '.rar', '.7z', '.tar', '.gz', '.tgz', '.bz2', '.xz')
    'Installers'              = @('.exe', '.msi', '.msix', '.msixbundle', '.appx', '.apk', '.vsix', '.vsixpackage')
    'Disk Images'             = @('.iso', '.img', '.vhd', '.vhdx')
    'Code'                    = @('.html', '.htm', '.css', '.js', '.jsx', '.ts', '.tsx', '.py', '.ipynb', '.json', '.xml', '.yml', '.yaml', '.java', '.c', '.cpp', '.cs', '.go', '.rs', '.sh', '.ps1', '.sql')
    'Fonts'                   = @('.ttf', '.otf', '.woff', '.woff2')
    'Torrents'                = @('.torrent')
}

if ($RulesFile) {
    $custom = Get-Content -LiteralPath $RulesFile -Raw | ConvertFrom-Json
    if (-not $custom.folders) { throw "Rules file has no 'folders' section: $RulesFile" }
    foreach ($prop in $custom.folders.PSObject.Properties) {
        if (-not (Test-SafeSubfolder $prop.Name)) { throw "Unsafe folder name in rules file: '$($prop.Name)'" }
        $exts = @($prop.Value | ForEach-Object { $e = "$_".Trim().ToLower(); if (-not $e.StartsWith('.')) { $e = ".$e" }; $e })
        foreach ($k in @($rules.Keys)) { $rules[$k] = @($rules[$k] | Where-Object { $exts -notcontains $_ }) }
        $rules[$prop.Name] = $exts
    }
}

$otherFolder     = 'Other'
$duplicateFolder = '_Duplicates (check, then delete)'
$inProgress      = @('.crdownload', '.part', '.partial', '.download', '.opdownload', '.tmp', '.!ut', '.!qb')
$cutoff          = (Get-Date).AddMinutes(-$MinAgeMinutes)

# ---------- Collect loose files ----------
$files = @(Get-ChildItem -LiteralPath $Path -File -Force | Where-Object {
    -not ($_.Attributes -band [IO.FileAttributes]::Hidden) -and
    -not ($_.Attributes -band [IO.FileAttributes]::System) -and
    $_.Name -ne 'desktop.ini' -and
    $inProgress -notcontains $_.Extension.ToLower() -and
    $_.LastWriteTime -lt $cutoff
})

# ---------- Exact duplicates (same size + same SHA-256) ----------
$duplicates = @{}
if (-not $NoDuplicateCheck) {
    $files | Group-Object Length | Where-Object Count -gt 1 | ForEach-Object { $_.Group } |
        Group-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } | Where-Object Count -gt 1 |
        ForEach-Object {
            # keep the copy with the shortest (usually original) name
            $_.Group | Sort-Object { $_.Name.Length }, Name | Select-Object -Skip 1 |
                ForEach-Object { $duplicates[$_.FullName] = $true }
        }
}

# ---------- Move ----------
$moves = New-Object System.Collections.Generic.List[object]
foreach ($f in $files) {
    $ext = $f.Extension.ToLower()
    if ($duplicates.ContainsKey($f.FullName)) {
        $sub = $duplicateFolder
    } else {
        $sub = $otherFolder
        foreach ($k in $rules.Keys) { if ($rules[$k] -contains $ext) { $sub = $k; break } }
    }
    $destDir = Join-Path $Path $sub
    $target  = Get-FreeName $destDir $f.Name
    if (-not $DryRun) {
        if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir | Out-Null }
        try { Move-Item -LiteralPath $f.FullName -Destination $target }
        catch { Write-Warning "Skipped (in use?): $($f.Name)"; continue }
    }
    $moves.Add([pscustomobject]@{ From = $f.FullName; To = $target; Folder = $sub; Bytes = $f.Length })
}

# ---------- Report ----------
if ($moves.Count -eq 0) {
    Write-Output "Nothing to sort in $Path"
    return
}
$moves | Group-Object Folder | Sort-Object Name | Select-Object Count, @{ n = 'Folder'; e = { $_.Name } } |
    Format-Table -AutoSize | Out-String | Write-Output
if ($DryRun) {
    Write-Output "Preview: $($moves.Count) files would be moved. Nothing was changed."
} else {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $logFile = Join-Path $LogDir ('sort-{0:yyyyMMdd-HHmmss}.csv' -f (Get-Date))
    $moves | Export-Csv -LiteralPath $logFile -NoTypeInformation -Encoding UTF8
    Write-Output "Moved $($moves.Count) files. Undo with: .\Undo-LastSort.ps1"

    if ($Notify) {
        $total = ($moves | Measure-Object Bytes -Sum).Sum
        $top = $moves | Group-Object { Split-Path $_.Folder -Leaf } | Sort-Object Count -Descending | Select-Object -First 3 |
            ForEach-Object { '{0} {1}' -f $_.Name, $_.Count }
        $plural = if ($moves.Count -eq 1) { 'file' } else { 'files' }
        $buttons = @(@{ Label = 'Open folder'; Uri = ([Uri]$Path).AbsoluteUri })
        if (Test-Path 'HKCU:\Software\Classes\sundaysort') { $buttons += @{ Label = 'Undo'; Uri = 'sundaysort:undo' } }
        Show-Toast ('SundaySort tidied {0} {1} ({2})' -f $moves.Count, $plural, (Format-Size $total)) ($top -join '  ·  ') $buttons
    }
}
