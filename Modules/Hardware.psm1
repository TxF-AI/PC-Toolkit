#requires -Version 5.1
<#
    Hardware.psm1 — Diagnostic matériel (lecture seule)
    CPU, RAM, GPU, carte mère/BIOS, températures.
    Règle : une température n'est affichée que si un capteur la fournit réellement.
#>

function Get-CpuLoadSample {
    <# Moyenne de la charge CPU sur N échantillons d'une seconde (compteurs WMI, indépendants de la langue). #>
    param([int]$Samples = 3)
    $v = @()
    for ($i = 0; $i -lt $Samples; $i++) {
        $p = Get-SafeCim -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'"
        if ($p) { $v += [double]$p.PercentProcessorTime }
        Start-Sleep -Milliseconds 900
    }
    if ($v.Count) { [math]::Round(($v | Measure-Object -Average).Average, 0) } else { $null }
}

function Get-GpuVramBytes {
    <# Win32_VideoController plafonne la VRAM à 4 Go : on lit la vraie valeur dans le registre du pilote. #>
    param([string]$GpuName)
    $base = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    foreach ($k in Get-ChildItem $base -ErrorAction SilentlyContinue | Where-Object PSChildName -match '^\d{4}$') {
        $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
        if ($p.DriverDesc -eq $GpuName -and $p.'HardwareInformation.qwMemorySize') { return [double]$p.'HardwareInformation.qwMemorySize' }
    }
    $null
}

function Invoke-HardwareDiagnostic {
    param($Ctx)
    $r = New-DiagResult -Module 'Hardware' -Title 'Diagnostic matériel' -Ctx $Ctx

    # --- Processeur ---------------------------------------------------------------
    Update-DiagProgress $Ctx 5 'Lecture du processeur…'
    Add-DiagSection $r 'Processeur' -Body {
        param($s)
        $cpu = Get-SafeCim Win32_Processor | Select-Object -First 1
        Add-DiagItem $s 'Modèle' ($cpu.Name.Trim())
        Add-DiagItem $s 'Cœurs / threads' ('{0} cœurs · {1} threads' -f $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors)
        Add-DiagItem $s 'Fréquence de base' ('{0:N2} GHz' -f ($cpu.MaxClockSpeed / 1000))
        Update-DiagProgress $Ctx 10 'Mesure de la charge CPU (3 s)…'
        $load = Get-CpuLoadSample 3
        $st = if ($null -eq $load) { 'NA' } elseif ($load -ge 90) { 'Crit' } elseif ($load -ge 70) { 'Warn' } else { 'OK' }
        Add-DiagItem $s 'Charge moyenne (3 s)' $(if ($null -ne $load) { "$load %" }) $st
        $perf = Get-SafeCim Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'"
        if ($perf -and $null -ne $perf.PercentProcessorPerformance) {
            $pp = [int]$perf.PercentProcessorPerformance
            Add-DiagItem $s 'Performance actuelle' ("$pp % de la fréquence de base") 'Info' 'Au-delà de 100 % = Turbo Boost actif. Une valeur très basse sous forte charge peut indiquer un bridage (thermique ou alimentation).'
        }
        $vt = if ($cpu.VirtualizationFirmwareEnabled) { 'Activée' } else { 'Désactivée ou utilisée par Hyper-V' }
        Add-DiagItem $s 'Virtualisation (BIOS)' $vt 'Info'
        $top = Get-Process -ErrorAction SilentlyContinue | Sort-Object CPU -Descending | Select-Object -First 8 |
            ForEach-Object { [pscustomobject]@{ Processus = $_.ProcessName; 'Temps CPU cumulé s' = [math]::Round($_.CPU, 0); 'Mémoire' = (Format-Bytes $_.WorkingSet64) } }
        Add-DiagTable $s 'Processus les plus gourmands en CPU (depuis leur lancement)' $top
    }

    # --- Mémoire -----------------------------------------------------------------
    Update-DiagProgress $Ctx 30 'Lecture de la mémoire…'
    Add-DiagSection $r 'Mémoire vive' -Body {
        param($s)
        $os = Get-SafeCim Win32_OperatingSystem
        $mods = @(Get-SafeCim Win32_PhysicalMemory)
        $total = ($mods | Measure-Object Capacity -Sum).Sum
        Add-DiagItem $s 'Capacité installée' ('{0} ({1} barrette(s))' -f (Format-Bytes $total), $mods.Count)
        $usedPct = [math]::Round((1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize) * 100, 0)
        $st = if ($usedPct -ge 90) { 'Crit' } elseif ($usedPct -ge 80) { 'Warn' } else { 'OK' }
        Add-DiagItem $s 'Utilisation actuelle' ('{0} % ({1} libres)' -f $usedPct, (Format-Bytes ($os.FreePhysicalMemory * 1KB))) $st
        $commit = Get-SafeCim Win32_PerfFormattedData_PerfOS_Memory
        if ($commit) { Add-DiagItem $s 'Mémoire engagée' ('{0} % de la limite' -f $commit.PercentCommittedBytesInUse) $(if ($commit.PercentCommittedBytesInUse -ge 85) { 'Warn' } else { 'OK' }) 'Inclut le fichier d''échange.' }

        $conf = ($mods | Measure-Object ConfiguredClockSpeed -Maximum).Maximum
        if ($conf) {
            $ddr = if (($mods | Select-Object -First 1).SMBIOSMemoryType -eq 34) { 'DDR5' } else { 'DDR4' }
            if ($ddr -eq 'DDR4' -and $conf -le 2666) {
                Add-DiagItem $s 'Fréquence effective' "$conf MT/s" 'Warn' 'Fréquence JEDEC par défaut : le profil XMP semble désactivé. Il s''active dans le BIOS (à faire après une mise à jour du BIOS).'
            } else { Add-DiagItem $s 'Fréquence effective' "$conf MT/s" 'OK' }
        }
        if ($mods.Count -eq 1) { Add-DiagItem $s 'Canaux' 'Une seule barrette : mode simple canal' 'Warn' 'Deux barrettes identiques (dual channel) offrent nettement plus de bande passante.' }
        elseif ($mods.Count -ge 2) { Add-DiagItem $s 'Canaux' "$($mods.Count) barrettes : dual channel probable" 'OK' 'Vérifiez qu''elles sont dans les slots recommandés par le manuel de la carte mère (souvent A2/B2).' }

        $rows = $mods | ForEach-Object { [pscustomobject]@{ Emplacement = $_.DeviceLocator; Capacité = (Format-Bytes $_.Capacity); 'Vitesse max SPD' = $_.Speed; 'Vitesse configurée' = $_.ConfiguredClockSpeed; Fabricant = $_.Manufacturer; Référence = ("$($_.PartNumber)").Trim() } }
        Add-DiagTable $s 'Barrettes' $rows
        $topMem = Get-Process -ErrorAction SilentlyContinue | Sort-Object WorkingSet64 -Descending | Select-Object -First 8 |
            ForEach-Object { [pscustomobject]@{ Processus = $_.ProcessName; Mémoire = (Format-Bytes $_.WorkingSet64) } }
        Add-DiagTable $s 'Processus les plus gourmands en mémoire' $topMem
    }

    # --- Carte graphique --------------------------------------------------------
    Update-DiagProgress $Ctx 50 'Lecture de la carte graphique…'
    Add-DiagSection $r 'Carte graphique' -Body {
        param($s)
        $all = @(Get-SafeCim Win32_VideoController)
        foreach ($v in $all | Where-Object Name -match 'Parsec|Virtual|Basic Display|Remote') {
            Add-DiagItem $s 'Adaptateur virtuel' $v.Name 'Info' 'Écran virtuel (bureau à distance, streaming) : pas une vraie carte graphique.'
        }
        foreach ($g in $all | Where-Object Name -notmatch 'Parsec|Virtual|Basic Display|Remote') {
            $vram = Get-GpuVramBytes $g.Name
            if (-not $vram -and $g.AdapterRAM) { $vram = [double][uint32]$g.AdapterRAM }
            $date = if ($g.DriverDate) { $g.DriverDate.ToString('dd/MM/yyyy') } else { '' }
            $age = if ($g.DriverDate) { ((Get-Date) - $g.DriverDate).TotalDays } else { 0 }
            Add-DiagItem $s $g.Name ('Pilote {0} du {1}' -f $g.DriverVersion, $date) $(if ($age -gt 365) { 'Warn' } else { 'OK' }) $(if ($age -gt 365) { 'Pilote de plus d''un an : une mise à jour depuis le site du fabricant (AMD, NVIDIA, Intel) est conseillée.' } else { '' })
            if ($vram) { Add-DiagItem $s '  Mémoire vidéo' (Format-Bytes $vram) }
            if ($g.CurrentHorizontalResolution) { Add-DiagItem $s '  Affichage principal' ('{0} × {1} à {2} Hz' -f $g.CurrentHorizontalResolution, $g.CurrentVerticalResolution, $g.CurrentRefreshRate) }
            if ($g.Status -ne 'OK') { Add-DiagItem $s '  État du périphérique' $g.Status 'Crit' }
        }
        # Charge GPU (compteurs Windows « GPU Engine », moteur 3D)
        $eng = @(Get-SafeCim Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine | Where-Object Name -match 'engtype_3D')
        if ($eng.Count) {
            $load = ($eng | Measure-Object UtilizationPercentage -Sum).Sum
            Add-DiagItem $s 'Charge 3D instantanée' ('{0} %' -f [math]::Min(100, $load)) 'Info'
        }
        # Réinitialisations du pilote graphique (TDR) sur 30 jours
        try {
            $tdr = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 4101; StartTime = (Get-Date).AddDays(-30) } -ErrorAction Stop)
            Add-DiagItem $s 'Plantages du pilote (TDR, 30 j)' $tdr.Count $(if ($tdr.Count -gt 0) { 'Warn' } else { 'OK' }) 'Événement 4101 : « le pilote d''affichage a cessé de répondre et a été récupéré ».'
        } catch { Add-DiagItem $s 'Plantages du pilote (TDR, 30 j)' 0 'OK' }
    }

    # --- Carte mère / BIOS ----------------------------------------------------
    Update-DiagProgress $Ctx 65 'Lecture carte mère et BIOS…'
    Add-DiagSection $r 'Carte mère et BIOS' -Body {
        param($s)
        $bb = Get-SafeCim Win32_BaseBoard
        $bios = Get-SafeCim Win32_BIOS
        Add-DiagItem $s 'Carte mère' ('{0} {1}' -f $bb.Manufacturer, $bb.Product)
        $bd = $bios.ReleaseDate
        $ageY = if ($bd) { [math]::Round(((Get-Date) - $bd).TotalDays / 365, 1) } else { $null }
        $st = if ($ageY -ge 2) { 'Warn' } else { 'OK' }
        Add-DiagItem $s 'Version du BIOS' ('{0} du {1:dd/MM/yyyy}' -f $bios.SMBIOSBIOSVersion, $bd) $st $(if ($ageY -ge 2) { "BIOS de $ageY ans : le fabricant de la carte mère publie sans doute des correctifs de stabilité (microcode, mémoire). À mettre à jour en suivant sa procédure officielle." } else { '' })
        try {
            $plan = (powercfg /getactivescheme) -replace '^.*\((.*)\)\s*$', '$1'
            Add-DiagItem $s 'Mode d''alimentation actif' $plan 'Info'
        } catch { }
        $sb = try { Confirm-SecureBootUEFI -ErrorAction Stop } catch { $null }
        Add-DiagItem $s 'Secure Boot' $(if ($null -eq $sb) { $null } elseif ($sb) { 'Activé' } else { 'Désactivé' }) 'Info' $(if ($null -eq $sb) { 'Lecture nécessitant les droits administrateur.' } else { '' })
    }

    # --- Températures ---------------------------------------------------------
    Update-DiagProgress $Ctx 80 'Recherche des capteurs de température…'
    Add-DiagSection $r 'Températures' -Body {
        param($s)
        $found = $false
        $cpuShort = ((Get-SafeCim Win32_Processor | Select-Object -First 1).Name -replace '\(R\)|\(TM\)|CPU|@.*$|\d+th Gen\s*', '' -replace '\s+', ' ').Trim()
        $gpuShort = (Get-SafeCim Win32_VideoController | Where-Object Name -notmatch 'Parsec|Virtual|Basic Display|Remote' | Select-Object -First 1).Name

        # 1) LibreHardwareMonitor / OpenHardwareMonitor, uniquement s'ils tournent déjà (aucune installation)
        foreach ($ns in 'root/LibreHardwareMonitor', 'root/OpenHardwareMonitor') {
            $sens = @(Get-SafeCim -Namespace $ns -ClassName Sensor | Where-Object SensorType -eq 'Temperature')
            if ($sens.Count) {
                $found = $true
                $rows = $sens | Sort-Object Parent, Name | ForEach-Object { [pscustomobject]@{ Capteur = $_.Name; Composant = $_.Parent; 'Valeur °C' = [math]::Round($_.Value, 1); 'Max °C' = [math]::Round($_.Max, 1) } }
                Add-DiagTable $s "Capteurs fournis par $($ns.Split('/')[1])" $rows
                $cpuT = $sens | Where-Object { $_.Parent -match 'cpu' -and $_.Name -match 'Package' } | Select-Object -First 1
                if ($cpuT) { Add-DiagItem $s 'CPU (package)' ('{0:N0} °C' -f $cpuT.Value) $(if ($cpuT.Value -ge 90) { 'Crit' } elseif ($cpuT.Value -ge 80) { 'Warn' } else { 'OK' }) }
            }
        }

        # 2) Zones thermiques ACPI exposées par la carte mère (pas forcément le CPU lui-même)
        $tz = @(Get-SafeCim Win32_PerfFormattedData_Counters_ThermalZoneInformation)
        foreach ($z in $tz) {
            $k = if ($z.HighPrecisionTemperature) { $z.HighPrecisionTemperature / 10 } else { $z.Temperature }
            if ($k -gt 200) {
                $found = $true
                $c = [math]::Round($k - 273.15, 1)
                Add-DiagItem $s ("Zone ACPI {0}" -f ($z.Name -replace '^.*\\', '')) "$c °C" $(if ($c -ge 90) { 'Warn' } else { 'Info' }) 'Capteur de la carte mère exposé par l''ACPI : ce n''est pas la température exacte des cœurs du CPU.'
            }
        }

        # 3) Température des disques (compteurs de fiabilité, droits admin requis)
        foreach ($d in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
            $rc = try { $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch { $null }
            if ($rc -and $rc.Temperature) {
                $found = $true
                Add-DiagItem $s ("Disque : {0}" -f $d.FriendlyName) ('{0} °C' -f $rc.Temperature) $(if ($rc.Temperature -ge 70) { 'Crit' } elseif ($rc.Temperature -ge 60) { 'Warn' } else { 'OK' })
            }
        }

        if (-not ($s.Items | Where-Object Label -eq 'CPU (package)')) {
            Add-DiagItem $s ('Température des cœurs CPU (' + $cpuShort + ')') $null 'NA' 'Windows n''expose pas les capteurs internes du processeur sans pilote tiers. Aucune valeur n''est estimée.'
        }
        Add-DiagItem $s ('Température GPU (' + $gpuShort + ')') $null 'NA' 'Non exposée par Windows. Consultable dans le logiciel du pilote (AMD Adrenalin, NVIDIA App…) ou le Gestionnaire des tâches > Performances.'
        if (-not (Test-IsAdmin)) { Add-DiagNote $s 'Mode standard : la température des disques nécessite les droits administrateur.' }
        Add-DiagNote $s 'Astuce : si LibreHardwareMonitor est lancé (en administrateur), ses capteurs apparaissent automatiquement ici. Rien n''est installé par PC Toolkit.'
    }

    Update-DiagProgress $Ctx 100 'Terminé'
    $r
}

Export-ModuleMember -Function Invoke-HardwareDiagnostic, Get-CpuLoadSample, Get-GpuVramBytes
