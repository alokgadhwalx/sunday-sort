<#
.SYNOPSIS
    Installs SundaySort and schedules it to tidy your Downloads folder once a week.
.EXAMPLE
    .\Install.ps1                                   # every Sunday at 9 PM
    .\Install.ps1 -Day Friday -Time "6:30 PM"
    .\Install.ps1 -Path "D:\Downloads" -RulesFile .\my-rules.json
    .\Install.ps1 -BySource                         # also sort by site: From WhatsApp, From Gmail...
#>
[CmdletBinding()]
param(
    [ValidateSet('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')]
    [string]$Day = 'Sunday',
    [string]$Time = '9:00 PM',
    # Folder to sort. Leave empty to use your Downloads folder.
    [string]$Path,
    # Optional custom rules (copied into the install folder).
    [string]$RulesFile,
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'SundaySort'),
    [string]$TaskName = 'SundaySort - weekly Downloads cleanup',
    # Don't show a notification after each weekly run.
    [switch]$NoNotify,
    # Don't look for old installers, unzipped archives and duplicates each week.
    [switch]$NoCleanupReport,
    # Put files from well-known sites (WhatsApp, Gmail, Drive, Discord...) into "From <site>" folders.
    [switch]$BySource,
    # Don't add "Tidy with SundaySort" to the right-click menu of folders.
    [switch]$NoContextMenu,
    [switch]$SkipPreview
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$at = [datetime]::Parse($Time)

# 1) Copy the scripts
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
foreach ($f in 'Sort-Downloads.ps1', 'Undo-LastSort.ps1', 'Find-Reclaimable.ps1', 'Remove-Reclaimable.ps1', 'Uninstall.ps1') {
    Copy-Item -LiteralPath (Join-Path $here $f) -Destination $InstallDir -Force
}
Get-ChildItem -LiteralPath $InstallDir -Filter '*.ps1' | Unblock-File

# Options shared by the weekly task and the right-click menu
$ruleArgs = ''
if ($RulesFile) {
    $rulesTarget = Join-Path $InstallDir 'rules.json'
    Copy-Item -LiteralPath $RulesFile -Destination $rulesTarget -Force
    $ruleArgs += " -RulesFile `"$rulesTarget`""
}
if ($BySource) { $ruleArgs += ' -BySource' }
$sortArgs = $ruleArgs
if ($Path) { $sortArgs += " -Path `"$((Resolve-Path -LiteralPath $Path).ProviderPath)`"" }
$sorter = Join-Path $InstallDir 'Sort-Downloads.ps1'

# 2) Show what the first run will do
if (-not $SkipPreview) {
    Write-Output "Preview of the first run (nothing is moved yet):"
    $previewArgs = @{ DryRun = $true }
    if ($Path) { $previewArgs.Path = $Path }
    if ($RulesFile) { $previewArgs.RulesFile = $rulesTarget }
    if ($BySource) { $previewArgs.BySource = $true }
    & $sorter @previewArgs
}

if (-not $NoCleanupReport) { $sortArgs += ' -CleanupReport' }

# 3) Notifications: the "Undo" button opens sundaysort:undo, registered for this user only
if (-not $NoNotify) {
    $sortArgs += ' -Notify'
    $undo = Join-Path $InstallDir 'Undo-LastSort.ps1'
    $key = 'HKCU:\Software\Classes\sundaysort'
    New-Item -Path "$key\shell\open\command" -Force | Out-Null
    Set-Item -Path $key -Value 'URL:SundaySort'
    New-ItemProperty -Path $key -Name 'URL Protocol' -Value '' -Force | Out-Null
    Set-Item -Path "$key\shell\open\command" -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$undo`" -Notify"
}

# 4) Right-click menu: "Tidy with SundaySort" on a folder, and on the empty space inside a folder.
#    Windows 11 shows it under "Show more options". Registered for this user only.
if (-not $NoContextMenu) {
    $menuCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$sorter`" -Path `"%V`" -MinAgeMinutes 1 -Notify$ruleArgs"
    foreach ($base in 'HKCU:\Software\Classes\Directory\shell\SundaySort', 'HKCU:\Software\Classes\Directory\Background\shell\SundaySort') {
        New-Item -Path "$base\command" -Force | Out-Null
        Set-Item -Path $base -Value 'Tidy with SundaySort'
        Set-Item -Path "$base\command" -Value $menuCmd
    }
}

# 5) Schedule it
$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$sorter`"$sortArgs"
$trigger   = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $Day -At $at
$settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
$principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $TaskName -Description 'Sorts loose files in Downloads into folders by type. Never deletes anything.' `
    -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null

$next = (Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo).NextRunTime
Write-Output ""
Write-Output "Installed to $InstallDir"
Write-Output "Scheduled every $Day at $($at.ToString('h:mm tt')). Next run: $next"
Write-Output "Sort now:  & `"$sorter`""
Write-Output "Undo:      & `"$(Join-Path $InstallDir 'Undo-LastSort.ps1')`""
Write-Output "Cleanup:   & `"$(Join-Path $InstallDir 'Find-Reclaimable.ps1')`""
if (-not $NoContextMenu) { Write-Output 'Right-click any folder -> "Tidy with SundaySort" (Windows 11: under "Show more options")' }
Write-Output "Remove:    & `"$(Join-Path $InstallDir 'Uninstall.ps1')`""
