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
    $r = New-DiagResult -Module 'Hardware' -Title (Get-Text 'Hw.003') -Ctx $Ctx

    # --- Processeur ---------------------------------------------------------------
    Update-DiagProgress $Ctx 5 (Get-Text 'Hw.004')
    Add-DiagSection $r (Get-Text 'Hw.005') -Body {
        param($s)
        $cpu = Get-SafeCim Win32_Processor | Select-Object -First 1
        Add-DiagItem $s (Get-Text 'Hw.006') ($cpu.Name.Trim())
        Add-DiagItem $s (Get-Text 'Hw.007') ((Get-Text 'Hw.008') -f $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors)
        Add-DiagItem $s (Get-Text 'Hw.009') ((Get-Text 'Hw.010') -f ($cpu.MaxClockSpeed / 1000))
        Update-DiagProgress $Ctx 10 (Get-Text 'Hw.011')
        $load = Get-CpuLoadSample 3
        $st = if ($null -eq $load) { 'NA' } elseif ($load -ge 90) { 'Crit' } elseif ($load -ge 70) { 'Warn' } else { 'OK' }
        Add-DiagItem $s (Get-Text 'Hw.012') $(if ($null -ne $load) { (Get-Text 'Hw.013' $load) }) $st
        $perf = Get-SafeCim Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'"
        if ($perf -and $null -ne $perf.PercentProcessorPerformance) {
            $pp = [int]$perf.PercentProcessorPerformance
            Add-DiagItem $s (Get-Text 'Hw.015') ((Get-Text 'Hw.016' $pp)) 'Info' (Get-Text 'Hw.017')
        }
        $vt = if ($cpu.VirtualizationFirmwareEnabled) { (Get-Text 'Hw.018') } else { (Get-Text 'Hw.019') }
        Add-DiagItem $s (Get-Text 'Hw.020') $vt 'Info'
        $top = Get-Process -ErrorAction SilentlyContinue | Sort-Object CPU -Descending | Select-Object -First 8 |
            ForEach-Object { [pscustomobject]@{ Processus = $_.ProcessName; 'Temps CPU cumulé s' = [math]::Round($_.CPU, 0); 'Mémoire' = (Format-Bytes $_.WorkingSet64) } }
        Add-DiagTable $s (Get-Text 'Hw.021') $top
    }

    # --- Mémoire -----------------------------------------------------------------
    Update-DiagProgress $Ctx 30 (Get-Text 'Hw.022')
    Add-DiagSection $r (Get-Text 'Hw.023') -Body {
        param($s)
        $os = Get-SafeCim Win32_OperatingSystem
        $mods = @(Get-SafeCim Win32_PhysicalMemory)
        $total = ($mods | Measure-Object Capacity -Sum).Sum
        Add-DiagItem $s (Get-Text 'Hw.024') ((Get-Text 'Hw.025') -f (Format-Bytes $total), $mods.Count)
        $usedPct = [math]::Round((1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize) * 100, 0)
        $st = if ($usedPct -ge 90) { 'Crit' } elseif ($usedPct -ge 80) { 'Warn' } else { 'OK' }
        Add-DiagItem $s (Get-Text 'Hw.026') ((Get-Text 'Hw.027') -f $usedPct, (Format-Bytes ($os.FreePhysicalMemory * 1KB))) $st
        $commit = Get-SafeCim Win32_PerfFormattedData_PerfOS_Memory
        if ($commit) { Add-DiagItem $s (Get-Text 'Hw.028') ((Get-Text 'Hw.029') -f $commit.PercentCommittedBytesInUse) $(if ($commit.PercentCommittedBytesInUse -ge 85) { 'Warn' } else { 'OK' }) (Get-Text 'Hw.030') }

        $conf = ($mods | Measure-Object ConfiguredClockSpeed -Maximum).Maximum
        if ($conf) {
            $ddr = if (($mods | Select-Object -First 1).SMBIOSMemoryType -eq 34) { 'DDR5' } else { 'DDR4' }
            if ($ddr -eq 'DDR4' -and $conf -le 2666) {
                Add-DiagItem $s (Get-Text 'Hw.031') (Get-Text 'Hw.032' $conf) 'Warn' (Get-Text 'Hw.033')
            } else { Add-DiagItem $s (Get-Text 'Hw.034') (Get-Text 'Hw.035' $conf) 'OK' }
        }
        if ($mods.Count -eq 1) { Add-DiagItem $s (Get-Text 'Hw.036') (Get-Text 'Hw.037') 'Warn' (Get-Text 'Hw.038') }
        elseif ($mods.Count -ge 2) { Add-DiagItem $s (Get-Text 'Hw.039') (Get-Text 'Hw.040' ($mods.Count)) 'OK' (Get-Text 'Hw.041') }

        $rows = $mods | ForEach-Object { [pscustomobject]@{ Emplacement = $_.DeviceLocator; Capacité = (Format-Bytes $_.Capacity); 'Vitesse max SPD' = $_.Speed; 'Vitesse configurée' = $_.ConfiguredClockSpeed; Fabricant = $_.Manufacturer; Référence = ("$($_.PartNumber)").Trim() } }
        Add-DiagTable $s (Get-Text 'Hw.042') $rows
        $topMem = Get-Process -ErrorAction SilentlyContinue | Sort-Object WorkingSet64 -Descending | Select-Object -First 8 |
            ForEach-Object { [pscustomobject]@{ Processus = $_.ProcessName; Mémoire = (Format-Bytes $_.WorkingSet64) } }
        Add-DiagTable $s (Get-Text 'Hw.043') $topMem
    }

    # --- Carte graphique --------------------------------------------------------
    Update-DiagProgress $Ctx 50 (Get-Text 'Hw.044')
    Add-DiagSection $r (Get-Text 'Hw.045') -Body {
        param($s)
        $all = @(Get-SafeCim Win32_VideoController)
        foreach ($v in $all | Where-Object Name -match 'Parsec|Virtual|Basic Display|Remote') {
            Add-DiagItem $s (Get-Text 'Hw.047') $v.Name 'Info' (Get-Text 'Hw.048')
        }
        foreach ($g in $all | Where-Object Name -notmatch 'Parsec|Virtual|Basic Display|Remote') {
            $vram = Get-GpuVramBytes $g.Name
            if (-not $vram -and $g.AdapterRAM) { $vram = [double][uint32]$g.AdapterRAM }
            $date = if ($g.DriverDate) { $g.DriverDate.ToString('dd/MM/yyyy') } else { '' }
            $age = if ($g.DriverDate) { ((Get-Date) - $g.DriverDate).TotalDays } else { 0 }
            Add-DiagItem $s $g.Name ((Get-Text 'Hw.050') -f $g.DriverVersion, $date) $(if ($age -gt 365) { 'Warn' } else { 'OK' }) $(if ($age -gt 365) { (Get-Text 'Hw.051') } else { '' })
            if ($vram) { Add-DiagItem $s (Get-Text 'Hw.052') (Format-Bytes $vram) }
            if ($g.CurrentHorizontalResolution) { Add-DiagItem $s (Get-Text 'Hw.053') ((Get-Text 'Hw.054') -f $g.CurrentHorizontalResolution, $g.CurrentVerticalResolution, $g.CurrentRefreshRate) }
            if ($g.Status -ne 'OK') { Add-DiagItem $s (Get-Text 'Hw.055') $g.Status 'Crit' }
        }
        # Charge GPU (compteurs Windows « GPU Engine », moteur 3D)
        $eng = @(Get-SafeCim Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine | Where-Object Name -match 'engtype_3D')
        if ($eng.Count) {
            $load = ($eng | Measure-Object UtilizationPercentage -Sum).Sum
            Add-DiagItem $s (Get-Text 'Hw.056') ('{0} %' -f [math]::Min(100, $load)) 'Info'
        }
        # Réinitialisations du pilote graphique (TDR) sur 30 jours
        try {
            $tdr = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 4101; StartTime = (Get-Date).AddDays(-30) } -ErrorAction Stop)
            Add-DiagItem $s (Get-Text 'Hw.058') $tdr.Count $(if ($tdr.Count -gt 0) { 'Warn' } else { 'OK' }) (Get-Text 'Hw.059')
        } catch { Add-DiagItem $s (Get-Text 'Hw.060') 0 'OK' }
    }

    # --- Carte mère / BIOS ----------------------------------------------------
    Update-DiagProgress $Ctx 65 (Get-Text 'Hw.061')
    Add-DiagSection $r (Get-Text 'Hw.062') -Body {
        param($s)
        $bb = Get-SafeCim Win32_BaseBoard
        $bios = Get-SafeCim Win32_BIOS
        Add-DiagItem $s (Get-Text 'Hw.063') ('{0} {1}' -f $bb.Manufacturer, $bb.Product)
        $bd = $bios.ReleaseDate
        $ageY = if ($bd) { [math]::Round(((Get-Date) - $bd).TotalDays / 365, 1) } else { $null }
        $st = if ($ageY -ge 2) { 'Warn' } else { 'OK' }
        Add-DiagItem $s (Get-Text 'Hw.064') ((Get-Text 'Hw.065') -f $bios.SMBIOSBIOSVersion, $bd) $st $(if ($ageY -ge 2) { (Get-Text 'Hw.066' $ageY) } else { '' })
        try {
            $plan = (powercfg /getactivescheme) -replace '^.*\((.*)\)\s*$', '$1'
            Add-DiagItem $s (Get-Text 'Hw.067') $plan 'Info'
        } catch { }
        $sb = try { Confirm-SecureBootUEFI -ErrorAction Stop } catch { $null }
        Add-DiagItem $s (Get-Text 'Hw.068') $(if ($null -eq $sb) { $null } elseif ($sb) { (Get-Text 'Hw.069') } else { (Get-Text 'Hw.070') }) 'Info' $(if ($null -eq $sb) { (Get-Text 'Hw.071') } else { '' })
    }

    # --- Températures ---------------------------------------------------------
    Update-DiagProgress $Ctx 80 (Get-Text 'Hw.072')
    Add-DiagSection $r (Get-Text 'Hw.073') -Body {
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
                Add-DiagTable $s (Get-Text 'Hw.077' ($ns.Split('/')[1])) $rows
                $cpuT = $sens | Where-Object { $_.Parent -match 'cpu' -and $_.Name -match 'Package' } | Select-Object -First 1
                if ($cpuT) { Add-DiagItem $s (Get-Text 'Hw.078') ('{0:N0} °C' -f $cpuT.Value) $(if ($cpuT.Value -ge 90) { 'Crit' } elseif ($cpuT.Value -ge 80) { 'Warn' } else { 'OK' }) }
            }
        }

        # 2) Zones thermiques ACPI exposées par la carte mère (pas forcément le CPU lui-même)
        $tz = @(Get-SafeCim Win32_PerfFormattedData_Counters_ThermalZoneInformation)
        foreach ($z in $tz) {
            $k = if ($z.HighPrecisionTemperature) { $z.HighPrecisionTemperature / 10 } else { $z.Temperature }
            if ($k -gt 200) {
                $found = $true
                $c = [math]::Round($k - 273.15, 1)
                Add-DiagItem $s ((Get-Text 'Hw.079') -f ($z.Name -replace '^.*\\', '')) "$c °C" $(if ($c -ge 90) { 'Warn' } else { 'Info' }) (Get-Text 'Hw.080')
            }
        }

        # 3) Température des disques (compteurs de fiabilité, droits admin requis)
        foreach ($d in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
            $rc = try { $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch { $null }
            if ($rc -and $rc.Temperature) {
                $found = $true
                Add-DiagItem $s ((Get-Text 'Hw.081') -f $d.FriendlyName) ('{0} °C' -f $rc.Temperature) $(if ($rc.Temperature -ge 70) { 'Crit' } elseif ($rc.Temperature -ge 60) { 'Warn' } else { 'OK' })
            }
        }

        if (-not ($s.Items | Where-Object Label -eq (Get-Text 'Hw.082'))) {
            Add-DiagItem $s ((Get-Text 'Hw.083') + $cpuShort + ')') $null 'NA' (Get-Text 'Hw.084')
        }
        Add-DiagItem $s ((Get-Text 'Hw.085') + $gpuShort + ')') $null 'NA' (Get-Text 'Hw.086')
        if (-not (Test-IsAdmin)) { Add-DiagNote $s (Get-Text 'Hw.087') }
        Add-DiagNote $s (Get-Text 'Hw.088')
    }

    Update-DiagProgress $Ctx 100 (Get-Text 'Hw.089')
    $r
}

Export-ModuleMember -Function Invoke-HardwareDiagnostic, Get-CpuLoadSample, Get-GpuVramBytes
