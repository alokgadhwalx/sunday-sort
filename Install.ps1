<#
.SYNOPSIS
    Installs SundaySort and schedules it to tidy your Downloads folder once a week.
.EXAMPLE
    .\Install.ps1                                   # every Sunday at 9 PM
    .\Install.ps1 -Day Friday -Time "6:30 PM"
    .\Install.ps1 -Path "D:\Downloads" -RulesFile .\my-rules.json
    .\Install.ps1 -BySource                         # also sort by site: From WhatsApp, From Gmail...
    .\Install.ps1 -Live                             # sort new downloads as they arrive, not just weekly
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
    # Where the scripts are installed. Leave empty to pick automatically: the installer checks that
    # Windows lets scheduled tasks run scripts there, and falls back to another folder if not.
    [string]$InstallDir,
    [string]$TaskName = 'SundaySort - weekly Downloads cleanup',
    # Don't show a notification after each weekly run.
    [switch]$NoNotify,
    # Don't look for old installers, unzipped archives and duplicates each week.
    [switch]$NoCleanupReport,
    # Put files from well-known sites (WhatsApp, Gmail, Drive, Discord...) into "From <site>" folders.
    [switch]$BySource,
    # Don't add "Tidy with SundaySort" to the right-click menu of folders.
    [switch]$NoContextMenu,
    # Live mode: sort new downloads shortly after they finish, instead of waiting for the weekly run.
    # The weekly run still happens and sends the cleanup report.
    [switch]$Live,
    # Live mode: how long a new file must stay unchanged before it's sorted (seconds).
    [int]$SettleSeconds = 120,
    [string]$LiveTaskName = 'SundaySort - live Downloads sorting',
    # Don't build the SundaySort app (window + tray icon); install only the background sorting.
    [switch]$NoApp,
    [switch]$SkipPreview
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$at = [datetime]::Parse($Time)
$principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited

# 0) Can scheduled tasks run scripts from this folder? On some PCs Windows blocks scripts started by
#    Task Scheduler from certain folders (seen directly inside %LOCALAPPDATA% and %APPDATA%), which
#    would make the weekly run and live mode silently fail. A tiny test task tells us for sure.
function Test-TaskCanRunScripts([string]$dir) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $marker = Join-Path $dir ".probe-$([guid]::NewGuid().ToString('N')).ok"
    $probe  = Join-Path $dir '.probe.ps1'
    Set-Content -LiteralPath $probe -Value "Set-Content -LiteralPath '$marker' -Value 'ok'"
    $name = 'SundaySort - install check'
    try {
        $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$probe`""
        Register-ScheduledTask -TaskName $name -Action $act -Principal $principal -Force | Out-Null
        Start-ScheduledTask -TaskName $name
        $deadline = (Get-Date).AddSeconds(20)
        while (-not (Test-Path -LiteralPath $marker) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
        Test-Path -LiteralPath $marker
    } finally {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $probe, $marker -ErrorAction SilentlyContinue
    }
}

$candidates = if ($InstallDir) { @($InstallDir) } else {
    @((Join-Path $env:LOCALAPPDATA 'Programs\SundaySort'), (Join-Path $env:USERPROFILE '.sundaysort'))
}
$chosen = $null
foreach ($c in $candidates) {
    Write-Output "Checking that Windows lets scheduled tasks run scripts from $c ..."
    if (Test-TaskCanRunScripts $c) { $chosen = $c; break }
    Write-Warning "Windows blocked scheduled scripts in $c."
    if ((Test-Path -LiteralPath $c) -and -not (Get-ChildItem -LiteralPath $c -Force)) { Remove-Item -LiteralPath $c }
}
if (-not $chosen) {
    throw "Windows blocked scheduled scripts in every folder tried ($($candidates -join ', ')). Try again with -InstallDir set to another folder you own, e.g. -InstallDir `"$env:USERPROFILE\Tools\SundaySort`"."
}
$InstallDir = $chosen

# 1) Copy the scripts
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
foreach ($f in 'Sort-Downloads.ps1', 'Undo-LastSort.ps1', 'Find-Reclaimable.ps1', 'Remove-Reclaimable.ps1', 'Watch-Downloads.ps1', 'Uninstall.ps1') {
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
Register-ScheduledTask -TaskName $TaskName -Description 'Sorts loose files in Downloads into folders by type. Never deletes anything.' `
    -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null

# 6) Live mode: a watcher that starts when you log in and keeps running in the background
if ($Live) {
    $watcherScript = Join-Path $InstallDir 'Watch-Downloads.ps1'
    $watchArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$watcherScript`" -SettleSeconds $SettleSeconds$ruleArgs"
    if ($Path) { $watchArgs += " -Path `"$((Resolve-Path -LiteralPath $Path).ProviderPath)`"" }
    if (-not $NoNotify) { $watchArgs += ' -Notify' }
    $liveAction   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $watchArgs
    # Start at log-on, and check every 15 minutes: if the watcher was closed for any reason it starts
    # again (if it's already running, Windows ignores the extra start because of IgnoreNew below).
    $liveTrigger  = @(
        (New-ScheduledTaskTrigger -AtLogOn -User ([Security.Principal.WindowsIdentity]::GetCurrent().Name)),
        (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 15))
    )
    $liveSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) `
                        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $LiveTaskName -Description 'Sorts new downloads shortly after they finish. Never deletes anything.' `
        -Action $liveAction -Trigger $liveTrigger -Settings $liveSettings -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName $LiveTaskName
    Start-Sleep -Seconds 3
    if ((Get-ScheduledTask -TaskName $LiveTaskName).State -ne 'Running') {
        Write-Warning "Live mode was set up but didn't stay running. Check Task Scheduler -> '$LiveTaskName' -> Last Run Result."
    }
}

# 7) The app: compiled right here with the C# compiler built into Windows, so there's no downloaded
#    .exe (and no "unknown app" warning). Adds SundaySort to the Start menu.
$appExe = Join-Path $InstallDir 'SundaySort.exe'
if (-not $NoApp) {
    try {
        Get-Process SundaySort -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $appExe } | Stop-Process -Force
        & (Join-Path $here 'app\Build-App.ps1') -OutDir $InstallDir | Out-Null
        $lnk = Join-Path ([Environment]::GetFolderPath('Programs')) 'SundaySort.lnk'
        $sh = New-Object -ComObject WScript.Shell
        $sc = $sh.CreateShortcut($lnk)
        $sc.TargetPath = $appExe; $sc.WorkingDirectory = $InstallDir
        $sc.Description = 'Keeps your Downloads folder tidy'; $sc.IconLocation = "$appExe,0"
        $sc.Save()
    } catch {
        Write-Warning "The SundaySort app couldn't be built ($($_.Exception.Message)). Background sorting is installed and works without it."
        $appExe = $null
    }
} else { $appExe = $null }

$next = (Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo).NextRunTime
Write-Output ""
Write-Output "Installed to $InstallDir"
Write-Output "Scheduled every $Day at $($at.ToString('h:mm tt')). Next run: $next"
if ($Live) { Write-Output "Live mode is on: new downloads are sorted $SettleSeconds seconds after they finish. Starts automatically when you log in." }
Write-Output "Sort now:  & `"$sorter`""
Write-Output "Undo:      & `"$(Join-Path $InstallDir 'Undo-LastSort.ps1')`""
Write-Output "Cleanup:   & `"$(Join-Path $InstallDir 'Find-Reclaimable.ps1')`""
if (-not $NoContextMenu) { Write-Output 'Right-click any folder -> "Tidy with SundaySort" (Windows 11: under "Show more options")' }
Write-Output "Remove:    & `"$(Join-Path $InstallDir 'Uninstall.ps1')`""
Write-Output "Logs and reports: $(Join-Path $env:LOCALAPPDATA 'SundaySort')"
if ($appExe -and (Test-Path -LiteralPath $appExe)) {
    Write-Output ""
    Write-Output "The SundaySort app is in your Start menu. Opening it now..."
    Start-Process -FilePath $appExe
}
