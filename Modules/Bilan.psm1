#requires -Version 5.1
<#
    Bilan.psm1 — Bilan « Avant / Après »
    ------------------------------------
    1. Get-SystemSnapshot  : photo de l'état du PC (lecture seule). Ce que Windows n'expose pas reste $null.
    2. Get-SnapshotComparison : calcule les écarts et les gains nets entre deux photos.
    3. New-BilanResult     : transforme la comparaison en résultat standard (affichage, HTML, TXT, historique).
    4. Show-BilanConsole   : tableau comparatif en console (style rouge néon).
    La seule écriture de ce module est le fichier de photo dans Data\Snapshots.
    Le nettoyage lui-même reste dans les outils existants (chacun demande sa confirmation).
#>

#region Photos -----------------------------------------------------------------------------

function Get-SystemSnapshot {
    <# Lecture seule. Chaque mesure indisponible vaut $null (jamais de valeur inventée). #>
    param($Ctx)
    $snap = [ordered]@{
        Date            = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        IsAdmin         = [bool](Test-IsAdmin)
        DiskFreeBytes   = $null
        RamUsedPct      = $null
        RamFreeMB       = $null
        ServicesRunning = $null
        Processes       = $null
        TempBytes       = $null
        RecycleBytes    = $null
        CacheBytes      = $null
        AudioActive     = $null
        AudioGhost      = $null
    }

    Update-DiagProgress $Ctx 5 'Espace disque…'
    try { $snap.DiskFreeBytes = [long]([IO.DriveInfo]$env:SystemDrive).AvailableFreeSpace } catch { }

    Update-DiagProgress $Ctx 15 'Mémoire…'
    $os = Get-SafeCim Win32_OperatingSystem
    if ($os -and $os.TotalVisibleMemorySize) {
        $snap.RamUsedPct = [math]::Round((1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize) * 100, 1)
        $snap.RamFreeMB = [math]::Round($os.FreePhysicalMemory / 1KB, 0)
    }

    Update-DiagProgress $Ctx 25 'Services et processus…'
    try { $snap.ServicesRunning = @(Get-Service -ErrorAction Stop | Where-Object { $_.Status -eq 'Running' }).Count } catch { }
    try { $snap.Processes = @(Get-Process -ErrorAction Stop).Count } catch { }

    Update-DiagProgress $Ctx 40 'Fichiers temporaires et corbeille…'
    try {
        if (Get-Command Get-TempCleanupPreview -ErrorAction SilentlyContinue) { $snap.TempBytes = [long](Get-TempCleanupPreview -Ctx $null).Bytes }
        if (Get-Command Get-RecycleBinSize -ErrorAction SilentlyContinue) { $snap.RecycleBytes = [long](Get-RecycleBinSize).Bytes }
        if ($null -ne $snap.TempBytes -or $null -ne $snap.RecycleBytes) { $snap.CacheBytes = [long]$snap.TempBytes + [long]$snap.RecycleBytes }
    } catch { }

    Update-DiagProgress $Ctx 80 'Périphériques audio…'
    try {
        $ep = @(Get-PnpDevice -Class AudioEndpoint -ErrorAction Stop)
        $snap.AudioActive = @($ep | Where-Object { $_.Present -eq $true -and $_.Status -eq 'OK' }).Count
        $snap.AudioGhost = @($ep | Where-Object { $_.Present -eq $false }).Count
    } catch { }

    Update-DiagProgress $Ctx 100 'Photo terminée'
    [pscustomobject]$snap
}

function Get-SnapshotFile([string]$Name) {
    Join-Path (Get-AppPath Snapshots) ($Name + '.json')
}

function Save-SystemSnapshot {
    <# Enregistre une photo (Data\Snapshots\<Name>.json). #>
    param([Parameter(Mandatory)]$Snapshot, [ValidateSet('avant', 'apres')][string]$Name = 'avant')
    $f = Get-SnapshotFile $Name
    $Snapshot | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $f -Encoding UTF8
    Write-AppLog "Bilan : photo « $Name » enregistrée"
    $f
}

function Get-SavedSnapshot {
    <# Relit une photo enregistrée ; $null si elle n'existe pas ou est illisible. #>
    param([ValidateSet('avant', 'apres')][string]$Name = 'avant')
    $f = Get-SnapshotFile $Name
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try { Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null }
}

#endregion

#region Comparaison -------------------------------------------------------------------------

function Format-BilanValue($Value, [string]$Fmt) {
    if ($null -eq $Value) { return 'Non disponible' }
    switch ($Fmt) {
        'bytes' { Format-Bytes ([double]$Value) }
        'mb'    { Format-Bytes ([double]$Value * 1MB) }
        'pct'   { '{0:N0} %' -f [double]$Value }
        default { '{0:N0}' -f [double]$Value }
    }
}

function Get-SnapshotComparison {
    <#
        Une ligne par indicateur : Indicateur, Avant, Apres, Gain, Status.
        Status : OK (amélioration), Warn (dégradation), Info (inchangé / neutre), NA (mesure manquante).
    #>
    param([Parameter(Mandatory)]$Before, [Parameter(Mandatory)]$After)
    $drive = $env:SystemDrive
    $defs = @(
        @{ Key = 'DiskFreeBytes';   Label = "Espace libre sur $drive";     Fmt = 'bytes'; Good = 'Higher'; Up = '+{0} libérés';                  Down = '-{0} d''espace libre en moins' }
        @{ Key = 'RamUsedPct';      Label = 'RAM utilisée';                Fmt = 'pct';   Good = 'Lower';  Up = '+{0} points d''occupation';     Down = '-{0} points d''occupation' }
        @{ Key = 'RamFreeMB';       Label = 'RAM disponible';              Fmt = 'mb';    Good = 'Higher'; Up = '+{0} de RAM libérée';           Down = '-{0} de RAM disponible' }
        @{ Key = 'ServicesRunning'; Label = 'Services en cours';           Fmt = 'count'; Good = 'Lower';  Up = '+{0} service(s) de plus';       Down = '-{0} service(s) arrêté(s)' }
        @{ Key = 'Processes';       Label = 'Processus';                   Fmt = 'count'; Good = 'Lower';  Up = '+{0} processus de plus';         Down = '-{0} processus en moins' }
        @{ Key = 'CacheBytes';      Label = 'Fichiers temporaires + corbeille'; Fmt = 'bytes'; Good = 'Lower'; Up = '+{0} de plus';             Down = '-{0} nettoyés' }
        @{ Key = 'AudioActive';     Label = 'Périphériques audio actifs';  Fmt = 'count'; Good = 'None';   Up = '+{0}';                           Down = '-{0}' }
        @{ Key = 'AudioGhost';      Label = 'Périphériques audio fantômes'; Fmt = 'count'; Good = 'Lower'; Up = '+{0} fantôme(s) de plus';         Down = '-{0} fantôme(s) purgé(s)' }
    )
    foreach ($d in $defs) {
        $b = $Before.($d.Key); $a = $After.($d.Key)
        $row = [ordered]@{ Indicateur = $d.Label; Avant = (Format-BilanValue $b $d.Fmt); Apres = (Format-BilanValue $a $d.Fmt); Gain = 'Non disponible'; Status = 'NA' }
        if ($null -ne $b -and $null -ne $a) {
            $delta = [double]$a - [double]$b
            # Tolérance : en dessous, on considère que rien n'a changé (RAM et compteurs bougent en permanence)
            $tol = switch ($d.Fmt) { 'bytes' { 1MB } 'mb' { 1 } 'pct' { 0.5 } default { 0 } }
            if ([math]::Abs($delta) -le $tol) { $row.Gain = 'Aucun changement'; $row.Status = 'Info' }
            else {
                $amount = switch ($d.Fmt) {
                    'bytes' { Format-Bytes ([math]::Abs($delta)) }
                    'mb'    { Format-Bytes ([math]::Abs($delta) * 1MB) }
                    'pct'   { '{0:N0}' -f [math]::Abs($delta) }
                    default { '{0:N0}' -f [math]::Abs($delta) }
                }
                $row.Gain = ($(if ($delta -gt 0) { $d.Up } else { $d.Down }) -f $amount)
                $row.Status = if ($d.Good -eq 'None') { 'Info' }
                              elseif (($d.Good -eq 'Higher') -eq ($delta -gt 0)) { 'OK' }
                              else { 'Warn' }
            }
        }
        [pscustomobject]$row
    }
}

#endregion

#region Rapport -----------------------------------------------------------------------------

function New-BilanResult {
    <# Résultat standard (même modèle que les diagnostics) : s'affiche, s'exporte en HTML/TXT et va dans l'historique. #>
    param([Parameter(Mandatory)]$Before, [Parameter(Mandatory)]$After)
    $rows = @(Get-SnapshotComparison -Before $Before -After $After)
    $r = New-DiagResult -Module 'Bilan' -Title 'Bilan avant / après' -Ctx $null

    Add-DiagSection $r 'Gains nets' -Layout Tiles -Body {
        param($s)
        foreach ($row in $rows) {
            Add-DiagItem $s $row.Indicateur $row.Gain $row.Status ("{0}  →  {1}" -f $row.Avant, $row.Apres)
        }
    }
    Add-DiagSection $r 'Comparatif' -Body {
        param($s)
        $t = foreach ($row in $rows) { [pscustomobject][ordered]@{ 'Indicateur' = $row.Indicateur; 'Avant' = $row.Avant; 'Après' = $row.Apres; 'Gain net' = $row.Gain } }
        Add-DiagTable $s 'Avant / Après' $t @('Indicateur', 'Avant', 'Après', 'Gain net')
        Add-DiagNote $s ("Photo « avant » : {0} · photo « après » : {1}." -f $Before.Date, $After.Date)
        Add-DiagNote $s 'La RAM, les processus et les services varient naturellement : seuls les écarts nets sont signalés, en dessous d''un seuil minimal on indique « Aucun changement ».'
        if ($Before.IsAdmin -ne $After.IsAdmin) { Add-DiagNote $s 'Les deux photos n''ont pas été prises avec les mêmes droits (administrateur ou non) : le dossier Temp de Windows peut fausser la comparaison.' }
    }
    $r
}

function Show-BilanConsole {
    <# Tableau comparatif en console, rouge néon. #>
    param([Parameter(Mandatory)]$Comparison, $Before, $After)
    $rows = @($Comparison)
    $w = @{
        I = [math]::Max(11, ($rows | ForEach-Object { $_.Indicateur.Length } | Measure-Object -Maximum).Maximum)
        A = [math]::Max(5,  ($rows | ForEach-Object { $_.Avant.Length } | Measure-Object -Maximum).Maximum)
        P = [math]::Max(5,  ($rows | ForEach-Object { $_.Apres.Length } | Measure-Object -Maximum).Maximum)
        G = [math]::Max(8,  ($rows | ForEach-Object { $_.Gain.Length } | Measure-Object -Maximum).Maximum)
    }
    $line = ([string][char]0x2500) * ($w.I + $w.A + $w.P + $w.G + 13)
    Write-Host ''
    Write-Host ('  ' + [char]0x26A1 + ' PC//TOOLKIT') -ForegroundColor Red -NoNewline
    Write-Host '  BILAN AVANT / APRÈS' -ForegroundColor White
    if ($Before -and $After) { Write-Host ("  {0}  →  {1}" -f $Before.Date, $After.Date) -ForegroundColor DarkGray }
    Write-Host "  $line" -ForegroundColor DarkRed
    $bar = [string][char]0x2502
    Write-Host ("  {0} {1} {0} {2} {0} {3} {0} {4}" -f $bar, 'INDICATEUR'.PadRight($w.I), 'AVANT'.PadRight($w.A), 'APRÈS'.PadRight($w.P), 'GAIN NET'.PadRight($w.G)) -ForegroundColor Red
    Write-Host "  $line" -ForegroundColor DarkRed
    foreach ($row in $rows) {
        $color = switch ($row.Status) { 'OK' { 'Green' } 'Warn' { 'Yellow' } 'NA' { 'DarkGray' } default { 'Gray' } }
        Write-Host ("  {0} " -f $bar) -ForegroundColor DarkRed -NoNewline
        Write-Host ($row.Indicateur.PadRight($w.I)) -ForegroundColor White -NoNewline
        Write-Host (" {0} " -f $bar) -ForegroundColor DarkRed -NoNewline
        Write-Host ($row.Avant.PadRight($w.A)) -ForegroundColor Gray -NoNewline
        Write-Host (" {0} " -f $bar) -ForegroundColor DarkRed -NoNewline
        Write-Host ($row.Apres.PadRight($w.P)) -ForegroundColor Gray -NoNewline
        Write-Host (" {0} " -f $bar) -ForegroundColor DarkRed -NoNewline
        Write-Host ($row.Gain.PadRight($w.G)) -ForegroundColor $color
    }
    Write-Host "  $line" -ForegroundColor DarkRed
    Write-Host ''
}

#endregion

Export-ModuleMember -Function Get-SystemSnapshot, Save-SystemSnapshot, Get-SavedSnapshot, Get-SnapshotComparison, New-BilanResult, Show-BilanConsole, Format-BilanValue
