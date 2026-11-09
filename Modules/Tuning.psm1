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
            Id = 'Game'; Name = 'Jeu'
            Summary = 'Performances maximales pour jouer.'
            Details = 'Plan Performances ultimes / élevées, arrêt temporaire de 7 services secondaires, vidage du cache RAM, nettoyage des fichiers temporaires et du démarrage.'
            Services = @('Spooler', 'SysMain', 'wuauserv', 'DiagTrack', 'MapsBroker', 'Fax', 'RemoteRegistry')
            Power = $true; FlushRam = $true; CleanTemp = $true; CleanStartup = $true
        }
        [pscustomobject]@{
            Id = 'MAO'; Name = 'MAO'
            Summary = 'Latence stable pour l''audio : aucune interruption en arrière-plan.'
            Details = 'Plan haute performance, arrêt temporaire des services secondaires (dont Windows Update et SysMain, sources de pics de latence), nettoyage du démarrage. La RAM n''est PAS vidée : cela évincerait les échantillons et plugins chargés en mémoire. Les services audio ne sont jamais touchés.'
            Services = @('Spooler', 'SysMain', 'wuauserv', 'DiagTrack', 'MapsBroker', 'Fax', 'RemoteRegistry')
            Power = $true; FlushRam = $false; CleanTemp = $false; CleanStartup = $true
        }
        [pscustomobject]@{
            Id = 'Office'; Name = 'Bureautique'
            Summary = 'Allègement discret pour le travail quotidien.'
            Details = 'Plan d''alimentation conservé, arrêt temporaire de 4 services inutiles (télémétrie, cartes, fax, registre distant), nettoyage des fichiers temporaires. Le démarrage n''est pas modifié.'
            Services = @('DiagTrack', 'MapsBroker', 'Fax', 'RemoteRegistry')
            Power = $false; FlushRam = $false; CleanTemp = $true; CleanStartup = $false
        }
    )
}

function Get-TuningPlan {
    <# Lecture seule : ce que le preset ferait réellement maintenant (pour l'aperçu avant confirmation). #>
    param([Parameter(Mandatory)][string]$Id)
    $p = Get-TuningProfiles | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $p) { throw "Preset inconnu : $Id" }
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
    if (-not $Confirmed) { throw 'Confirmation explicite requise (-Confirmed).' }
    $p = Get-TuningProfiles | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $p) { throw "Preset inconnu : $Id" }
    $steps = New-Object System.Collections.ArrayList
    $step = { param($n, $s, $d) [void]$steps.Add([pscustomobject]@{ Step = $n; Status = $s; Detail = $d }) }
    Write-AppLog "Preset d'optimisation « $($p.Name) » : démarrage" 'ACTION'
    Update-DiagProgress $Ctx 5 'Préparation…'

    Update-DiagProgress $Ctx 15 'Plan d''alimentation et services…'
    if ($p.Power -or $p.Services.Count -gt 0) {
        $st = Get-GameModeStatus
        if (-not $st.IsAdmin) { & $step 'Plan d''alimentation et services' 'Ignoré' 'droits administrateur requis' }
        elseif ($st.ModeActive) { & $step 'Plan d''alimentation et services' 'Ignoré' 'un profil est déjà actif : restaurez-le d''abord' }
        else {
            try {
                $r = Enable-GameMode -Confirmed -OnlyServices $p.Services -SkipPowerPlan:(-not $p.Power) -ProfileName "Preset $($p.Name)"
                $d = @()
                if ($p.Power) { $d += $(if ($r.PlanAfter) { "plan « $($r.PlanAfter) »" } else { 'plan inchangé' }) }
                $d += "$($r.Stopped.Count) service(s) arrêté(s)" + $(if ($r.Stopped.Count) { ' (' + ($r.Stopped -join ', ') + ')' } else { '' })
                if ($r.Failed.Count) { $d += 'non arrêtés : ' + ($r.Failed -join ', ') }
                & $step 'Plan d''alimentation et services' 'OK' ($d -join ' ; ')
            } catch { & $step 'Plan d''alimentation et services' 'Échec' $_.Exception.Message }
        }
    }
    Update-DiagProgress $Ctx 45 'Cache RAM…'
    if ($p.FlushRam) {
        try { $r = Invoke-RamTrim -Confirmed; & $step 'Cache RAM' 'OK' ("{0} processus allégés ({1})" -f $r.Processes, $(if ($null -ne $r.FreedMB) { "$($r.FreedMB) Mo gagnés" } else { 'gain non mesurable' })) }
        catch { & $step 'Cache RAM' 'Échec' $_.Exception.Message }
    }
    Update-DiagProgress $Ctx 65 'Fichiers temporaires…'
    if ($p.CleanTemp) {
        try {
            $pv = Get-TempCleanupPreview -Ctx $null
            $r = Invoke-TempCleanup -Ctx $null -Files $pv.Files -Roots $pv.Roots -Confirmed
            & $step 'Fichiers temporaires' 'OK' ("{0} fichier(s) supprimé(s) ({1})" -f $r.Deleted, (Format-Bytes $r.Freed))
        } catch { & $step 'Fichiers temporaires' 'Échec' $_.Exception.Message }
    }
    Update-DiagProgress $Ctx 85 'Démarrage…'
    if ($p.CleanStartup) {
        try {
            $r = Invoke-StartupAutoClean -Confirmed
            & $step 'Démarrage' 'OK' ("{0} programme(s) désactivé(s)" -f $r.Disabled.Count)
        } catch { & $step 'Démarrage' 'Échec' $_.Exception.Message }
    }
    Write-AppLog ("Preset d'optimisation « {0} » : terminé ({1} étape(s))" -f $p.Name, $steps.Count) 'ACTION'
    [pscustomobject]@{ Profile = $p; Steps = @($steps) }
}

Export-ModuleMember -Function Get-TuningProfiles, Get-TuningPlan, Invoke-TuningProfile
