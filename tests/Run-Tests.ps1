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

Write-Host ''
Write-Host "$script:passed passed, $script:failed failed"
if ($script:failed -gt 0) { exit 1 }
