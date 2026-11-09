#requires -Version 5.1
<#
    WindowsAnalysis.psm1 — Analyse de Windows (lecture seule)
    Version et support, redémarrage en attente, journaux d'événements, plantages,
    services, programmes au démarrage, sécurité.
#>

# Fin de support des versions de Windows 11 (éditions Famille/Pro), source : cycle de vie Microsoft
$script:Win11EndOfService = @{
    '21H2' = [datetime]'2023-10-10'; '22H2' = [datetime]'2024-10-08'; '23H2' = [datetime]'2025-11-11'
    '24H2' = [datetime]'2026-10-13'; '25H2' = [datetime]'2027-10-12'
}

function Get-WindowsSupportEnd {
    <#
        Date de fin de support d'une version de Windows 11 (ex. « 23H2 »), ou $null si inconnue.
        Source unique utilisée par la page Windows ET le tableau de bord : à mettre à jour ici seulement.
    #>
    param([string]$Version)
    if ($Version -and $script:Win11EndOfService.ContainsKey($Version)) { $script:Win11EndOfService[$Version] } else { $null }
}

function Get-EventsSafe {
    <# Get-WinEvent qui renvoie un tableau vide quand aucun événement ne correspond. #>
    param([hashtable]$Filter, [int]$Max = 3000)
    try { @(Get-WinEvent -FilterHashtable $Filter -MaxEvents $Max -ErrorAction Stop) } catch { @() }
}

function Test-PendingReboot {
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    foreach ($k in $keys) { if (Test-Path $k) { return $true } }
    $false
}

function Get-StartupEntries {
    <# Programmes lancés au démarrage (clés Run + dossiers Démarrage) avec leur état dans le Gestionnaire des tâches. #>
    $out = @()
    $sources = @(
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'; Scope = 'Utilisateur' },
        @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'; Scope = 'Tous' },
        @{ Path = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'; Scope = 'Tous (32 bits)' }
    )
    foreach ($src in $sources) {
        $props = Get-ItemProperty $src.Path -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        $appr = Get-ItemProperty $src.Approved -ErrorAction SilentlyContinue
        foreach ($p in $props.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' }) {
            $bytes = $appr.($p.Name)
            $enabled = -not ($bytes -and ($bytes[0] -band 1))
            $out += [pscustomobject]@{ Nom = $p.Name; État = $(if ($enabled) { 'Activé' } else { 'Désactivé' }); Portée = $src.Scope; Commande = "$($p.Value)" }
        }
    }
    $folders = @(
        @{ Path = [Environment]::GetFolderPath('Startup'); Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'; Scope = 'Utilisateur (dossier)' },
        @{ Path = [Environment]::GetFolderPath('CommonStartup'); Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'; Scope = 'Tous (dossier)' }
    )
    foreach ($f in $folders) {
        $appr = Get-ItemProperty $f.Approved -ErrorAction SilentlyContinue
        foreach ($file in Get-ChildItem -LiteralPath $f.Path -File -ErrorAction SilentlyContinue | Where-Object Name -ne 'desktop.ini') {
            $bytes = $appr.($file.Name)
            $enabled = -not ($bytes -and ($bytes[0] -band 1))
            $out += [pscustomobject]@{ Nom = $file.BaseName; État = $(if ($enabled) { 'Activé' } else { 'Désactivé' }); Portée = $f.Scope; Commande = $file.FullName }
        }
    }
    $out
}

function Invoke-WindowsDiagnostic {
    param($Ctx, [int]$Days = 7)
    $r = New-DiagResult -Module 'Windows' -Title 'Analyse Windows' -Ctx $Ctx
    $since = (Get-Date).AddDays(-$Days)

    # --- Système ---------------------------------------------------------------
    Update-DiagProgress $Ctx 5 'Lecture de la version de Windows…'
    Add-DiagSection $r 'Système' -Body {
        param($s)
        $os = Get-SafeCim Win32_OperatingSystem
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $ver = $cv.DisplayVersion
        Add-DiagItem $s 'Édition' ('{0} {1} (build {2}.{3})' -f ($os.Caption -replace 'Microsoft ', ''), $ver, $cv.CurrentBuild, $cv.UBR)
        if ($script:Win11EndOfService.ContainsKey($ver)) {
            $eos = $script:Win11EndOfService[$ver]
            $left = ($eos - (Get-Date)).TotalDays
            $st = if ($left -lt 0) { 'Crit' } elseif ($left -lt 120) { 'Warn' } else { 'OK' }
            $txt = if ($left -lt 0) { "Plus prise en charge depuis le $($eos.ToString('dd/MM/yyyy'))" } else { "Prise en charge jusqu'au $($eos.ToString('dd/MM/yyyy'))" }
            Add-DiagItem $s 'Support de la version' $txt $st $(if ($left -lt 120) { 'Une version non prise en charge ne reçoit plus de correctifs de sécurité. Mise à jour via Paramètres > Windows Update.' } else { '' })
        }
        $up = (Get-Date) - $os.LastBootUpTime
        Add-DiagItem $s 'Dernier démarrage' ('{0:dd/MM/yyyy HH:mm} (il y a {1})' -f $os.LastBootUpTime, (Format-Span $up)) $(if ($up.TotalDays -gt 7) { 'Warn' } else { 'OK' }) $(if ($up.TotalDays -gt 7) { 'Pas de redémarrage complet depuis plus de 7 jours (le « démarrage rapide » ne compte pas comme un redémarrage).' } else { '' })
        $pend = Test-PendingReboot
        Add-DiagItem $s 'Redémarrage en attente' $(if ($pend) { 'Oui' } else { 'Non' }) $(if ($pend) { 'Warn' } else { 'OK' })
        $hf = Get-HotFix -ErrorAction SilentlyContinue | Where-Object InstalledOn | Sort-Object InstalledOn -Descending | Select-Object -First 1
        if ($hf) {
            $age = ((Get-Date) - $hf.InstalledOn).TotalDays
            Add-DiagItem $s 'Dernière mise à jour installée' ('{0} le {1:dd/MM/yyyy}' -f $hf.HotFixID, $hf.InstalledOn) $(if ($age -gt 45) { 'Warn' } else { 'OK' })
        }
        $fs = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction SilentlyContinue).HiberbootEnabled
        Add-DiagItem $s 'Démarrage rapide' $(if ($fs -eq 1) { 'Activé' } else { 'Désactivé' }) 'Info' 'Quand il est activé, « Arrêter » ne réinitialise pas complètement les pilotes : préférez « Redémarrer » après un souci matériel.'
    }

    # --- Stabilité ---------------------------------------------------------------
    Update-DiagProgress $Ctx 20 'Analyse des journaux système…'
    $period = if ($Days -eq 1) { 'dernières 24 h' } else { "$Days derniers jours" }
    Add-DiagSection $r "Stabilité ($period)" -Body {
        param($s)
        $kp = Get-EventsSafe @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $since }
        $bc = Get-EventsSafe @{ LogName = 'System'; Id = 1001; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; StartTime = $since }
        $whea = Get-EventsSafe @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = $since }
        $disk = Get-EventsSafe @{ LogName = 'System'; ProviderName = 'disk', 'Ntfs', 'stornvme', 'storahci'; Level = 1, 2, 3; StartTime = $since }
        $usb = Get-EventsSafe @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-PnP'; Id = 219; StartTime = $since }

        Add-DiagItem $s 'Arrêts inattendus (Kernel-Power 41)' $kp.Count $(if ($kp.Count -ge 2) { 'Crit' } elseif ($kp.Count -eq 1) { 'Warn' } else { 'OK' }) 'Coupure, appui long sur le bouton d''alimentation ou blocage complet du PC.'
        Add-DiagItem $s 'Écrans bleus (BugCheck)' $bc.Count $(if ($bc.Count) { 'Crit' } else { 'OK' })
        Add-DiagItem $s 'Erreurs matérielles (WHEA)' $whea.Count $(if ($whea.Count) { 'Crit' } else { 'OK' }) 'Erreurs signalées par le CPU, la mémoire ou le bus PCIe : souvent liées à l''overclocking, au XMP ou au BIOS.'
        Add-DiagItem $s 'Alertes disque / NTFS' $disk.Count $(if ($disk.Count -ge 5) { 'Crit' } elseif ($disk.Count) { 'Warn' } else { 'OK' })
        Add-DiagItem $s 'Pilotes non chargés (PnP 219)' $usb.Count $(if ($usb.Count -ge 5) { 'Warn' } else { 'Info' })

        $crit = (@($kp) + @($bc) + @($whea)) | Sort-Object TimeCreated -Descending | Select-Object -First 15 |
            ForEach-Object { [pscustomobject]@{ Date = $_.TimeCreated.ToString('dd/MM HH:mm'); Source = ($_.ProviderName -replace 'Microsoft-Windows-', ''); ID = $_.Id; Message = (("$($_.Message)" -split "`n")[0]).Trim() } }
        if ($crit) { Add-DiagTable $s 'Derniers événements critiques' $crit }

        $rel = Get-SafeCim Win32_ReliabilityStabilityMetrics | Sort-Object TimeGenerated -Descending | Select-Object -First 1
        if ($rel) { Add-DiagItem $s 'Indice de fiabilité Windows' ('{0:N1} / 10' -f $rel.SystemStabilityIndex) $(if ($rel.SystemStabilityIndex -lt 5) { 'Warn' } else { 'OK' }) }
    }

    # --- Journaux ---------------------------------------------------------------
    Update-DiagProgress $Ctx 40 'Regroupement des erreurs…'
    Add-DiagSection $r 'Erreurs des journaux' -Body {
        param($s)
        $sys = Get-EventsSafe @{ LogName = 'System'; Level = 1, 2; StartTime = $since }
        $app = Get-EventsSafe @{ LogName = 'Application'; Level = 1, 2; StartTime = $since }
        Add-DiagItem $s 'Erreurs Système' $sys.Count $(if ($sys.Count -gt 100) { 'Warn' } else { 'Info' })
        Add-DiagItem $s 'Erreurs Application' $app.Count $(if ($app.Count -gt 100) { 'Warn' } else { 'Info' })
        $grp = $sys | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 10 |
            ForEach-Object { $l = $_.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1; [pscustomobject]@{ Source = $_.Name; Nombre = $_.Count; Dernière = $l.TimeCreated.ToString('dd/MM HH:mm'); 'Dernier message' = (("$($l.Message)" -split "`n")[0]).Trim() } }
        Add-DiagTable $s 'Sources d''erreurs système les plus fréquentes' $grp
        # Plantages d'applications (Application Error 1000 / Application Hang 1002)
        $crash = $app | Where-Object { $_.Id -in 1000, 1002 -and $_.ProviderName -in 'Application Error', 'Application Hang' }
        $cg = $crash | Group-Object { "$($_.Properties[0].Value)" } | Sort-Object Count -Descending | Select-Object -First 10 |
            ForEach-Object { [pscustomobject]@{ Application = $_.Name; Plantages = @($_.Group | Where-Object Id -eq 1000).Count; Blocages = @($_.Group | Where-Object Id -eq 1002).Count; Dernier = ($_.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated.ToString('dd/MM HH:mm') } }
        Add-DiagItem $s 'Applications plantées / bloquées' @($crash).Count $(if (@($crash).Count -ge 5) { 'Warn' } else { 'Info' })
        if ($cg) { Add-DiagTable $s 'Applications concernées' $cg }
        Add-DiagNote $s 'Beaucoup d''erreurs Windows sont bénignes et récurrentes : c''est leur répétition ou leur coïncidence avec un problème ressenti qui compte.'
    }

    # --- Services ---------------------------------------------------------------
    Update-DiagProgress $Ctx 65 'Analyse des services…'
    Add-DiagSection $r 'Services' -Body {
        param($s)
        $svc = @(Get-SafeCim Win32_Service)
        $stopped = $svc | Where-Object { $_.StartMode -eq 'Auto' -and $_.State -ne 'Running' -and $_.ExitCode -ne 0 }
        Add-DiagItem $s 'Services en échec au démarrage' @($stopped).Count $(if (@($stopped).Count) { 'Warn' } else { 'OK' }) 'Services automatiques arrêtés avec un code d''erreur (les arrêts normaux sont ignorés).'
        if ($stopped) { Add-DiagTable $s 'Services automatiques en échec' ($stopped | ForEach-Object { [pscustomobject]@{ Nom = $_.Name; 'Nom affiché' = $_.DisplayName; 'Code de sortie' = $_.ExitCode } }) }
        $third = $svc | Where-Object { $_.State -eq 'Running' -and $_.PathName -and $_.PathName -notmatch '(?i)\\Windows\\(system32|SysWOW64|Microsoft\.NET|servicing)|\\Windows Defender\\|\\Microsoft\\' } | Sort-Object DisplayName
        Add-DiagItem $s 'Services tiers en cours d''exécution' @($third).Count 'Info'
        Add-DiagTable $s 'Services tiers actifs (non Microsoft)' ($third | ForEach-Object { [pscustomobject]@{ 'Nom affiché' = $_.DisplayName; Démarrage = $_.StartMode; Chemin = ($_.PathName -replace '"', '') } })
        Add-DiagNote $s 'Lecture seule : aucun service n''est modifié. Ne désactivez un service que si vous savez à quoi il sert.'
    }

    # --- Démarrage ---------------------------------------------------------------
    Update-DiagProgress $Ctx 80 'Programmes au démarrage…'
    Add-DiagSection $r 'Démarrage' -Body {
        param($s)
        $st = @(Get-StartupEntries)
        $en = @($st | Where-Object État -eq 'Activé')
        Add-DiagItem $s 'Programmes au démarrage' ('{0} activé(s), {1} désactivé(s)' -f $en.Count, ($st.Count - $en.Count)) $(if ($en.Count -gt 12) { 'Warn' } else { 'OK' })
        Add-DiagTable $s 'Entrées de démarrage' ($st | Sort-Object État, Nom)
        try {
            $tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.State -ne 'Disabled' -and $_.TaskPath -notlike '\Microsoft\*' -and ($_.Triggers | Where-Object { $_.CimClass.CimClassName -in 'MSFT_TaskLogonTrigger', 'MSFT_TaskBootTrigger' }) })
            Add-DiagItem $s 'Tâches planifiées à l''ouverture de session' $tasks.Count 'Info'
            if ($tasks) { Add-DiagTable $s 'Tâches planifiées tierces (ouverture de session / démarrage)' ($tasks | ForEach-Object { [pscustomobject]@{ Tâche = $_.TaskName; Dossier = $_.TaskPath; État = "$($_.State)" } }) }
        } catch { }
        $bp = Get-EventsSafe @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } 1
        if ($bp) { Add-DiagItem $s 'Durée du dernier démarrage' ('{0:N1} s' -f ([double]$bp[0].Properties[5].Value / 1000)) 'Info' }
    }

    # --- Sécurité ---------------------------------------------------------------
    Update-DiagProgress $Ctx 92 'État de la sécurité…'
    Add-DiagSection $r 'Sécurité' -Body {
        param($s)
        $av = @(Get-SafeCim -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct)
        foreach ($a in $av) {
            $hex = '{0:X6}' -f [int]$a.productState
            $on = $hex.Substring(2, 2) -in '10', '11'
            $upd = $hex.Substring(4, 2) -eq '00'
            Add-DiagItem $s ("Antivirus : {0}" -f $a.displayName) ('{0} · {1}' -f $(if ($on) { 'actif' } else { 'inactif' }), $(if ($upd) { 'à jour' } else { 'signatures anciennes' })) $(if ($on -and $upd) { 'OK' } elseif ($on) { 'Warn' } else { 'Info' })
        }
        if (-not $av) { Add-DiagItem $s 'Antivirus' 'Aucun antivirus déclaré' 'Crit' }
        $fw = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue)
        if ($fw) { Add-DiagItem $s 'Pare-feu Windows' (($fw | ForEach-Object { '{0} : {1}' -f $_.Name, $(if ($_.Enabled) { 'actif' } else { 'inactif' }) }) -join ' · ') $(if (@($fw | Where-Object { -not $_.Enabled }).Count) { 'Warn' } else { 'OK' }) }
        $uac = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue).EnableLUA
        Add-DiagItem $s 'Contrôle de compte (UAC)' $(if ($uac -eq 1) { 'Activé' } else { 'Désactivé' }) $(if ($uac -eq 1) { 'OK' } else { 'Crit' })
    }

    Update-DiagProgress $Ctx 100 'Terminé'
    $r
}

Export-ModuleMember -Function Invoke-WindowsDiagnostic, Get-WindowsSupportEnd, Get-StartupEntries, Test-PendingReboot, Get-EventsSafe
