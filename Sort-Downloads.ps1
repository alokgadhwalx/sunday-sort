<#
.SYNOPSIS
    Sorts the loose files in your Downloads folder into subfolders by type.
    Never deletes anything. Every move is logged so it can be undone.

.EXAMPLE
    .\Sort-Downloads.ps1 -DryRun          # preview only, moves nothing
    .\Sort-Downloads.ps1                  # sort your Downloads folder
    .\Sort-Downloads.ps1 -Path D:\Inbox   # sort another folder
    .\Sort-Downloads.ps1 -RulesFile .\my-rules.json
    .\Sort-Downloads.ps1 -BySource        # files from WhatsApp, Gmail, Drive... get their own folders
#>
[CmdletBinding()]
param(
    # Folder to sort. Defaults to your Downloads folder (even if you moved it).
    [string]$Path,
    # Show what would happen without moving anything.
    [switch]$DryRun,
    # Leave files alone that changed in the last N minutes (downloads still in progress).
    [double]$MinAgeMinutes = 10,
    # Optional JSON file with your own rules: by extension, by file name, or by the website a file came from.
    # See examples\rules.example.json.
    [string]$RulesFile,
    # Put files from well-known sites (WhatsApp, Gmail, Google Drive, Discord, GitHub...) into "From <site>" folders.
    # Uses the download source Windows records for every downloaded file. Nothing leaves your PC.
    [switch]$BySource,
    # Don't look for exact duplicate files.
    [switch]$NoDuplicateCheck,
    # Where the undo logs are written.
    [string]$LogDir = (Join-Path $env:LOCALAPPDATA 'SundaySort\logs'),
    # Show a Windows notification with a summary (used by the weekly task).
    [switch]$Notify,
    # After sorting, look for space that could be freed and write a report (see Find-Reclaimable.ps1).
    [switch]$CleanupReport,
    [string]$ReportDir = (Join-Path $env:LOCALAPPDATA 'SundaySort\reports')
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

function Show-Toast([string]$title, [string]$body, [object[]]$buttons, [string]$body2 = '', [string]$footer = '') {
    # Windows notification. Silently does nothing where toasts aren't available.
    try {
        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $esc = { param($s) [Security.SecurityElement]::Escape($s) }
        $actions = ($buttons | ForEach-Object {
            '<action content="{0}" activationType="protocol" arguments="{1}"/>' -f (& $esc $_.Label), (& $esc $_.Uri)
        }) -join ''
        $lines = (@($title, $body, $body2) | Where-Object { $_ } | ForEach-Object { '<text>{0}</text>' -f (& $esc $_) }) -join ''
        if ($footer) { $lines += '<text placement="attribution">{0}</text>' -f (& $esc $footer) }
        $xml = '<toast><visual><binding template="ToastGeneric">{0}</binding></visual><actions>{1}</actions></toast>' -f $lines, $actions
        $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
        $doc.LoadXml($xml)
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        $toast = New-Object Windows.UI.Notifications.ToastNotification $doc
        # Same tag every time: a new SundaySort notification replaces the previous one instead of piling up.
        $toast.Tag = 'sort'; $toast.Group = 'SundaySort'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
    } catch {
        Write-Verbose "Notification not shown: $($_.Exception.Message)"
    }
}

function Test-SafeSubfolder([string]$name) {
    $name -and -not ([IO.Path]::IsPathRooted($name) -or $name -match '(^|[\\/])\.\.([\\/]|$)' -or $name.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0)
}

# Windows records where every downloaded file came from (the "Mark of the Web").
# Returns the website's host name, e.g. "mail.google.com", or $null if there's no record.
function Get-DownloadSource($file) {
    try { $zone = Get-Content -LiteralPath $file.FullName -Stream Zone.Identifier -ErrorAction Stop } catch { return $null }
    $values = @{}
    foreach ($line in $zone) { if ($line -match '^(ReferrerUrl|HostUrl)=(.+)$') { $values[$matches[1]] = $matches[2].Trim() } }
    # The page you were on (ReferrerUrl) says more than the download server (HostUrl), so try it first.
    foreach ($key in 'ReferrerUrl', 'HostUrl') {
        $u = $values[$key]
        if (-not $u) { continue }
        $u = $u -replace '^blob:', ''
        try { $h = ([Uri]$u).Host.ToLower() } catch { continue }
        if ($h -and $h -ne 'about') { return $h }
    }
    $null
}

# "web.whatsapp.com" matches "whatsapp.com"; patterns with * use wildcards.
function Find-SourceFolder([string]$sourceHost, $sourceRules) {
    foreach ($r in $sourceRules) {
        foreach ($p in $r.Patterns) {
            $p = $p.ToLower().Trim()
            if ($p.Contains('*')) { if ($sourceHost -like $p) { return $r.Folder } }
            elseif ($sourceHost -eq $p -or $sourceHost.EndsWith(".$p")) { return $r.Folder }
        }
    }
    $null
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

# Well-known sites for -BySource. Matching is on the end of the host name, so "web.whatsapp.com" matches "whatsapp.com".
$builtinSources = @(
    @{ Folder = 'From WhatsApp';     Patterns = @('whatsapp.com', 'whatsapp.net') }
    @{ Folder = 'From Gmail';        Patterns = @('mail.google.com', 'mail-attachment.googleusercontent.com') }
    @{ Folder = 'From Google Drive'; Patterns = @('drive.google.com', 'drive.usercontent.google.com', 'docs.google.com') }
    @{ Folder = 'From Outlook';      Patterns = @('outlook.live.com', 'outlook.office.com', 'outlook.office365.com', 'attachments.office.net') }
    @{ Folder = 'From Teams';        Patterns = @('teams.microsoft.com', 'teams.live.com') }
    @{ Folder = 'From OneDrive';     Patterns = @('onedrive.live.com', '1drv.ms', '*.sharepoint.com') }
    @{ Folder = 'From Discord';      Patterns = @('discord.com', 'discordapp.com', 'discordapp.net') }
    @{ Folder = 'From Telegram';     Patterns = @('telegram.org') }
    @{ Folder = 'From Slack';        Patterns = @('slack.com', 'slack-edge.com', 'slack-files.com') }
    @{ Folder = 'From GitHub';       Patterns = @('github.com', 'githubusercontent.com') }
    @{ Folder = 'From LinkedIn';     Patterns = @('linkedin.com', 'licdn.com') }
    @{ Folder = 'From Canva';        Patterns = @('canva.com') }
    @{ Folder = 'From Office Online'; Patterns = @('officeapps.live.com', 'office.com', 'microsoft365.com') }
    @{ Folder = 'From ChatGPT';      Patterns = @('chatgpt.com', 'oaiusercontent.com') }
    @{ Folder = 'From Claude';       Patterns = @('claude.ai') }
)

$nameRules   = New-Object System.Collections.Generic.List[object]
$sourceRules = New-Object System.Collections.Generic.List[object]

if ($RulesFile) {
    $custom = Get-Content -LiteralPath $RulesFile -Raw | ConvertFrom-Json
    if (-not ($custom.folders -or $custom.names -or $custom.sources)) {
        throw "Rules file needs at least one of 'folders', 'names' or 'sources': $RulesFile"
    }
    $sections = @($custom.folders, $custom.names, $custom.sources) | Where-Object { $_ }
    foreach ($section in $sections) {
        foreach ($prop in $section.PSObject.Properties) {
            if (-not (Test-SafeSubfolder $prop.Name)) { throw "Unsafe folder name in rules file: '$($prop.Name)'" }
        }
    }
    if ($custom.folders) {
        foreach ($prop in $custom.folders.PSObject.Properties) {
            $exts = @($prop.Value | ForEach-Object { $e = "$_".Trim().ToLower(); if (-not $e.StartsWith('.')) { $e = ".$e" }; $e })
            foreach ($k in @($rules.Keys)) { $rules[$k] = @($rules[$k] | Where-Object { $exts -notcontains $_ }) }
            $rules[$prop.Name] = $exts
        }
    }
    if ($custom.names) {
        foreach ($prop in $custom.names.PSObject.Properties) { $nameRules.Add(@{ Folder = $prop.Name; Patterns = @($prop.Value | ForEach-Object { "$_" }) }) }
    }
    if ($custom.sources) {
        foreach ($prop in $custom.sources.PSObject.Properties) { $sourceRules.Add(@{ Folder = $prop.Name; Patterns = @($prop.Value | ForEach-Object { "$_" }) }) }
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
    $sub = $null; $why = $null
    if ($duplicates.ContainsKey($f.FullName)) {
        $sub = $duplicateFolder; $why = 'exact duplicate'
    }
    # 1) Your file-name rules, e.g. "*invoice*" -> Finance
    if (-not $sub) {
        foreach ($r in $nameRules) {
            foreach ($p in $r.Patterns) { if ($f.Name -like $p) { $sub = $r.Folder; $why = "name matches $p"; break } }
            if ($sub) { break }
        }
    }
    # 2) Where it was downloaded from: your rules first, then the built-in sites with -BySource
    if (-not $sub -and ($sourceRules.Count -or $BySource)) {
        $src = Get-DownloadSource $f
        if ($src) {
            $sub = Find-SourceFolder $src $sourceRules
            if (-not $sub -and $BySource) { $sub = Find-SourceFolder $src $builtinSources }
            if ($sub) { $why = "downloaded from $src" }
        }
    }
    # 3) File type
    if (-not $sub) {
        $sub = $otherFolder; $why = "type $ext"
        foreach ($k in $rules.Keys) { if ($rules[$k] -contains $ext) { $sub = $k; break } }
    }
    $destDir = Join-Path $Path $sub
    $target  = Get-FreeName $destDir $f.Name
    if (-not $DryRun) {
        if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir | Out-Null }
        try { Move-Item -LiteralPath $f.FullName -Destination $target }
        catch { Write-Warning "Skipped (in use?): $($f.Name)"; continue }
    }
    $moves.Add([pscustomobject]@{ From = $f.FullName; To = $target; Folder = $sub; Bytes = $f.Length; Reason = $why })
}

# ---------- Report ----------
if ($moves.Count -eq 0) {
    Write-Output "Nothing to sort in $Path"
} else {
$moves | Group-Object Folder | Sort-Object Name | Select-Object Count, @{ n = 'Folder'; e = { $_.Name } } |
    Format-Table -AutoSize | Out-String | Write-Output
if ($DryRun) {
    Write-Output "Preview: $($moves.Count) files would be moved. Nothing was changed."
} else {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $logFile = Join-Path $LogDir ('sort-{0:yyyyMMdd-HHmmss}.csv' -f (Get-Date))
    $moves | Export-Csv -LiteralPath $logFile -NoTypeInformation -Encoding UTF8
    Write-Output "Moved $($moves.Count) files. Undo with: .\Undo-LastSort.ps1"

    # Running total since the first sort, shown in the notification
    $statsFile = Join-Path $LogDir 'stats.json'
    $stats = $null
    if (Test-Path -LiteralPath $statsFile) { try { $stats = Get-Content -LiteralPath $statsFile -Raw | ConvertFrom-Json } catch { } }
    if (-not $stats) { $stats = [pscustomobject]@{ Files = 0; Bytes = 0; Since = (Get-Date -Format 'yyyy-MM-dd') } }
    $stats.Files = [long]$stats.Files + $moves.Count
    $stats.Bytes = [long]$stats.Bytes + [long](($moves | Measure-Object Bytes -Sum).Sum)
    $stats | ConvertTo-Json | Set-Content -LiteralPath $statsFile -Encoding UTF8
}
}

# ---------- Cleanup report ----------
$reclaim = $null
if ($CleanupReport -and -not $DryRun) {
    try {
        # Let the cleanup scan look inside the folders this sort uses (including your own rule folders)
        $myFolders = New-Object System.Collections.Generic.List[string]
        foreach ($r in $nameRules)      { $myFolders.Add(($r.Folder -split '\\')[0]) }
        foreach ($r in $sourceRules)    { $myFolders.Add(($r.Folder -split '\\')[0]) }
        foreach ($k in $rules.Keys)     { $myFolders.Add(($k -split '\\')[0]) }
        $myFolders = @($myFolders | Select-Object -Unique)
        $reclaim = & (Join-Path $PSScriptRoot 'Find-Reclaimable.ps1') -Path $Path -ReportDir $ReportDir -Summary -ExtraFolders $myFolders
        if ($reclaim.Count) {
            Write-Output ('{0} could be freed ({1} files). Report: {2}' -f (Format-Size $reclaim.Bytes), $reclaim.Count, $reclaim.ReportHtml)
        }
    } catch {
        Write-Warning "Cleanup report failed: $($_.Exception.Message)"
    }
}

# ---------- Notification ----------
$hasReclaim = $reclaim -and $reclaim.Count
if ($Notify -and -not $DryRun -and ($moves.Count -or $hasReclaim)) {
    $buttons = @()
    if ($moves.Count) {
        $total = ($moves | Measure-Object Bytes -Sum).Sum
        $plural = if ($moves.Count -eq 1) { 'file' } else { 'files' }
        $title = 'SundaySort tidied {0} {1} ({2})' -f $moves.Count, $plural, (Format-Size $total)
        $body = ($moves | Group-Object { Split-Path $_.Folder -Leaf } | Sort-Object Count -Descending | Select-Object -First 3 |
            ForEach-Object { '{0} {1}' -f $_.Name, $_.Count }) -join '  ·  '
    } else {
        $title = 'SundaySort weekly check'
        $body = 'Nothing new to sort.'
    }
    $body2 = ''
    if ($hasReclaim) {
        $parts = @()
        $pl = { param($n, $one, $many) if ($n -eq 1) { "1 $one" } else { "$n $many" } }
        if ($reclaim.Installers) { $parts += & $pl $reclaim.Installers 'old installer' 'old installers' }
        if ($reclaim.Archives)   { $parts += & $pl $reclaim.Archives 'unzipped archive' 'unzipped archives' }
        if ($reclaim.Duplicates) { $parts += & $pl $reclaim.Duplicates 'duplicate' 'duplicates' }
        $body2 = 'You could free {0}: {1}' -f (Format-Size $reclaim.Bytes), ($parts -join ', ')
        if ($reclaim.ReportHtml) { $buttons += @{ Label = 'Review'; Uri = ([Uri]$reclaim.ReportHtml).AbsoluteUri } }
    }
    $buttons += @{ Label = 'Open folder'; Uri = ([Uri]$Path).AbsoluteUri }
    if ($moves.Count -and (Test-Path 'HKCU:\Software\Classes\sundaysort')) { $buttons += @{ Label = 'Undo'; Uri = 'sundaysort:undo' } }
    $footer = ''
    if ($stats -and $stats.Files) {
        $since = try { ([datetime]$stats.Since).ToString('d MMM yyyy') } catch { $stats.Since }
        $footer = '{0:N0} files sorted since {1}' -f $stats.Files, $since
    }
    Show-Toast $title $body $buttons $body2 $footer
}
