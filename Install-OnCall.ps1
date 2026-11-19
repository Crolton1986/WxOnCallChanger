#Requires -Version 7.4
<#
.SYNOPSIS
Keeps the On-Call Manager running under your own account. No admin rights needed.

.DESCRIPTION
1. Installs Pode into your profile (CurrentUser scope) if it isn't already available.
2. Checks that the saved Webex keys can be read by this account.
3. Windows: registers a scheduled task, as you, that runs Start-OnCall.ps1 -Service.
   Linux:   writes a systemd user service and enables it, plus "linger" so it runs while
            you're signed out.

Windows details: a boot trigger needs admin, so the task uses a repeating trigger instead. It
starts now and re-checks every 5 minutes; if the server is already running, Windows skips the
repeat. By default the task runs whether or not you're signed in, so it asks for your Windows
password once. If your account isn't allowed to do that, use -WhenLoggedOn.

In a container you don't need this script: the image runs the server, and Docker's restart
policy keeps it up.

.EXAMPLE
./Install-OnCall.ps1
.EXAMPLE
./Install-OnCall.ps1 -Listen Network -PublicUrl https://oncall.example.com:8443
.EXAMPLE
./Install-OnCall.ps1 -WhenLoggedOn
.EXAMPLE
./Install-OnCall.ps1 -Remove
#>
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName = 'Install')][ValidateSet('Local', 'Network')][string]$Listen = 'Local',
    [Parameter(ParameterSetName = 'Install')][int]$Port,
    [Parameter(ParameterSetName = 'Install')][string]$PublicUrl,
    [Parameter(ParameterSetName = 'Install')][switch]$WhenLoggedOn,
    [Parameter(ParameterSetName = 'Remove', Mandatory)][switch]$Remove,
    [string]$TaskName = 'On-Call Manager'
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $IsWindows -and -not $IsLinux) { throw 'Install-OnCall.ps1 supports Windows and Linux. On other systems, run Start-OnCall.ps1 under your own service manager.' }
if (-not $Port) { $Port = if ($Listen -eq 'Network') { 8443 } else { 8080 } }

$unitName = 'oncall.service'
$unitDir  = Join-Path $(if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }) 'systemd' 'user'
$unitFile = Join-Path $unitDir $unitName

if ($Remove) {
    if ($IsWindows) {
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Host "Removed scheduled task '$TaskName'." -ForegroundColor Green
        } else {
            Write-Host "No scheduled task named '$TaskName'."
        }
    }
    else {
        if (Test-Path -LiteralPath $unitFile) {
            & systemctl --user disable --now $unitName 2>$null
            Remove-Item -LiteralPath $unitFile
            & systemctl --user daemon-reload
            Write-Host "Removed $unitName. Linger is left as it was (loginctl disable-linger to turn it off)." -ForegroundColor Green
        } else {
            Write-Host "No $unitName in $unitDir."
        }
    }
    return
}

# --- 1. Pode, in your profile ------------------------------------------------
$inLib = Get-ChildItem (Join-Path $root 'lib' 'Pode') -Filter Pode.psd1 -Recurse -ErrorAction SilentlyContinue
if (-not $inLib -and -not (Get-Module -ListAvailable -Name Pode)) {
    Write-Host 'Installing Pode for your account (CurrentUser scope)...' -ForegroundColor Cyan
    Install-Module -Name Pode -Scope CurrentUser -Repository PSGallery -Force
}

# --- 2. Saved keys must be readable by this account ------------------------
Import-Module (Join-Path $root 'modules' 'Webex.psm1') -Force
Initialize-WebexModule -DataPath $(if ($env:ONCALL_DATA) { $env:ONCALL_DATA } else { Join-Path $root 'data' })
$me = Get-OnCallAccountName
try { $null = Get-WebexTokenStatus }
catch {
    if ($_.Exception.Message -like 'No Webex keys*') {
        Write-Warning 'No Webex keys saved yet. Add them on the Settings page once the server is running.'
    }
    else { throw "The saved Webex keys can't be read as $me. $($_.Exception.Message)" }
}

$startArgs = "-Listen $Listen -Port $Port"
if ($PublicUrl) { $startArgs += " -PublicUrl $PublicUrl" }
$openAt = if ($Listen -eq 'Network') { if ($PublicUrl) { $PublicUrl } else { "https://localhost:$Port" } } else { "http://localhost:$Port" }
$pwsh = (Get-Process -Id $PID).Path

# --- 3a. Linux: systemd user service ------------------------------------------
if ($IsLinux) {
    if (-not (Get-Command systemctl -ErrorAction SilentlyContinue)) {
        throw 'systemctl not found. Run Start-OnCall.ps1 under your own service manager, or use the container image.'
    }
    $null = New-Item -ItemType Directory -Path $unitDir -Force
    @"
[Unit]
Description=On-Call Manager (Webex Contact Center on-call switching)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$root
ExecStart=$pwsh -NoProfile -NonInteractive -File "$root/Start-OnCall.ps1" $startArgs
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
"@ | Set-Content -LiteralPath $unitFile -Encoding utf8

    & systemctl --user daemon-reload
    & systemctl --user enable --now $unitName
    if ($LASTEXITCODE) { throw "systemctl couldn't start $unitName. Check: journalctl --user -u $unitName" }

    & loginctl enable-linger $env:USER 2>$null
    $lingerOn = (& loginctl show-user $env:USER --property=Linger 2>$null) -eq 'Linger=yes'
    Write-Host "Installed $unitName as $me." -ForegroundColor Green
    if (-not $lingerOn) {
        Write-Warning "It runs only while you're signed in, because this system wouldn't turn on linger for you. An admin can run: sudo loginctl enable-linger $env:USER"
    }
    Write-Host "Open $openAt in a few seconds. Logs: journalctl --user -u $unitName"
    if ($Listen -eq 'Network') { Write-Host 'The first-time setup code is in that log.' }
    return
}

# --- 3b. Windows: scheduled task, as you -----------------------------------
$argLine = "-NoProfile -NonInteractive -File `"$(Join-Path $root 'Start-OnCall.ps1')`" -Service $startArgs"
$action  = New-ScheduledTaskAction -Execute $pwsh -Argument $argLine -WorkingDirectory $root
$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew `
    -StartWhenAvailable `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

if ($WhenLoggedOn) {
    $trigger  = New-ScheduledTaskTrigger -AtLogOn -User $me
    $register = @{ Principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited }
} else {
    $trigger  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
    $cred     = Get-Credential -UserName $me -Message 'Your Windows password, so the task can run while you are signed out'
    $register = @{ User = $me; Password = $cred.GetNetworkCredential().Password; RunLevel = 'Limited' }
}

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

try {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings @register `
        -Description "Webex Contact Center on-call switching. Web UI at $openAt" | Out-Null
}
catch {
    if ($WhenLoggedOn) { throw }
    throw ("Windows would not register a task that runs while $me is signed out. " +
           "Check the password, or this account may lack the 'Log on as a batch job' right. " +
           "Run again with -WhenLoggedOn to run only while signed in. Details: $($_.Exception.Message)")
}

Start-ScheduledTask -TaskName $TaskName
$mode = if ($WhenLoggedOn) { 'while you are signed in' } else { 'whether or not you are signed in' }
Write-Host "Installed '$TaskName' as $me, running $mode." -ForegroundColor Green
Write-Host "Open $openAt in a few seconds. Logs: $(Join-Path $root 'logs')"
