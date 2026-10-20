#Requires -Version 7.4
<#
.SYNOPSIS
Sets up the On-Call Manager to keep running under your own Windows account. No admin rights needed.

.DESCRIPTION
1. Installs Pode into your profile (CurrentUser scope) if it isn't already available.
2. Checks that the saved Webex keys belong to you.
3. Registers a scheduled task, as you, that runs Start-OnCall.ps1 -Service.

A boot trigger needs admin, so the task uses a repeating trigger instead: it starts now and
re-checks every 5 minutes. If the server is already running, Windows skips the repeat. After a
reboot or a crash it comes back within 5 minutes.

By default the task runs whether or not you're signed in, so it asks for your Windows password
once. If your account isn't allowed to do that, use -WhenLoggedOn to run only while you're signed in.

.EXAMPLE
.\Install-OnCall.ps1
.EXAMPLE
.\Install-OnCall.ps1 -WhenLoggedOn
.EXAMPLE
.\Install-OnCall.ps1 -Remove
#>
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName = 'Install')][int]$Port = 8080,
    [Parameter(ParameterSetName = 'Install')][switch]$WhenLoggedOn,
    [Parameter(ParameterSetName = 'Remove', Mandatory)][switch]$Remove,
    [string]$TaskName = 'On-Call Manager'
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$me   = "$env:USERDOMAIN\$env:USERNAME"

if ($Remove) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Removed scheduled task '$TaskName'." -ForegroundColor Green
    } else {
        Write-Host "No scheduled task named '$TaskName'."
    }
    return
}

# --- 1. Pode, in your profile ------------------------------------------------
$inLib = Get-ChildItem (Join-Path $root 'lib\Pode') -Filter Pode.psd1 -Recurse -ErrorAction SilentlyContinue
if (-not $inLib -and -not (Get-Module -ListAvailable -Name Pode)) {
    Write-Host 'Installing Pode for your account (CurrentUser scope)...' -ForegroundColor Cyan
    Install-Module -Name Pode -Scope CurrentUser -Repository PSGallery -Force
}

# --- 2. Webex keys must be readable by this account --------------------------
$secrets = Join-Path $root 'data\secrets.clixml'
if (-not (Test-Path $secrets)) {
    throw 'No Webex keys saved yet. Run .\Test-Webex.ps1 -SetupCredential first.'
}
try {
    $s = Import-Clixml $secrets
    $null = ConvertFrom-SecureString $s.ClientSecret -AsPlainText
}
catch {
    throw "The saved Webex keys were saved by a different Windows account. Run .\Test-Webex.ps1 -SetupCredential as $me."
}

# --- 3. Scheduled task, as you -----------------------------------------------
$pwsh    = (Get-Process -Id $PID).Path
$argLine = "-NoProfile -NonInteractive -File `"$root\Start-OnCall.ps1`" -Service -Port $Port"
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
        -Description "Webex Contact Center on-call switching. Web UI at http://localhost:$Port" | Out-Null
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
Write-Host "Open http://localhost:$Port in a few seconds. Logs: $root\logs"
