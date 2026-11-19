<#
.SYNOPSIS
    Tests for SundaySort. No dependencies: works in Windows PowerShell 5.1 and PowerShell 7.
    Every test runs in its own temporary folder; nothing outside it is touched.
.EXAMPLE
    .\tests\Run-Tests.ps1
#>
$ErrorActionPreference = 'Stop'
$repo   = Split-Path -Parent $PSScriptRoot
$sorter = Join-Path $repo 'Sort-Downloads.ps1'
$undo   = Join-Path $repo 'Undo-LastSort.ps1'
$finder = Join-Path $repo 'Find-Reclaimable.ps1'
$remover = Join-Path $repo 'Remove-Reclaimable.ps1'
$noApps = @([pscustomobject]@{ Name = 'Nothing Installed Here'; Version = '1.0' })

function Find-Items([string]$root, [object[]]$apps = $noApps) {
    @(& $finder -Path $root -NoReport -PassThru -InstalledPrograms $apps | Where-Object { $_.PSObject.Properties['Category'] })
}
$script:failed = 0
$script:passed = 0

function New-TestFolder {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('sundaysort-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $root, "$root\_logs" | Out-Null
    $root
}

# Creates a file that looks like an old download (so the "still downloading" guard doesn't skip it).
function New-OldFile([string]$path, [string]$content = 'x') {
    $dir = Split-Path $path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    Set-Content -LiteralPath $path -Value $content
    (Get-Item -LiteralPath $path).LastWriteTime = (Get-Date).AddDays(-2)
}

# Marks a file as downloaded from a website, the same way browsers do (the "Mark of the Web").
function Set-Source([string]$path, [string]$referrer, [string]$hostUrl) {
    $lines = @('[ZoneTransfer]', 'ZoneId=3')
    if ($referrer) { $lines += "ReferrerUrl=$referrer" }
    if ($hostUrl)  { $lines += "HostUrl=$hostUrl" }
    Set-Content -LiteralPath $path -Stream Zone.Identifier -Value $lines
    (Get-Item -LiteralPath $path).LastWriteTime = (Get-Date).AddDays(-2)
}

function Invoke-Sort([string]$root, [hashtable]$extra = @{}) {
    $p = @{ Path = $root; LogDir = "$root\_logs" } + $extra
    & $sorter @p | Out-Null
}

function Assert([bool]$condition, [string]$message) {
    if (-not $condition) { throw $message }
}

function Test([string]$name, [scriptblock]$body) {
    $root = New-TestFolder
    try {
        & $body $root
        $script:passed++
        Write-Host "  [pass] $name" -ForegroundColor Green
    } catch {
        $script:failed++
        Write-Host "  [FAIL] $name" -ForegroundColor Red
        Write-Host "         $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "SundaySort tests (PowerShell $($PSVersionTable.PSVersion))"

Test 'sorts files into folders by type' {
    param($r)
    'a.pdf', 'b.docx', 'c.pptx', 'd.xlsx', 'e.png', 'f.mp4', 'g.mp3', 'h.zip', 'i.exe', 'j.py' | ForEach-Object { New-OldFile "$r\$_" $_ }
    Invoke-Sort $r
    $expected = @{
        'Documents\PDFs\a.pdf' = 1; 'Documents\Word\b.docx' = 1; 'Documents\Slides\c.pptx' = 1
        'Documents\Spreadsheets\d.xlsx' = 1; 'Images\e.png' = 1; 'Videos\f.mp4' = 1; 'Audio\g.mp3' = 1
        'Archives\h.zip' = 1; 'Installers\i.exe' = 1; 'Code\j.py' = 1
    }
    foreach ($rel in $expected.Keys) { Assert (Test-Path -LiteralPath "$r\$rel") "missing $rel" }
}

Test 'matches extensions case-insensitively' {
    param($r)
    New-OldFile "$r\PHOTO.JPG"
    Invoke-Sort $r
    Assert (Test-Path "$r\Images\PHOTO.JPG") 'upper-case .JPG was not sorted into Images'
}

Test 'unknown types go to Other' {
    param($r)
    New-OldFile "$r\mystery.xyz"
    Invoke-Sort $r
    Assert (Test-Path "$r\Other\mystery.xyz") 'unknown type not in Other'
}

Test 'dry run moves nothing and writes no log' {
    param($r)
    New-OldFile "$r\a.pdf"; New-OldFile "$r\b.png"
    Invoke-Sort $r @{ DryRun = $true }
    Assert ((Get-ChildItem $r -File).Count -eq 2) 'files were moved during a dry run'
    Assert (-not (Get-ChildItem "$r\_logs")) 'a log was written during a dry run'
}

Test 'exact duplicates go to the review folder, the original stays' {
    param($r)
    New-OldFile "$r\invoice.pdf" 'same'
    New-OldFile "$r\invoice (1).pdf" 'same'
    New-OldFile "$r\other.pdf" 'different'
    Invoke-Sort $r
    Assert (Test-Path "$r\Documents\PDFs\invoice.pdf") 'original not kept'
    Assert (Test-Path "$r\_Duplicates (check, then delete)\invoice (1).pdf") 'duplicate not set aside'
    Assert (Test-Path "$r\Documents\PDFs\other.pdf") 'non-duplicate with same extension misplaced'
}

Test 'same size but different contents is not a duplicate' {
    param($r)
    New-OldFile "$r\a.pdf" 'abc'
    New-OldFile "$r\b.pdf" 'xyz'
    Invoke-Sort $r
    Assert (-not (Test-Path "$r\_Duplicates (check, then delete)")) 'different files flagged as duplicates'
}

Test 'skips in-progress downloads, new files and hidden files' {
    param($r)
    New-OldFile "$r\movie.mp4.crdownload"
    New-OldFile "$r\big.zip.part"
    New-OldFile "$r\secret.txt"; (Get-Item "$r\secret.txt").Attributes = 'Hidden'
    Set-Content "$r\just-now.pdf" 'fresh'
    Invoke-Sort $r
    foreach ($f in 'movie.mp4.crdownload', 'big.zip.part', 'secret.txt', 'just-now.pdf') {
        Assert (Test-Path -LiteralPath "$r\$f") "$f should have been left alone"
    }
}

Test 'never overwrites a file that already exists' {
    param($r)
    New-OldFile "$r\Documents\PDFs\notes.pdf" 'old'
    New-OldFile "$r\notes.pdf" 'new'
    Invoke-Sort $r
    Assert ((Get-Content "$r\Documents\PDFs\notes.pdf") -eq 'old') 'existing file was overwritten'
    Assert ((Get-Content "$r\Documents\PDFs\notes (2).pdf") -eq 'new') 'new file not renamed to (2)'
}

Test 'leaves existing subfolders and their contents alone' {
    param($r)
    New-OldFile "$r\My Project\report.pdf"
    Invoke-Sort $r
    Assert (Test-Path "$r\My Project\report.pdf") 'file inside a subfolder was moved'
}

Test 'undo puts every file back and removes folders it created' {
    param($r)
    New-OldFile "$r\a.pdf" '1'; New-OldFile "$r\b.png" '2'; New-OldFile "$r\c.zip" '3'
    New-OldFile "$r\Images\keep.png" 'already here'
    Invoke-Sort $r
    & $undo -LogDir "$r\_logs" | Out-Null
    foreach ($f in 'a.pdf', 'b.png', 'c.zip') { Assert (Test-Path "$r\$f") "$f not restored" }
    Assert (-not (Test-Path "$r\Documents")) 'empty folder created by the sort was not removed'
    Assert (Test-Path "$r\Images\keep.png") 'pre-existing folder content was disturbed'
    Assert ([bool](Get-ChildItem "$r\_logs" -Filter '*.undone.csv')) 'log was not marked as undone'
}

Test 'custom rules override the built-in ones' {
    param($r)
    $rules = "$r\_logs\rules.json"
    '{ "folders": { "Books": [".epub", "pdf"] } }' | Set-Content $rules
    New-OldFile "$r\novel.pdf" 'novel'; New-OldFile "$r\story.epub" 'story'
    Invoke-Sort $r @{ RulesFile = $rules }
    Assert (Test-Path "$r\Books\novel.pdf") 'custom rule (extension without a dot) not applied'
    Assert (Test-Path "$r\Books\story.epub") 'custom rule not applied'
}

Test 'rejects rules that point outside the folder' {
    param($r)
    $rules = "$r\_logs\bad.json"
    '{ "folders": { "..\\escape": [".pdf"] } }' | Set-Content $rules
    New-OldFile "$r\a.pdf"
    $threw = $false
    try { Invoke-Sort $r @{ RulesFile = $rules } } catch { $threw = $true }
    Assert $threw 'unsafe rules file was accepted'
    Assert (Test-Path "$r\a.pdf") 'files moved despite an invalid rules file'
}

Test 'handles names with brackets and spaces' {
    param($r)
    New-OldFile "$r\[draft] my file (v2).pdf"
    Invoke-Sort $r
    Assert (Test-Path -LiteralPath "$r\Documents\PDFs\[draft] my file (v2).pdf") 'special-character name not sorted'
}

Test 'running twice in a row changes nothing the second time' {
    param($r)
    New-OldFile "$r\a.pdf"
    Invoke-Sort $r
    $out = & $sorter -Path $r -LogDir "$r\_logs"
    Assert ("$out" -match 'Nothing to sort') 'second run did not report nothing to sort'
}

Test 'source: -BySource sorts files from well-known sites, including blob: links' {
    param($r)
    New-OldFile "$r\photo.jpg" 'wa';        Set-Source "$r\photo.jpg" '' 'blob:https://web.whatsapp.com/1f2e3d'
    New-OldFile "$r\statement.pdf" 'gm';    Set-Source "$r\statement.pdf" 'https://mail.google.com/mail/u/0/' 'https://mail-attachment.googleusercontent.com/x'
    New-OldFile "$r\notes.docx" 'dr';       Set-Source "$r\notes.docx" '' 'https://drive.usercontent.google.com/download?id=1'
    New-OldFile "$r\random.pdf" 'web';      Set-Source "$r\random.pdf" 'https://example.org/page' 'https://example.org/random.pdf'
    New-OldFile "$r\local.pdf" 'no source'
    Invoke-Sort $r @{ BySource = $true }
    Assert (Test-Path "$r\From WhatsApp\photo.jpg") 'WhatsApp blob: download not in From WhatsApp'
    Assert (Test-Path "$r\From Gmail\statement.pdf") 'Gmail attachment not in From Gmail'
    Assert (Test-Path "$r\From Google Drive\notes.docx") 'Drive download not in From Google Drive'
    Assert (Test-Path "$r\Documents\PDFs\random.pdf") 'unknown site should fall back to type'
    Assert (Test-Path "$r\Documents\PDFs\local.pdf") 'file without a source should fall back to type'
}

Test 'source: without -BySource or source rules, the download source is ignored' {
    param($r)
    New-OldFile "$r\photo.jpg" 'wa'; Set-Source "$r\photo.jpg" '' 'https://web.whatsapp.com/x'
    Invoke-Sort $r
    Assert (Test-Path "$r\Images\photo.jpg") 'source used without being asked'
}

Test 'source: your own site rules, with subdomains and wildcards' {
    param($r)
    $rules = "$r\_logs\rules.json"
    '{ "sources": { "Finance": ["examplebank.com"], "College": ["*.university.edu"] } }' | Set-Content $rules
    New-OldFile "$r\statement.pdf" 'bank'; Set-Source "$r\statement.pdf" 'https://netbanking.examplebank.com/stmts' ''
    New-OldFile "$r\notes.pdf" 'uni';      Set-Source "$r\notes.pdf" 'https://lms.cs.university.edu/course' ''
    New-OldFile "$r\fake.pdf" 'phish';     Set-Source "$r\fake.pdf" 'https://examplebank.com.evil.net/x' ''
    Invoke-Sort $r @{ RulesFile = $rules }
    Assert (Test-Path "$r\Finance\statement.pdf") 'subdomain of examplebank.com not matched'
    Assert (Test-Path "$r\College\notes.pdf") 'wildcard site rule not matched'
    Assert (Test-Path "$r\Documents\PDFs\fake.pdf") 'look-alike domain wrongly matched'
}

Test 'names: file-name rules come first, and are logged with a reason' {
    param($r)
    $rules = "$r\_logs\rules.json"
    '{ "names": { "Finance": ["*invoice*", "*receipt*"], "Images\\Screenshots": ["Screenshot*"] } }' | Set-Content $rules
    New-OldFile "$r\Invoice-2026-11.pdf" 'inv'
    New-OldFile "$r\Screenshot 2026-11-20 101500.png" 'shot'
    New-OldFile "$r\holiday.png" 'pic'
    Invoke-Sort $r @{ RulesFile = $rules }
    Assert (Test-Path "$r\Finance\Invoice-2026-11.pdf") 'name rule (case-insensitive) not applied'
    Assert (Test-Path "$r\Images\Screenshots\Screenshot 2026-11-20 101500.png") 'nested name-rule folder not used'
    Assert (Test-Path "$r\Images\holiday.png") 'other images should still sort by type'
    $log = Import-Csv (Get-ChildItem "$r\_logs" -Filter 'sort-*.csv' | Select-Object -First 1).FullName
    Assert (($log | Where-Object { $_.To -like '*Invoice*' }).Reason -eq 'name matches *invoice*') 'reason not logged'
}

Test 'running total adds up across runs' {
    param($r)
    New-OldFile "$r\a.pdf" 'a'; Invoke-Sort $r
    New-OldFile "$r\b.pdf" 'b'; New-OldFile "$r\c.png" 'c'; Invoke-Sort $r
    $stats = Get-Content "$r\_logs\stats.json" -Raw | ConvertFrom-Json
    Assert ($stats.Files -eq 3) "expected 3 files in the running total, got $($stats.Files)"
}

Test 'cleanup: also checks "From ..." folders' {
    param($r)
    New-OldFile "$r\From WhatsApp\photo.jpg" 'same photo'
    New-OldFile "$r\Images\photo.jpg" 'same photo'
    $items = @(Find-Items $r)
    Assert ($items.Count -eq 1) "expected 1 duplicate, got $($items.Count)"
}

Test 'cleanup: finds duplicates across subfolders and keeps the sorted copy' {
    param($r)
    New-OldFile "$r\Documents\PDFs\report.pdf" 'same content'
    New-OldFile "$r\_Duplicates (check, then delete)\report (1).pdf" 'same content'
    New-OldFile "$r\Images\unique.png" 'different'
    $items = @(Find-Items $r)
    Assert ($items.Count -eq 1) "expected 1 item, got $($items.Count)"
    Assert ($items[0].Category -eq 'Duplicate') 'not reported as a duplicate'
    Assert ($items[0].Path -like '*_Duplicates*report (1).pdf') 'flagged the wrong copy'
    Assert ($items[0].KeptCopy -like '*Documents\PDFs\report.pdf') 'kept the wrong copy'
}

Test 'cleanup: never looks inside your own folders unless asked' {
    param($r)
    New-OldFile "$r\ToolA\license.txt" 'same license'
    New-OldFile "$r\ToolB\license.txt" 'same license'
    Assert (@(Find-Items $r).Count -eq 0) 'flagged files inside user folders'
    $all = @(& $finder -Path $r -NoReport -PassThru -IncludeAllFolders -InstalledPrograms $noApps | Where-Object { $_.PSObject.Properties['Category'] })
    Assert ($all.Count -eq 1) '-IncludeAllFolders did not find the duplicate'
}

Test 'cleanup: flags a zip only when every file in it is already unzipped' {
    param($r)
    New-OldFile "$r\project\a.txt" 'a'; New-OldFile "$r\project\sub\b.txt" 'b'
    New-Item -ItemType Directory "$r\Archives" | Out-Null
    Compress-Archive -Path "$r\project\*" -DestinationPath "$r\Archives\project.zip"
    New-OldFile "$r\_src\c.txt" 'c'; New-OldFile "$r\_src\d.txt" 'd'
    Compress-Archive -Path "$r\_src\*" -DestinationPath "$r\Archives\partial.zip"
    New-OldFile "$r\partial\c.txt" 'c'   # d.txt missing -> not fully unzipped
    $items = @(Find-Items $r | Where-Object Category -eq 'Extracted archive')
    Assert ($items.Count -eq 1) "expected 1 archive, got $($items.Count)"
    Assert ($items[0].Path -like '*project.zip') 'fully unzipped archive not flagged'
}

Test 'cleanup: flags installers for installed apps, but not newer versions or unknown apps' {
    param($r)
    New-OldFile "$r\Installers\ExampleApp-Setup-1.5.0.exe" 'v1.5'
    New-OldFile "$r\Installers\ExampleApp-Setup-2.0.0.exe" 'v2.0'
    New-OldFile "$r\Installers\ExampleApp-Setup-3.0.0.exe" 'v3.0'
    New-OldFile "$r\Installers\OtherThing-setup.exe" 'other'
    $apps = @([pscustomobject]@{ Name = 'Example App'; Version = '2.0.0' })
    $names = @(Find-Items $r $apps | Where-Object Category -eq 'Installer' | ForEach-Object { Split-Path $_.Path -Leaf } | Sort-Object)
    Assert (($names -join ',') -eq 'ExampleApp-Setup-1.5.0.exe,ExampleApp-Setup-2.0.0.exe') "flagged: $($names -join ', ')"
}

Test 'cleanup: Remove-Reclaimable re-checks files and skips anything that changed' {
    param($r)
    New-OldFile "$r\Documents\PDFs\a.pdf" 'pair A'; New-OldFile "$r\Documents\PDFs\a-copy.pdf" 'pair A'
    New-OldFile "$r\Images\b.png" 'pair B';         New-OldFile "$r\Images\b-copy.png" 'pair B'
    $reports = "$r\_logs\reports"
    & $finder -Path $r -ReportDir $reports -InstalledPrograms $noApps | Out-Null
    Assert ([bool](Get-ChildItem $reports -Filter '*.html')) 'no HTML report written'
    Remove-Item "$r\Documents\PDFs\a.pdf"     # the copy being kept for pair A disappears
    $planned = @(& $remover -ReportDir $reports -ListOnly -WarningAction SilentlyContinue | Where-Object { $_.PSObject.Properties['Path'] })
    Assert ($planned.Count -eq 1) "expected 1 file planned, got $($planned.Count)"
    Assert ($planned[0].Path -like '*Images\b-copy.png') 'planned the wrong file'
    Assert (Test-Path "$r\Documents\PDFs\a-copy.pdf") 'ListOnly changed something'
}

Test 'weekly run with -CleanupReport sorts first, then writes a report' {
    param($r)
    New-OldFile "$r\Documents\PDFs\a.pdf" 'same'
    New-OldFile "$r\a.pdf" 'same'
    Invoke-Sort $r @{ CleanupReport = $true; ReportDir = "$r\_logs\reports" }
    Assert ([bool](Get-ChildItem "$r\_logs\reports" -Filter '*.html')) 'no report written'
}

Write-Host ''
Write-Host "$script:passed passed, $script:failed failed"
if ($script:failed -gt 0) { exit 1 }
