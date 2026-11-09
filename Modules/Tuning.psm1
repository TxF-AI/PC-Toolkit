#requires -Version 5.1
<#
    Tuning.psm1 — Presets d'optimisation 1-clic (Jeu / MAO / Bureautique)
    ---------------------------------------------------------------------
    Un preset assemble des briques déjà existantes et déjà sûres :
      • plan d'alimentation + arrêt temporaire de services secondaires  → Enable-GameMode (état sauvegardé, restauration en un clic)
      • vidage du cache RAM                                            → Invoke-RamTrim (effet temporaire, aucun programme fermé)
      • nettoyage des fichiers temporaires                             → Invoke-TempCleanup
      • désactivation des programmes de démarrage superflus            → Invoke-StartupAutoClean (liste blanche, sauvegarde)
    Rien n'est exécuté sans -Confirmed. Les services audio ne sont jamais touchés (la liste vient de Performance.psm1).
#>

function Get-TuningProfiles {
    <# Les 3 presets. Services : sous-ensemble de la liste officielle du Mode Performance. #>
    @(
        [pscustomobject]@{
            Id = 'Game'; Name = (Get-Text 'Tun.NameGame')
            Summary = (Get-Text 'Tun.002')
            Details = (Get-Text 'Tun.003')
            Services = @('Spooler', 'SysMain', 'wuauserv', 'DiagTrack', 'MapsBroker', 'Fax', 'RemoteRegistry')
            Power = $true; FlushRam = $true; CleanTemp = $true; CleanStartup = $true
        }
        [pscustomobject]@{
            Id = 'MAO'; Name = (Get-Text 'Tun.NameMao')
            Summary = (Get-Text 'Tun.010')
            Details = (Get-Text 'Tun.011')
            Services = @('Spooler', 'SysMain', 'wuauserv', 'DiagTrack', 'MapsBroker', 'Fax', 'RemoteRegistry')
            Power = $true; FlushRam = $false; CleanTemp = $false; CleanStartup = $true
        }
        [pscustomobject]@{
            Id = 'Office'; Name = (Get-Text 'Tun.019')
            Summary = (Get-Text 'Tun.020')
            Details = (Get-Text 'Tun.021')
            Services = @('DiagTrack', 'MapsBroker', 'Fax', 'RemoteRegistry')
            Power = $false; FlushRam = $false; CleanTemp = $true; CleanStartup = $false
        }
    )
}

function Get-TuningPlan {
    <# Lecture seule : ce que le preset ferait réellement maintenant (pour l'aperçu avant confirmation). #>
    param([Parameter(Mandatory)][string]$Id)
    $p = Get-TuningProfiles | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $p) { throw (Get-Text 'Tun.025' $Id) }
    $st = Get-GameModeStatus
    $running = @($st.Services | Where-Object { $_.Running -and $p.Services -contains $_.Name })
    $tempCount = $null; $tempBytes = $null
    if ($p.CleanTemp) { try { $pv = Get-TempCleanupPreview -Ctx $null; $tempCount = $pv.Count; $tempBytes = $pv.Bytes } catch { } }
    $startup = $null
    if ($p.CleanStartup) { try { $startup = @((Get-StartupCleanupPlan).Targets) } catch { } }
    [pscustomobject]@{
        Profile = $p; IsAdmin = $st.IsAdmin; ModeActive = $st.ModeActive; ActivePlan = $st.ActivePlan
        ServicesToStop = @($running); TempCount = $tempCount; TempBytes = $tempBytes; StartupTargets = @($startup)
        NeedsAdmin = ($p.Power -or $p.Services.Count -gt 0)
    }
}

function Invoke-TuningProfile {
    <# Applique un preset étape par étape. Une étape qui échoue n'empêche pas les autres. Exige -Confirmed. #>
    param([Parameter(Mandatory)][string]$Id, [switch]$Confirmed, $Ctx)
    if (-not $Confirmed) { throw (Get-Text 'Tun.026') }
    $p = Get-TuningProfiles | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $p) { throw (Get-Text 'Tun.027' $Id) }
    $steps = New-Object System.Collections.ArrayList
    $step = { param($n, $s, $d) [void]$steps.Add([pscustomobject]@{ Step = $n; Status = $s; Detail = $d }) }
    Write-AppLog (Get-Text 'Tun.028' $($p.Name)) 'ACTION'
    Update-DiagProgress $Ctx 5 (Get-Text 'Tun.030')

    Update-DiagProgress $Ctx 15 (Get-Text 'Tun.031')
    if ($p.Power -or $p.Services.Count -gt 0) {
        $st = Get-GameModeStatus
        if (-not $st.IsAdmin) { & $step (Get-Text 'Tun.032') 'Ignoré' (Get-Text 'Tun.034') }
        elseif ($st.ModeActive) { & $step (Get-Text 'Tun.035') 'Ignoré' (Get-Text 'Tun.037') }
        else {
            try {
                $r = Enable-GameMode -Confirmed -OnlyServices $p.Services -SkipPowerPlan:(-not $p.Power) -ProfileName (Get-Text 'Tun.038' $($p.Name))
                $d = @()
                if ($p.Power) { $d += $(if ($r.PlanAfter) { (Get-Text 'Tun.039' $($r.PlanAfter)) } else { (Get-Text 'Tun.040') }) }
                $d += (Get-Text 'Tun.041' $($r.Stopped.Count)) + $(if ($r.Stopped.Count) { ' (' + ($r.Stopped -join ', ') + ')' } else { '' })
                if ($r.Failed.Count) { $d += (Get-Text 'Tun.042') + ($r.Failed -join ', ') }
                & $step (Get-Text 'Tun.043') 'OK' ($d -join ' ; ')
            } catch { & $step (Get-Text 'Tun.044') 'Échec' $_.Exception.Message }
        }
    }
    Update-DiagProgress $Ctx 45 (Get-Text 'Tun.046')
    if ($p.FlushRam) {
        try { $r = Invoke-RamTrim -Confirmed; & $step (Get-Text 'Tun.047') 'OK' ((Get-Text 'Tun.048') -f $r.Processes, $(if ($null -ne $r.FreedMB) { (Get-Text 'Tun.049' $($r.FreedMB)) } else { (Get-Text 'Tun.050') })) }
        catch { & $step (Get-Text 'Tun.051') 'Échec' $_.Exception.Message }
    }
    Update-DiagProgress $Ctx 65 (Get-Text 'Tun.053')
    if ($p.CleanTemp) {
        try {
            $pv = Get-TempCleanupPreview -Ctx $null
            $r = Invoke-TempCleanup -Ctx $null -Files $pv.Files -Roots $pv.Roots -Confirmed
            & $step (Get-Text 'Tun.054') 'OK' ((Get-Text 'Tun.055') -f $r.Deleted, (Format-Bytes $r.Freed))
        } catch { & $step (Get-Text 'Tun.056') 'Échec' $_.Exception.Message }
    }
    Update-DiagProgress $Ctx 85 (Get-Text 'Tun.058')
    if ($p.CleanStartup) {
        try {
            $r = Invoke-StartupAutoClean -Confirmed
            & $step (Get-Text 'Tun.059') 'OK' ((Get-Text 'Tun.060') -f $r.Disabled.Count)
        } catch { & $step (Get-Text 'Tun.061') 'Échec' $_.Exception.Message }
    }
    Write-AppLog ((Get-Text 'Tun.063') -f $p.Name, $steps.Count) 'ACTION'
    [pscustomobject]@{ Profile = $p; Steps = @($steps) }
}

Export-ModuleMember -Function Get-TuningProfiles, Get-TuningPlan, Invoke-TuningProfile
