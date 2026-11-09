#requires -Version 5.1
<#
    Bilan.psm1 — Bilan « Avant / Après » (tout en mémoire, aucun fichier)
    ---------------------------------------------------------------------
    1. Get-SystemSnapshot     : photo de l'état du PC (lecture seule). Ce que Windows n'expose pas reste $null.
    2. Get-SnapshotComparison : écarts et gains nets entre deux photos.
    3. New-BilanResult        : résultat au modèle standard (affichage, et section finale des exports HTML/TXT).
    Les photos sont gardées en mémoire par l'interface pendant l'exécution : rien n'est enregistré.
#>

function Get-SystemSnapshot {
    <# Lecture seule. Chaque mesure indisponible vaut $null (jamais de valeur inventée). #>
    param($Ctx)
    $snap = [ordered]@{
        Date            = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        IsAdmin         = [bool](Test-IsAdmin)
        DiskFreeBytes   = $null
        RamUsedPct      = $null
        RamUsedMB       = $null
        RamFreeMB       = $null
        ServicesRunning = $null
        Processes       = $null
        AudioGhost      = $null
        StartupActive   = $null
        TempBytes      = $null
        RecycleBytes    = $null
        CacheBytes      = $null
        SuspectActive   = $null
        Quarantined     = $null
        TuningProfile   = $null
    }

    Update-DiagProgress $Ctx 10 (Get-Text 'Bil.002')
    try { $snap.DiskFreeBytes = [long]([IO.DriveInfo]$env:SystemDrive).AvailableFreeSpace } catch { }

    Update-DiagProgress $Ctx 25 (Get-Text 'Bil.003')
    $os = Get-SafeCim Win32_OperatingSystem
    if ($os -and $os.TotalVisibleMemorySize) {
        $snap.RamUsedPct = [math]::Round((1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize) * 100, 1)
        $snap.RamUsedMB = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1KB, 0)
        $snap.RamFreeMB = [math]::Round($os.FreePhysicalMemory / 1KB, 0)
    }

    Update-DiagProgress $Ctx 40 (Get-Text 'Bil.004')
    try { $snap.ServicesRunning = @(Get-Service -ErrorAction Stop | Where-Object { $_.Status -eq 'Running' }).Count } catch { }
    try { $snap.Processes = @(Get-Process -ErrorAction Stop).Count } catch { }

    Update-DiagProgress $Ctx 55 (Get-Text 'Bil.006')
    try {
        if (Get-Command Get-TempCleanupPreview -ErrorAction SilentlyContinue) { $snap.TempBytes = [long](Get-TempCleanupPreview -Ctx $null).Bytes }
        if (Get-Command Get-RecycleBinSize -ErrorAction SilentlyContinue) { $snap.RecycleBytes = [long](Get-RecycleBinSize).Bytes }
        if ($null -ne $snap.TempBytes -or $null -ne $snap.RecycleBytes) { $snap.CacheBytes = [long]$snap.TempBytes + [long]$snap.RecycleBytes }
    } catch { }

    Update-DiagProgress $Ctx 70 (Get-Text 'Bil.007')
    try { if (Get-Command Get-StartupItems -ErrorAction SilentlyContinue) { $snap.StartupActive = @(Get-StartupItems | Where-Object Enabled).Count } } catch { }

    Update-DiagProgress $Ctx 85 (Get-Text 'Bil.008')
    try { $snap.AudioGhost = @(Get-PnpDevice -Class AudioEndpoint -ErrorAction Stop | Where-Object { $_.Present -eq $false }).Count } catch { }

    Update-DiagProgress $Ctx 92 (Get-Text 'Bil.009')
    try {
        if (Get-Command Get-SecuritySnapshotValues -ErrorAction SilentlyContinue) {
            $sec = Get-SecuritySnapshotValues
            $snap.SuspectActive = $sec.SuspectActive; $snap.Quarantined = $sec.Quarantined
        }
    } catch { }
    try {
        if (Get-Command Read-GameModeState -ErrorAction SilentlyContinue) {
            $gm = Read-GameModeState -Path (Get-GameModeStatePath)
            $snap.TuningProfile = if ($gm) { $(if ($gm.Profile) { [string]$gm.Profile } else { (Get-Text 'Bil.010') }) } else { (Get-Text 'Bil.011') }
        }
    } catch { }

    Update-DiagProgress $Ctx 100 (Get-Text 'Bil.012')
    [pscustomobject]$snap
}

function Get-SnapshotComparison {
    <#
        Une ligne par indicateur : Indicateur, Avant, Apres, Gain, Status.
        Status : OK (amélioration), Warn (dégradation), Info (inchangé ou neutre), NA (mesure manquante).
    #>
    param([Parameter(Mandatory)]$Before, [Parameter(Mandatory)]$After)
    $sign = { param($d) if ($d -gt 0) { '+' } else { '-' } }
    $s = { param($n) if ([math]::Abs($n) -gt 1) { 's' } else { '' } }
    $defs = @(
        @{ Label = (Get-Text 'Bil.013' $($env:SystemDrive)); Good = 'Higher'; Tol = 1MB
           Get  = { param($x) $x.DiskFreeBytes }
           Show = { param($x) Format-Bytes $x.DiskFreeBytes }
           Gain = { param($b, $a, $d) if ($d -gt 0) { '+' + (Format-Bytes $d) + (Get-Text 'Bil.015') } else { '-' + (Format-Bytes ([math]::Abs($d))) } } }
        @{ Label = (Get-Text 'Bil.016'); Good = 'Lower'; Tol = 100
           Get  = { param($x) $x.RamUsedMB }
           Show = { param($x) '{0:N0} % ({1})' -f $x.RamUsedPct, (Format-Bytes ($x.RamUsedMB * 1MB)) }
           Gain = { param($b, $a, $d) '{0:+0;-0;0} % ({1}{2})' -f ($a.RamUsedPct - $b.RamUsedPct), (& $sign $d), (Format-Bytes ([math]::Abs($d) * 1MB)) } }
        @{ Label = (Get-Text 'Bil.018'); Good = 'Higher'; Tol = 100
           Get  = { param($x) $x.RamFreeMB }
           Show = { param($x) (Get-Text 'Bil.020') -f $x.RamFreeMB }
           Gain = { param($b, $a, $d) (Get-Text 'Bil.021') -f (& $sign $d), [math]::Abs($d) } }
        @{ Label = (Get-Text 'Bil.022'); Good = 'Lower'; Tol = 0
           Get  = { param($x) $x.ServicesRunning }
           Show = { param($x) '{0:N0}' -f $x.ServicesRunning }
           Gain = { param($b, $a, $d) $n = [math]::Abs($d); if ($d -lt 0) { (Get-Text 'Bil.024') -f $n, (& $s $n) } else { (Get-Text 'Bil.025') -f $n, (& $s $n) } } }
        @{ Label = (Get-Text 'Bil.026'); Good = 'None'; Tol = 0
           Get  = { param($x) $x.Processes }
           Show = { param($x) '{0:N0}' -f $x.Processes }
           Gain = { param($b, $a, $d) (Get-Text 'Bil.028') -f (& $sign $d), [math]::Abs($d) } }
        @{ Label = (Get-Text 'Bil.029'); Good = 'Lower'; Tol = 0
           Get  = { param($x) $x.AudioGhost }
           Show = { param($x) if ($x.AudioGhost -gt 0) { (Get-Text 'Bil.031') -f $x.AudioGhost, (& $s $x.AudioGhost) } else { '0' } }
           Gain = { param($b, $a, $d) $n = [math]::Abs($d); if ($d -lt 0) { (Get-Text 'Bil.032') -f $n, (& $s $n) } else { '+{0:N0}' -f $n } } }
        @{ Label = (Get-Text 'Bil.033'); Good = 'Lower'; Tol = 0
           Get  = { param($x) $x.StartupActive }
           Show = { param($x) (Get-Text 'Bil.035') -f $x.StartupActive, (& $s $x.StartupActive) }
           Gain = { param($b, $a, $d) $n = [math]::Abs($d); if ($d -lt 0) { (Get-Text 'Bil.036') -f $n, (& $s $n) } else { (Get-Text 'Bil.037') -f $n, (& $s $n) } } }
        @{ Label = (Get-Text 'Bil.038'); Good = 'Lower'; Tol = 0
           Get  = { param($x) $x.SuspectActive }
           Show = { param($x) '{0:N0}' -f $x.SuspectActive }
           Gain = { param($b, $a, $d) $n = [math]::Abs($d); if ($d -lt 0) { (Get-Text 'Bil.040') -f $n, (& $s $n) } else { (Get-Text 'Bil.041') -f $n } } }
        @{ Label = (Get-Text 'Bil.042'); Good = 'Higher'; Tol = 0
           Get  = { param($x) $x.Quarantined }
           Show = { param($x) '{0:N0}' -f $x.Quarantined }
           Gain = { param($b, $a, $d) $n = [math]::Abs($d); if ($d -gt 0) { (Get-Text 'Bil.044') -f $n, (& $s $n) } else { (Get-Text 'Bil.045') -f $n, (& $s $n) } } }
        @{ Label = (Get-Text 'Bil.046'); Good = 'Higher'; Tol = 0
           Get  = { param($x) if ($null -eq $x.TuningProfile) { $null } elseif ($x.TuningProfile -eq (Get-Text 'Bil.048')) { 0 } else { 1 } }
           Show = { param($x) [string]$x.TuningProfile }
           Gain = { param($b, $a, $d) if ($d -gt 0) { (Get-Text 'Bil.049' $($a.TuningProfile)) } else { (Get-Text 'Bil.050') } } }
        @{ Label = (Get-Text 'Bil.051'); Good = 'Lower'; Tol = 1MB
           Get  = { param($x) $x.CacheBytes }
           Show = { param($x) Format-Bytes $x.CacheBytes }
           Gain = { param($b, $a, $d) if ($d -lt 0) { '-' + (Format-Bytes ([math]::Abs($d))) + (Get-Text 'Bil.053') } else { '+' + (Format-Bytes $d) } } }
    )
    foreach ($d in $defs) {
        $b = & $d.Get $Before; $a = & $d.Get $After
        $row = [ordered]@{ Indicateur = $d.Label; Avant = (Get-Text 'Bil.054'); Apres = (Get-Text 'Bil.055'); Gain = (Get-Text 'Bil.056'); Status = 'NA' }
        if ($null -ne $b) { $row.Avant = & $d.Show $Before }
        if ($null -ne $a) { $row.Apres = & $d.Show $After }
        if ($null -ne $b -and $null -ne $a) {
            $delta = [double]$a - [double]$b
            # En dessous du seuil (RAM, compteurs…) on ne revendique aucun changement
            if ([math]::Abs($delta) -le $d.Tol) { $row.Gain = (Get-Text 'Bil.057'); $row.Status = 'Info' }
            else {
                $row.Gain = & $d.Gain $Before $After $delta
                $row.Status = if ($d.Good -eq 'None') { 'Info' }
                              elseif (($d.Good -eq 'Higher') -eq ($delta -gt 0)) { 'OK' }
                              else { 'Warn' }
            }
        }
        [pscustomobject]$row
    }
}

function New-BilanResult {
    <# Résultat standard (même modèle que les diagnostics) : s'affiche et s'ajoute en fin d'export HTML/TXT. #>
    param([Parameter(Mandatory)]$Before, [Parameter(Mandatory)]$After, [string]$Operation = '')
    $rows = @(Get-SnapshotComparison -Before $Before -After $After)
    $r = New-DiagResult -Module 'Bilan' -Title (Get-Text 'Bil.061') -Ctx $null

    Add-DiagSection $r (Get-Text 'Bil.062') -Layout Tiles -Body {
        param($s)
        foreach ($row in $rows) { Add-DiagItem $s $row.Indicateur $row.Gain $row.Status ("{0}  →  {1}" -f $row.Avant, $row.Apres) }
    }
    Add-DiagSection $r (Get-Text 'Bil.063') -Body {
        param($s)
        $t = foreach ($row in $rows) { [pscustomobject][ordered]@{ 'Indicateur' = $row.Indicateur; 'Avant' = $row.Avant; 'Après' = $row.Apres; 'Gain net' = $row.Gain } }
        Add-DiagTable $s (Get-Text 'Bil.064') $t @('Indicateur', 'Avant', 'Après', 'Gain net')
        if ($Operation) { Add-DiagNote $s (Get-Text 'Bil.069' $Operation) }
        Add-DiagNote $s ((Get-Text 'Bil.070') -f $Before.Date, $After.Date)
        Add-DiagNote $s (Get-Text 'Bil.071')
        if ($Before.IsAdmin -ne $After.IsAdmin) { Add-DiagNote $s (Get-Text 'Bil.072') }
    }
    $r
}

Export-ModuleMember -Function Get-SystemSnapshot, Get-SnapshotComparison, New-BilanResult
