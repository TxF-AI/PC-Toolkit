#requires -Version 5.1
<#
    Dashboard.psm1 — Tableau de bord (lecture seule, ~10 s)
    Vue rapide de l'état général + liste des points d'attention.
    S'appuie sur les fonctions exportées par les autres modules.
#>

function Invoke-DashboardDiagnostic {
    param($Ctx)
    $r = New-DiagResult -Module 'Dashboard' -Title 'Tableau de bord' -Ctx $Ctx
    $alerts = New-Object System.Collections.ArrayList
    function Add-Alert([string]$Status, [string]$Label, [string]$Text) { [void]$alerts.Add([pscustomobject]@{ Status = $Status; Label = $Label; Text = $Text }) }

    $os = Get-SafeCim Win32_OperatingSystem
    $cpu = Get-SafeCim Win32_Processor | Select-Object -First 1

    Add-DiagSection $r 'Vue d''ensemble' -Layout Tiles -Body {
        param($s)
        Update-DiagProgress $Ctx 5 'Système…'
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        Add-DiagItem $s 'Windows' ('{0} · build {1}.{2}' -f $cv.DisplayVersion, $cv.CurrentBuild, $cv.UBR) 'Info'
        $up = (Get-Date) - $os.LastBootUpTime
        Add-DiagItem $s 'Allumé depuis' (Format-Span $up) $(if ($up.TotalDays -gt 7) { 'Warn' } else { 'OK' })
        if ($up.TotalDays -gt 7) { Add-Alert 'Warn' 'Redémarrage' 'Pas de redémarrage depuis plus de 7 jours.' }

        Update-DiagProgress $Ctx 15 'Charge du processeur…'
        $load = Get-CpuLoadSample 2
        Add-DiagItem $s 'Charge CPU' $(if ($null -ne $load) { "$load %" }) $(if ($load -ge 90) { 'Crit' } elseif ($load -ge 70) { 'Warn' } else { 'OK' }) ($cpu.Name.Trim())
        if ($load -ge 70) { Add-Alert 'Warn' 'Processeur' "Charge élevée au repos ($load %)." }

        $ramPct = [math]::Round((1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize) * 100, 0)
        Add-DiagItem $s 'Mémoire utilisée' "$ramPct %" $(if ($ramPct -ge 90) { 'Crit' } elseif ($ramPct -ge 80) { 'Warn' } else { 'OK' }) ('{0} au total' -f (Format-Bytes ($os.TotalVisibleMemorySize * 1KB)))
        if ($ramPct -ge 80) { Add-Alert 'Warn' 'Mémoire' "Mémoire utilisée à $ramPct %." }

        Update-DiagProgress $Ctx 25 'Disques…'
        $c = Get-Volume -DriveLetter ($env:SystemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue
        if ($c) {
            $pct = [math]::Round($c.SizeRemaining / $c.Size * 100, 0)
            $st = if ($pct -lt 8) { 'Crit' } elseif ($pct -lt 15) { 'Warn' } else { 'OK' }
            Add-DiagItem $s 'Disque système libre' ('{0} ({1} %)' -f (Format-Bytes $c.SizeRemaining), $pct) $st
            if ($st -ne 'OK') { Add-Alert $st 'Stockage' "Il reste $pct % sur le disque système." }
        }
        $bad = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { "$($_.HealthStatus)" -ne 'Healthy' })
        Add-DiagItem $s 'Santé des disques' $(if ($bad.Count) { "$($bad.Count) disque(s) à vérifier" } else { 'Tous sains' }) $(if ($bad.Count) { 'Crit' } else { 'OK' })
        if ($bad.Count) { Add-Alert 'Crit' 'Disques' ("Santé dégradée : " + (($bad.FriendlyName) -join ', ')) }

        Update-DiagProgress $Ctx 35 'Carte graphique…'
        $gpu = Get-SafeCim Win32_VideoController | Where-Object Name -notmatch 'Parsec|Virtual|Basic' | Select-Object -First 1
        if ($gpu) {
            $age = if ($gpu.DriverDate) { [int]((Get-Date) - $gpu.DriverDate).TotalDays } else { 0 }
            Add-DiagItem $s 'Pilote graphique' ('{0:dd/MM/yyyy}' -f $gpu.DriverDate) $(if ($age -gt 365) { 'Warn' } else { 'OK' }) $gpu.Name
            if ($age -gt 365) { Add-Alert 'Warn' 'Carte graphique' "Pilote vieux de $age jours." }
        }

        Update-DiagProgress $Ctx 45 'Réseau (5 s)…'
        $gw = Get-DefaultGateway
        $t = [ordered]@{}; if ($gw) { $t['Box'] = $gw }; $t['Internet'] = '1.1.1.1'
        $series = Measure-PingSeries -Targets $t -DurationSec 5 -Ctx $Ctx -ProgressFrom 45 -ProgressTo 75
        $inet = Get-PingStats ([int[]]$series['Internet'].ToArray())
        if ($inet.NoReply) {
            Add-DiagItem $s 'Internet' 'Pas de réponse' 'Crit'
            Add-Alert 'Crit' 'Réseau' 'Internet ne répond pas (1.1.1.1).'
        } else {
            $st = if ($inet.LossPct -ge 5) { 'Crit' } elseif ($inet.LossPct -gt 0 -or $inet.Jitter -gt 5) { 'Warn' } else { 'OK' }
            Add-DiagItem $s 'Ping Internet' ('{0} ms' -f $inet.Avg) $st ('gigue {0} ms · pertes {1} %' -f $inet.Jitter, $inet.LossPct)
            if ($st -ne 'OK') { Add-Alert $st 'Réseau' "Pertes ou gigue sur la ligne (pertes $($inet.LossPct) %, gigue $($inet.Jitter) ms)." }
        }

        Update-DiagProgress $Ctx 78 'Audio…'
        $def = Get-DefaultAudioEndpoint 'Render'
        if ($def) {
            $info = Get-AudioDeviceInfo $def.EndpointId
            Add-DiagItem $s 'Sortie audio' $def.Device $(if ($info -and $info.Status -ne 'OK') { 'Crit' } else { 'OK' }) ("$($def.Name) · $($info.Type)").Trim(' ·')
        } else { Add-DiagItem $s 'Sortie audio' 'Aucune' 'Warn' 'Aucun périphérique de sortie par défaut' }

        Update-DiagProgress $Ctx 85 'Journaux (24 h)…'
        $crit = @(Get-EventsSafe @{ LogName = 'System'; Level = 1; StartTime = (Get-Date).AddDays(-1) })
        $whea = @(Get-EventsSafe @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = (Get-Date).AddDays(-7) })
        Add-DiagItem $s 'Événements critiques 24 h' $crit.Count $(if ($crit.Count) { 'Crit' } else { 'OK' })
        if ($crit.Count) { Add-Alert 'Crit' 'Stabilité' "$($crit.Count) événement(s) critique(s) en 24 h (arrêt inattendu, écran bleu…)." }
        if ($whea.Count) { Add-Alert 'Crit' 'Matériel' "$($whea.Count) erreur(s) matérielle(s) WHEA sur 7 jours." }
        if (Test-PendingReboot) { Add-Alert 'Warn' 'Mises à jour' 'Un redémarrage est en attente pour terminer des mises à jour.' }

        $ver = $cv.DisplayVersion
        $eos = Get-WindowsSupportEnd $ver   # liste unique, tenue dans WindowsAnalysis.psm1
        if ($eos -and (Get-Date) -gt $eos) { Add-Alert 'Crit' 'Windows' "La version $ver n'est plus prise en charge : plus de correctifs de sécurité." }

        Add-DiagItem $s 'Mode' $(if (Test-IsAdmin) { 'Administrateur' } else { 'Standard' }) 'Info' 'Lecture seule dans les deux cas'
    }

    Update-DiagProgress $Ctx 95 'Synthèse…'
    Add-DiagSection $r 'Points d''attention' -Body {
        param($s)
        if ($alerts.Count -eq 0) { Add-DiagItem $s 'Aucun point d''attention' 'Tout semble en ordre sur les vérifications rapides.' 'OK' }
        foreach ($a in $alerts | Sort-Object { if ($_.Status -eq 'Crit') { 0 } else { 1 } }) { Add-DiagItem $s $a.Label $a.Text $a.Status }
        Add-DiagNote $s 'Vérification rapide. Lancez les modules dédiés pour une analyse complète.'
    }

    Update-DiagProgress $Ctx 100 'Terminé'
    $r
}

Export-ModuleMember -Function Invoke-DashboardDiagnostic
