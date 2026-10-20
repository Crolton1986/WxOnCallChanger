#Requires -Version 7.4
<#
.SYNOPSIS
Starts the On-Call Manager: web UI on http://localhost:8080 plus the Webex check (interval set in Settings).

.DESCRIPTION
Pode is loaded from .\lib\Pode if present, otherwise from your installed modules.
Install it once for your account (no admin) with:
    Install-Module -Name Pode -Scope CurrentUser

Press Ctrl+C to stop when running interactively. The scheduled task runs it with -Service.
#>
[CmdletBinding()]
param(
    [int]$Port = 8080,
    [switch]$Service   # no console (scheduled task): run as a Pode daemon
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$env:ONCALL_DATA = Join-Path $root 'data'
$env:ONCALL_ROOT = $root
$env:ONCALL_PORT = $Port

# --- Pode -------------------------------------------------------------------
$localPode = Get-ChildItem -Path (Join-Path $root 'lib\Pode') -Filter 'Pode.psd1' -Recurse -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($localPode) { Import-Module $localPode.FullName -Force }
elseif (Get-Module -ListAvailable Pode) { Import-Module Pode -Force }
else { throw 'Pode not found. Run: Install-Module -Name Pode -Scope CurrentUser' }

# --- App modules ------------------------------------------------------------
Import-Module (Join-Path $root 'modules\Webex.psm1') -Force
Import-Module (Join-Path $root 'modules\Schedule.psm1') -Force
Import-Module (Join-Path $root 'modules\Web.psm1') -Force
$env:ONCALL_TZ = (Get-OnCallConfig).TimeZone
if (-not $env:ONCALL_TZ) { $env:ONCALL_TZ = 'Pacific Standard Time' }

$podeOptions = @{ Threads = 4 }
if ($Service) { $podeOptions.Daemon = $true }

Start-PodeServer @podeOptions -ScriptBlock {
    Add-PodeEndpoint -Address localhost -Port $env:ONCALL_PORT -Protocol Http

    New-PodeLoggingMethod -File -Name 'server' -Path (Join-Path $env:ONCALL_ROOT 'logs') -MaxDays 30 | Enable-PodeErrorLogging

    Import-PodeModule -Path (Join-Path $env:ONCALL_ROOT 'modules\Webex.psm1')
    Import-PodeModule -Path (Join-Path $env:ONCALL_ROOT 'modules\Schedule.psm1')
    Import-PodeModule -Path (Join-Path $env:ONCALL_ROOT 'modules\Web.psm1')

    # Local-only guard: right Host header (blocks DNS rebinding) and, for anything that
    # changes data, JSON plus a custom header (blocks cross-site form posts).
    Add-PodeMiddleware -Name 'guard' -ScriptBlock {
        $host_ = "$($WebEvent.Request.Headers['Host'])" -replace ':\d+$', ''
        if ($host_ -notin @('localhost', '127.0.0.1')) {
            Set-PodeResponseStatus -Code 403 -NoErrorPage
            return $false
        }
        if ($WebEvent.Method -in 'post', 'put', 'delete' -and $WebEvent.Path -like '/api/*') {
            if ($WebEvent.Request.Headers['X-OnCall'] -ne '1') {
                Write-PodeJsonResponse -StatusCode 403 -Value @{ error = 'Missing X-OnCall header.' }
                return $false
            }
        }
        return $true
    }

    Add-PodeStaticRoute -Path '/public' -Source (Join-Path $env:ONCALL_ROOT 'public')
    Add-PodeRoute -Method Get -Path '/' -ScriptBlock {
        Write-PodeFileResponse -Path (Join-Path $env:ONCALL_ROOT 'public\index.html') -ContentType 'text/html; charset=utf-8'
    }

    # --- Status and sync ----------------------------------------------------
    Add-PodeRoute -Method Get -Path '/api/status' -ScriptBlock {
        Invoke-OnCallApi { Get-OnCallStatus }
    }
    Add-PodeRoute -Method Post -Path '/api/sync' -ScriptBlock {
        Invoke-OnCallApi -Lock { Invoke-OnCallSync -Actor 'web'; Get-OnCallStatus }
    }
    Add-PodeRoute -Method Post -Path '/api/switch' -ScriptBlock {
        Invoke-OnCallApi -Lock {
            $d = $WebEvent.Data
            if ($d.teamKey) { Set-OnCallSwitch -TeamKey $d.teamKey -Enabled ([bool]$d.enabled) }
            else            { Set-OnCallSwitch -Global -Enabled ([bool]$d.enabled) }
            Get-OnCallStatus
        }
    }

    # --- People -------------------------------------------------------------
    Add-PodeRoute -Method Get -Path '/api/people' -ScriptBlock {
        Invoke-OnCallApi { @{ items = @(Get-OnCallPerson) } }
    }
    Add-PodeRoute -Method Post -Path '/api/people' -ScriptBlock {
        Invoke-OnCallApi -Lock {
            Add-OnCallPerson -Name $WebEvent.Data.name -Number $WebEvent.Data.number -Teams @($WebEvent.Data.teams | Where-Object { $_ })
        }
    }
    Add-PodeRoute -Method Put -Path '/api/people/:id' -ScriptBlock {
        Invoke-OnCallApi -Lock {
            $d = $WebEvent.Data
            $p = @{ Person = $WebEvent.Parameters['id'] }
            if ($d.name)   { $p.Name   = $d.name }
            if ($d.number) { $p.Number = $d.number }
            if ($d.ContainsKey('teams')) { $p.Teams = [string[]]@($d.teams | Where-Object { $_ }) }
            Set-OnCallPerson @p
        }
    }
    Add-PodeRoute -Method Delete -Path '/api/people/:id' -ScriptBlock {
        Invoke-OnCallApi -Lock { Remove-OnCallPerson -Person $WebEvent.Parameters['id']; @{ ok = $true } }
    }

    # --- Rotations ----------------------------------------------------------
    Add-PodeRoute -Method Get -Path '/api/rotations' -ScriptBlock {
        Invoke-OnCallApi { @{ items = @(Get-OnCallTeams | ForEach-Object { Get-OnCallRotation -TeamKey $_.Key }) } }
    }
    Add-PodeRoute -Method Put -Path '/api/rotations/:team' -ScriptBlock {
        Invoke-OnCallApi -Lock {
            $d = $WebEvent.Data
            Set-OnCallRotation -TeamKey $WebEvent.Parameters['team'] -Members @($d.members) `
                -AnchorStart $d.anchorStart -AnchorPerson $d.anchorPersonId
            Get-OnCallRotation -TeamKey $WebEvent.Parameters['team']
        }
    }

    # --- Calendar events and overrides --------------------------------------
    Add-PodeRoute -Method Get -Path '/api/events' -ScriptBlock {
        Invoke-OnCallApi { Get-OnCallEvents -Start $WebEvent.Query['start'] -End $WebEvent.Query['end'] }
    }
    Add-PodeRoute -Method Post -Path '/api/overrides' -ScriptBlock {
        Invoke-OnCallApi -Lock {
            $d = $WebEvent.Data
            Add-OnCallOverride -TeamKey $d.teamKey -Person $d.personId -Start $d.start -End $d.end -Note $d.note
        }
    }
    Add-PodeRoute -Method Put -Path '/api/overrides/:id' -ScriptBlock {
        Invoke-OnCallApi -Lock {
            $d = $WebEvent.Data
            $p = @{ Id = $WebEvent.Parameters['id'] }
            if ($d.personId) { $p.Person = $d.personId }
            if ($d.start)    { $p.Start  = $d.start }
            if ($d.end)      { $p.End    = $d.end }
            if ($d.ContainsKey('note')) { $p.Note = "$($d.note)" }
            Set-OnCallOverride @p
        }
    }
    Add-PodeRoute -Method Delete -Path '/api/overrides/:id' -ScriptBlock {
        Invoke-OnCallApi -Lock {
            Remove-OnCallOverride -Id $WebEvent.Parameters['id'] -WholeSwap:($WebEvent.Query['swap'] -eq '1')
            @{ ok = $true }
        }
    }

    # --- Week swaps ---------------------------------------------------------
    Add-PodeRoute -Method Get -Path '/api/swap-options' -ScriptBlock {
        Invoke-OnCallApi {
            Get-OnCallSwapOptions -TeamKey $WebEvent.Query['team'] -WeekStart $WebEvent.Query['week'] -WithPerson $WebEvent.Query['person']
        }
    }
    Add-PodeRoute -Method Post -Path '/api/swaps' -ScriptBlock {
        Invoke-OnCallApi -Lock {
            $d = $WebEvent.Data
            $null = New-OnCallSwap -TeamKey $d.teamKey -WeekStart $d.weekStart -WithPerson $d.withPersonId -OtherWeekStart $d.otherWeekStart
            @{ ok = $true }
        }
    }

    # --- Teams --------------------------------------------------------------
    Add-PodeRoute -Method Get -Path '/api/teams' -ScriptBlock {
        Invoke-OnCallApi { Get-OnCallTeamsView }
    }
    Add-PodeRoute -Method Post -Path '/api/teams' -ScriptBlock {
        Invoke-OnCallApi -Lock { Add-OnCallTeam -DisplayName "$($WebEvent.Data.displayName)" -WebexTeamId "$($WebEvent.Data.webexTeamId)" }
    }
    Add-PodeRoute -Method Put -Path '/api/teams/:key' -ScriptBlock {
        Invoke-OnCallApi -Lock {
            Set-OnCallTeam -TeamKey $WebEvent.Parameters['key'] -DisplayName "$($WebEvent.Data.displayName)" -WebexTeamId "$($WebEvent.Data.webexTeamId)"
        }
    }
    Add-PodeRoute -Method Delete -Path '/api/teams/:key' -ScriptBlock {
        Invoke-OnCallApi -Lock { Remove-OnCallTeam -TeamKey $WebEvent.Parameters['key']; @{ ok = $true } }
    }

    # --- Webex credentials (write-only) --------------------------------------
    Add-PodeRoute -Method Get -Path '/api/credentials' -ScriptBlock {
        Invoke-OnCallApi { Get-OnCallCredentialStatus }
    }
    Add-PodeRoute -Method Post -Path '/api/credentials' -ScriptBlock {
        Invoke-OnCallApi -Lock { Update-OnCallCredential -Body $WebEvent.Data }
    }
    Add-PodeRoute -Method Post -Path '/api/settings' -ScriptBlock {
        Invoke-OnCallApi -Lock { Set-OnCallCheckMinutes -Minutes ([int]$WebEvent.Data.checkMinutes); @{ checkMinutes = Get-OnCallCheckMinutes } }
    }

    # --- Audit --------------------------------------------------------------
    Add-PodeRoute -Method Get -Path '/api/audit' -ScriptBlock {
        Invoke-OnCallApi { @{ items = @(Get-OnCallAudit -Last 300) } }
    }

    # --- The check loop -----------------------------------------------------
    # Ticks every minute but only calls Webex on the interval set in Settings,
    # or right when a handoff or cover changes who should be on call.
    Add-PodeSchedule -Name 'sync' -Cron '* * * * *' -OnStart -ScriptBlock {
        Lock-PodeObject -ScriptBlock {
            try { Invoke-OnCallTick -Actor 'scheduler' }
            catch { Write-OnCallAudit -Event 'sync_error' -Detail $_.Exception.Message -Actor 'scheduler' }
        }
    }

    Write-Host "On-Call Manager running at http://localhost:$env:ONCALL_PORT  (Ctrl+C to stop)" -ForegroundColor Green
}
