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
        TempBytes       = $null
        RecycleBytes    = $null
        CacheBytes      = $null
    }

    Update-DiagProgress $Ctx 10 'Espace disque…'
    try { $snap.DiskFreeBytes = [long]([IO.DriveInfo]$env:SystemDrive).AvailableFreeSpace } catch { }

    Update-DiagProgress $Ctx 25 'Mémoire…'
    $os = Get-SafeCim Win32_OperatingSystem
    if ($os -and $os.TotalVisibleMemorySize) {
        $snap.RamUsedPct = [math]::Round((1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize) * 100, 1)
        $snap.RamUsedMB = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1KB, 0)
        $snap.RamFreeMB = [math]::Round($os.FreePhysicalMemory / 1KB, 0)
    }

    Update-DiagProgress $Ctx 40 'Services et processus…'
    try { $snap.ServicesRunning = @(Get-Service -ErrorAction Stop | Where-Object { $_.Status -eq 'Running' }).Count } catch { }
    try { $snap.Processes = @(Get-Process -ErrorAction Stop).Count } catch { }

    Update-DiagProgress $Ctx 55 'Fichiers temporaires et corbeille…'
    try {
        if (Get-Command Get-TempCleanupPreview -ErrorAction SilentlyContinue) { $snap.TempBytes = [long](Get-TempCleanupPreview -Ctx $null).Bytes }
        if (Get-Command Get-RecycleBinSize -ErrorAction SilentlyContinue) { $snap.RecycleBytes = [long](Get-RecycleBinSize).Bytes }
        if ($null -ne $snap.TempBytes -or $null -ne $snap.RecycleBytes) { $snap.CacheBytes = [long]$snap.TempBytes + [long]$snap.RecycleBytes }
    } catch { }

    Update-DiagProgress $Ctx 85 'Périphériques audio…'
    try { $snap.AudioGhost = @(Get-PnpDevice -Class AudioEndpoint -ErrorAction Stop | Where-Object { $_.Present -eq $false }).Count } catch { }

    Update-DiagProgress $Ctx 100 'Photo terminée'
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
        @{ Label = "Disque $($env:SystemDrive) libre"; Good = 'Higher'; Tol = 1MB
           Get  = { param($x) $x.DiskFreeBytes }
           Show = { param($x) Format-Bytes $x.DiskFreeBytes }
           Gain = { param($b, $a, $d) if ($d -gt 0) { '+' + (Format-Bytes $d) + ' libérés' } else { '-' + (Format-Bytes ([math]::Abs($d))) } } }
        @{ Label = 'RAM utilisée'; Good = 'Lower'; Tol = 100
           Get  = { param($x) $x.RamUsedMB }
           Show = { param($x) '{0:N0} % ({1})' -f $x.RamUsedPct, (Format-Bytes ($x.RamUsedMB * 1MB)) }
           Gain = { param($b, $a, $d) '{0:+0;-0;0} % ({1}{2})' -f ($a.RamUsedPct - $b.RamUsedPct), (& $sign $d), (Format-Bytes ([math]::Abs($d) * 1MB)) } }
        @{ Label = 'RAM disponible'; Good = 'Higher'; Tol = 100
           Get  = { param($x) $x.RamFreeMB }
           Show = { param($x) '{0:N0} Mo' -f $x.RamFreeMB }
           Gain = { param($b, $a, $d) '{0}{1:N0} Mo' -f (& $sign $d), [math]::Abs($d) } }
        @{ Label = 'Services actifs'; Good = 'Lower'; Tol = 0
           Get  = { param($x) $x.ServicesRunning }
           Show = { param($x) '{0:N0}' -f $x.ServicesRunning }
           Gain = { param($b, $a, $d) $n = [math]::Abs($d); if ($d -lt 0) { '-{0:N0} service{1} coupé{1}' -f $n, (& $s $n) } else { '+{0:N0} service{1}' -f $n, (& $s $n) } } }
        @{ Label = 'Processus'; Good = 'None'; Tol = 0
           Get  = { param($x) $x.Processes }
           Show = { param($x) '{0:N0}' -f $x.Processes }
           Gain = { param($b, $a, $d) '{0}{1:N0} processus' -f (& $sign $d), [math]::Abs($d) } }
        @{ Label = 'Périphériques audio'; Good = 'Lower'; Tol = 0
           Get  = { param($x) $x.AudioGhost }
           Show = { param($x) if ($x.AudioGhost -gt 0) { '{0:N0} fantôme{1}' -f $x.AudioGhost, (& $s $x.AudioGhost) } else { '0' } }
           Gain = { param($b, $a, $d) $n = [math]::Abs($d); if ($d -lt 0) { '-{0:N0} purgé{1}' -f $n, (& $s $n) } else { '+{0:N0}' -f $n } } }
        @{ Label = 'Fichiers temporaires'; Good = 'Lower'; Tol = 1MB
           Get  = { param($x) $x.CacheBytes }
           Show = { param($x) Format-Bytes $x.CacheBytes }
           Gain = { param($b, $a, $d) if ($d -lt 0) { '-' + (Format-Bytes ([math]::Abs($d))) + ' nettoyés' } else { '+' + (Format-Bytes $d) } } }
    )
    foreach ($d in $defs) {
        $b = & $d.Get $Before; $a = & $d.Get $After
        $row = [ordered]@{ Indicateur = $d.Label; Avant = 'Non disponible'; Apres = 'Non disponible'; Gain = 'Non disponible'; Status = 'NA' }
        if ($null -ne $b) { $row.Avant = & $d.Show $Before }
        if ($null -ne $a) { $row.Apres = & $d.Show $After }
        if ($null -ne $b -and $null -ne $a) {
            $delta = [double]$a - [double]$b
            # En dessous du seuil (RAM, compteurs…) on ne revendique aucun changement
            if ([math]::Abs($delta) -le $d.Tol) { $row.Gain = 'Aucun changement'; $row.Status = 'Info' }
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
    $r = New-DiagResult -Module 'Bilan' -Title 'Bilan d''optimisation — avant / après' -Ctx $null

    Add-DiagSection $r 'Gains nets' -Layout Tiles -Body {
        param($s)
        foreach ($row in $rows) { Add-DiagItem $s $row.Indicateur $row.Gain $row.Status ("{0}  →  {1}" -f $row.Avant, $row.Apres) }
    }
    Add-DiagSection $r 'Comparatif' -Body {
        param($s)
        $t = foreach ($row in $rows) { [pscustomobject][ordered]@{ 'Indicateur' = $row.Indicateur; 'Avant' = $row.Avant; 'Après' = $row.Apres; 'Gain net' = $row.Gain } }
        Add-DiagTable $s 'Avant / Après' $t @('Indicateur', 'Avant', 'Après', 'Gain net')
        if ($Operation) { Add-DiagNote $s "Actions mesurées : $Operation." }
        Add-DiagNote $s ("Mesure de départ : {0} · mesure finale : {1}." -f $Before.Date, $After.Date)
        Add-DiagNote $s 'La RAM, les services et les processus varient naturellement : sous un seuil minimal on indique « Aucun changement ».'
        if ($Before.IsAdmin -ne $After.IsAdmin) { Add-DiagNote $s 'Les deux mesures n''ont pas été prises avec les mêmes droits (administrateur ou non) : le dossier Temp de Windows peut fausser la comparaison.' }
    }
    $r
}

Export-ModuleMember -Function Get-SystemSnapshot, Get-SnapshotComparison, New-BilanResult
