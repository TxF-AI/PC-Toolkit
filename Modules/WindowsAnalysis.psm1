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
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'; Scope = (Get-Text 'Win.001') },
        @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'; Scope = (Get-Text 'Win.002') },
        @{ Path = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'; Scope = (Get-Text 'Win.003') }
    )
    foreach ($src in $sources) {
        $props = Get-ItemProperty $src.Path -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        $appr = Get-ItemProperty $src.Approved -ErrorAction SilentlyContinue
        foreach ($p in $props.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' }) {
            $bytes = $appr.($p.Name)
            $enabled = -not ($bytes -and ($bytes[0] -band 1))
            $out += [pscustomobject]@{ Nom = $p.Name; État = $(if ($enabled) { (Get-Text 'Win.004') } else { (Get-Text 'Win.005') }); Portée = $src.Scope; Commande = "$($p.Value)" }
        }
    }
    $folders = @(
        @{ Path = [Environment]::GetFolderPath('Startup'); Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'; Scope = (Get-Text 'Win.007') },
        @{ Path = [Environment]::GetFolderPath('CommonStartup'); Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'; Scope = (Get-Text 'Win.009') }
    )
    foreach ($f in $folders) {
        $appr = Get-ItemProperty $f.Approved -ErrorAction SilentlyContinue
        foreach ($file in Get-ChildItem -LiteralPath $f.Path -File -ErrorAction SilentlyContinue | Where-Object Name -ne 'desktop.ini') {
            $bytes = $appr.($file.Name)
            $enabled = -not ($bytes -and ($bytes[0] -band 1))
            $out += [pscustomobject]@{ Nom = $file.BaseName; État = $(if ($enabled) { (Get-Text 'Win.010') } else { (Get-Text 'Win.011') }); Portée = $f.Scope; Commande = $file.FullName }
        }
    }
    $out
}

function Invoke-WindowsDiagnostic {
    param($Ctx, [int]$Days = 7)
    $r = New-DiagResult -Module 'Windows' -Title (Get-Text 'Win.013') -Ctx $Ctx
    $since = (Get-Date).AddDays(-$Days)

    # --- Système ---------------------------------------------------------------
    Update-DiagProgress $Ctx 5 (Get-Text 'Win.014')
    Add-DiagSection $r (Get-Text 'Win.015') -Body {
        param($s)
        $os = Get-SafeCim Win32_OperatingSystem
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $ver = $cv.DisplayVersion
        Add-DiagItem $s (Get-Text 'Win.016') ((Get-Text 'Win.017') -f ($os.Caption -replace (Get-Text 'Win.018'), ''), $ver, $cv.CurrentBuild, $cv.UBR)
        if ($script:Win11EndOfService.ContainsKey($ver)) {
            $eos = $script:Win11EndOfService[$ver]
            $left = ($eos - (Get-Date)).TotalDays
            $st = if ($left -lt 0) { 'Crit' } elseif ($left -lt 120) { 'Warn' } else { 'OK' }
            $txt = if ($left -lt 0) { (Get-Text 'Win.019' $($eos.ToString('dd/MM/yyyy'))) } else { (Get-Text 'Win.020' $($eos.ToString('dd/MM/yyyy'))) }
            Add-DiagItem $s (Get-Text 'Win.021') $txt $st $(if ($left -lt 120) { (Get-Text 'Win.022') } else { '' })
        }
        $up = (Get-Date) - $os.LastBootUpTime
        Add-DiagItem $s (Get-Text 'Win.023') ((Get-Text 'Win.024') -f $os.LastBootUpTime, (Format-Span $up)) $(if ($up.TotalDays -gt 7) { 'Warn' } else { 'OK' }) $(if ($up.TotalDays -gt 7) { (Get-Text 'Win.025') } else { '' })
        $pend = Test-PendingReboot
        Add-DiagItem $s (Get-Text 'Win.026') $(if ($pend) { 'Oui' } else { 'Non' }) $(if ($pend) { 'Warn' } else { 'OK' })
        $hf = Get-HotFix -ErrorAction SilentlyContinue | Where-Object InstalledOn | Sort-Object InstalledOn -Descending | Select-Object -First 1
        if ($hf) {
            $age = ((Get-Date) - $hf.InstalledOn).TotalDays
            Add-DiagItem $s (Get-Text 'Win.027') ((Get-Text 'Win.028') -f $hf.HotFixID, $hf.InstalledOn) $(if ($age -gt 45) { 'Warn' } else { 'OK' })
        }
        $fs = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction SilentlyContinue).HiberbootEnabled
        Add-DiagItem $s (Get-Text 'Win.029') $(if ($fs -eq 1) { (Get-Text 'Win.030') } else { (Get-Text 'Win.031') }) 'Info' (Get-Text 'Win.032')
    }

    # --- Stabilité ---------------------------------------------------------------
    Update-DiagProgress $Ctx 20 (Get-Text 'Win.033')
    $period = if ($Days -eq 1) { (Get-Text 'Win.034') } else { (Get-Text 'Win.035' $Days) }
    Add-DiagSection $r (Get-Text 'Win.036' $period) -Body {
        param($s)
        $kp = Get-EventsSafe @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $since }
        $bc = Get-EventsSafe @{ LogName = 'System'; Id = 1001; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; StartTime = $since }
        $whea = Get-EventsSafe @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = $since }
        $disk = Get-EventsSafe @{ LogName = 'System'; ProviderName = 'disk', 'Ntfs', 'stornvme', 'storahci'; Level = 1, 2, 3; StartTime = $since }
        $usb = Get-EventsSafe @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-PnP'; Id = 219; StartTime = $since }

        Add-DiagItem $s (Get-Text 'Win.046') $kp.Count $(if ($kp.Count -ge 2) { 'Crit' } elseif ($kp.Count -eq 1) { 'Warn' } else { 'OK' }) (Get-Text 'Win.047')
        Add-DiagItem $s (Get-Text 'Win.048') $bc.Count $(if ($bc.Count) { 'Crit' } else { 'OK' })
        Add-DiagItem $s (Get-Text 'Win.049') $whea.Count $(if ($whea.Count) { 'Crit' } else { 'OK' }) (Get-Text 'Win.050')
        Add-DiagItem $s (Get-Text 'Win.051') $disk.Count $(if ($disk.Count -ge 5) { 'Crit' } elseif ($disk.Count) { 'Warn' } else { 'OK' })
        Add-DiagItem $s (Get-Text 'Win.052') $usb.Count $(if ($usb.Count -ge 5) { 'Warn' } else { 'Info' })

        $crit = (@($kp) + @($bc) + @($whea)) | Sort-Object TimeCreated -Descending | Select-Object -First 15 |
            ForEach-Object { [pscustomobject]@{ Date = $_.TimeCreated.ToString('dd/MM HH:mm'); Source = ($_.ProviderName -replace 'Microsoft-Windows-', ''); ID = $_.Id; Message = (("$($_.Message)" -split "`n")[0]).Trim() } }
        if ($crit) { Add-DiagTable $s (Get-Text 'Win.054') $crit }

        $rel = Get-SafeCim Win32_ReliabilityStabilityMetrics | Sort-Object TimeGenerated -Descending | Select-Object -First 1
        if ($rel) { Add-DiagItem $s (Get-Text 'Win.055') ('{0:N1} / 10' -f $rel.SystemStabilityIndex) $(if ($rel.SystemStabilityIndex -lt 5) { 'Warn' } else { 'OK' }) }
    }

    # --- Journaux ---------------------------------------------------------------
    Update-DiagProgress $Ctx 40 (Get-Text 'Win.056')
    Add-DiagSection $r (Get-Text 'Win.057') -Body {
        param($s)
        $sys = Get-EventsSafe @{ LogName = 'System'; Level = 1, 2; StartTime = $since }
        $app = Get-EventsSafe @{ LogName = 'Application'; Level = 1, 2; StartTime = $since }
        Add-DiagItem $s (Get-Text 'Win.060') $sys.Count $(if ($sys.Count -gt 100) { 'Warn' } else { 'Info' })
        Add-DiagItem $s (Get-Text 'Win.061') $app.Count $(if ($app.Count -gt 100) { 'Warn' } else { 'Info' })
        $grp = $sys | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 10 |
            ForEach-Object { $l = $_.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1; [pscustomobject]@{ Source = $_.Name; Nombre = $_.Count; Dernière = $l.TimeCreated.ToString('dd/MM HH:mm'); 'Dernier message' = (("$($l.Message)" -split "`n")[0]).Trim() } }
        Add-DiagTable $s (Get-Text 'Win.063') $grp
        # Plantages d'applications (Application Error 1000 / Application Hang 1002)
        $crash = $app | Where-Object { $_.Id -in 1000, 1002 -and $_.ProviderName -in 'Application Error', 'Application Hang' }
        $cg = $crash | Group-Object { "$($_.Properties[0].Value)" } | Sort-Object Count -Descending | Select-Object -First 10 |
            ForEach-Object { [pscustomobject]@{ Application = $_.Name; Plantages = @($_.Group | Where-Object Id -eq 1000).Count; Blocages = @($_.Group | Where-Object Id -eq 1002).Count; Dernier = ($_.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated.ToString('dd/MM HH:mm') } }
        Add-DiagItem $s (Get-Text 'Win.067') @($crash).Count $(if (@($crash).Count -ge 5) { 'Warn' } else { 'Info' })
        if ($cg) { Add-DiagTable $s (Get-Text 'Win.068') $cg }
        Add-DiagNote $s (Get-Text 'Win.069')
    }

    # --- Services ---------------------------------------------------------------
    Update-DiagProgress $Ctx 65 (Get-Text 'Win.070')
    Add-DiagSection $r (Get-Text 'Win.071') -Body {
        param($s)
        $svc = @(Get-SafeCim Win32_Service)
        $stopped = $svc | Where-Object { $_.StartMode -eq 'Auto' -and $_.State -ne 'Running' -and $_.ExitCode -ne 0 }
        Add-DiagItem $s (Get-Text 'Win.074') @($stopped).Count $(if (@($stopped).Count) { 'Warn' } else { 'OK' }) (Get-Text 'Win.075')
        if ($stopped) { Add-DiagTable $s (Get-Text 'Win.076') ($stopped | ForEach-Object { [pscustomobject]@{ Nom = $_.Name; 'Nom affiché' = $_.DisplayName; 'Code de sortie' = $_.ExitCode } }) }
        $third = $svc | Where-Object { $_.State -eq 'Running' -and $_.PathName -and $_.PathName -notmatch '(?i)\\Windows\\(system32|SysWOW64|Microsoft\.NET|servicing)|\\Windows Defender\\|\\Microsoft\\' } | Sort-Object DisplayName
        Add-DiagItem $s (Get-Text 'Win.078') @($third).Count 'Info'
        Add-DiagTable $s (Get-Text 'Win.079') ($third | ForEach-Object { [pscustomobject]@{ 'Nom affiché' = $_.DisplayName; Démarrage = $_.StartMode; Chemin = ($_.PathName -replace '"', '') } })
        Add-DiagNote $s (Get-Text 'Win.080')
    }

    # --- Démarrage ---------------------------------------------------------------
    Update-DiagProgress $Ctx 80 (Get-Text 'Win.081')
    Add-DiagSection $r (Get-Text 'Win.082') -Body {
        param($s)
        $st = @(Get-StartupEntries)
        $en = @($st | Where-Object État -eq (Get-Text 'Win.083'))
        Add-DiagItem $s (Get-Text 'Win.084') ((Get-Text 'Win.085') -f $en.Count, ($st.Count - $en.Count)) $(if ($en.Count -gt 12) { 'Warn' } else { 'OK' })
        Add-DiagTable $s (Get-Text 'Win.086') ($st | Sort-Object État, Nom)
        try {
            $tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.State -ne 'Disabled' -and $_.TaskPath -notlike '\Microsoft\*' -and ($_.Triggers | Where-Object { $_.CimClass.CimClassName -in 'MSFT_TaskLogonTrigger', 'MSFT_TaskBootTrigger' }) })
            Add-DiagItem $s (Get-Text 'Win.088') $tasks.Count 'Info'
            if ($tasks) { Add-DiagTable $s (Get-Text 'Win.089') ($tasks | ForEach-Object { [pscustomobject]@{ Tâche = $_.TaskName; Dossier = $_.TaskPath; État = "$($_.State)" } }) }
        } catch { }
        $bp = Get-EventsSafe @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } 1
        if ($bp) { Add-DiagItem $s (Get-Text 'Win.090') ('{0:N1} s' -f ([double]$bp[0].Properties[5].Value / 1000)) 'Info' }
    }

    # --- Sécurité ---------------------------------------------------------------
    Update-DiagProgress $Ctx 92 (Get-Text 'Win.091')
    Add-DiagSection $r (Get-Text 'Win.092') -Body {
        param($s)
        $av = @(Get-SafeCim -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct)
        foreach ($a in $av) {
            $hex = '{0:X6}' -f [int]$a.productState
            $on = $hex.Substring(2, 2) -in '10', '11'
            $upd = $hex.Substring(4, 2) -eq '00'
            Add-DiagItem $s ((Get-Text 'Win.093') -f $a.displayName) ('{0} · {1}' -f $(if ($on) { (Get-Text 'Win.094') } else { (Get-Text 'Win.095') }), $(if ($upd) { (Get-Text 'Win.096') } else { (Get-Text 'Win.097') })) $(if ($on -and $upd) { 'OK' } elseif ($on) { 'Warn' } else { 'Info' })
        }
        if (-not $av) { Add-DiagItem $s (Get-Text 'Win.098') (Get-Text 'Win.099') 'Crit' }
        $fw = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue)
        if ($fw) { Add-DiagItem $s (Get-Text 'Win.100') (($fw | ForEach-Object { '{0} : {1}' -f $_.Name, $(if ($_.Enabled) { (Get-Text 'Win.101') } else { (Get-Text 'Win.102') }) }) -join ' · ') $(if (@($fw | Where-Object { -not $_.Enabled }).Count) { 'Warn' } else { 'OK' }) }
        $uac = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue).EnableLUA
        Add-DiagItem $s (Get-Text 'Win.103') $(if ($uac -eq 1) { (Get-Text 'Win.104') } else { (Get-Text 'Win.105') }) $(if ($uac -eq 1) { 'OK' } else { 'Crit' })
    }

    Update-DiagProgress $Ctx 100 (Get-Text 'Win.106')
    $r
}

Export-ModuleMember -Function Invoke-WindowsDiagnostic, Get-WindowsSupportEnd, Get-StartupEntries, Test-PendingReboot, Get-EventsSafe
