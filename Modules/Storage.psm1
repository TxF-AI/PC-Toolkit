#requires -Version 5.1
<#
    Storage.psm1 — Analyse du stockage (lecture seule)
    Volumes, santé des disques (SMART via Windows), taille des dossiers courants, gros fichiers.
    Aucun fichier n'est déplacé ni supprimé ici.
#>

function Get-FolderStats {
    <#
        Parcours récursif rapide (.NET) : taille totale, nombre de fichiers et gros fichiers.
        - ignore les liens symboliques/jonctions (évite les boucles et les doubles comptes)
        - ignore les dossiers inaccessibles au lieu d'échouer
    #>
    param([string]$Path, [long]$BigThreshold = 0, $Ctx, [string]$StatusPrefix = '')
    $total = [long]0; $count = 0; $dirs = 0; $denied = 0
    $big = New-Object System.Collections.Generic.List[object]
    $stack = New-Object System.Collections.Generic.Stack[string]
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        if (Test-DiagCancel $Ctx) { break }
        $d = $stack.Pop(); $dirs++
        if ($Ctx -and $StatusPrefix -and ($dirs % 300 -eq 0)) { $Ctx.Status = "$StatusPrefix $dirs dossiers parcourus…" }
        try {
            foreach ($e in ([IO.DirectoryInfo]$d).EnumerateFileSystemInfos()) {
                if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                if ($e -is [IO.DirectoryInfo]) { $stack.Push($e.FullName) }
                else {
                    $total += $e.Length; $count++
                    if ($BigThreshold -gt 0 -and $e.Length -ge $BigThreshold) { $big.Add([pscustomobject]@{ Path = $e.FullName; Size = $e.Length; Modified = $e.LastWriteTime }) }
                }
            }
        } catch { $denied++ }
    }
    [pscustomobject]@{ Path = $Path; Bytes = $total; Files = $count; Dirs = $dirs; Denied = $denied; Big = $big }
}

function Invoke-StorageDiagnostic {
    param($Ctx, [string]$ScanPath = $env:USERPROFILE, [long]$BigFileMB = 500)
    $r = New-DiagResult -Module 'Storage' -Title 'Analyse du stockage' -Ctx $Ctx

    # --- Volumes ---------------------------------------------------------------
    Update-DiagProgress $Ctx 3 'Lecture des volumes…'
    Add-DiagSection $r 'Espace disque' -Body {
        param($s)
        $vols = Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and $_.Size -gt 0 } | Sort-Object DriveLetter
        $rows = @()
        foreach ($v in $vols) {
            $pct = [math]::Round($v.SizeRemaining / $v.Size * 100, 1)
            $st = if ($pct -lt 8) { 'Crit' } elseif ($pct -lt 15) { 'Warn' } else { 'OK' }
            Add-DiagItem $s ('{0}:  {1}' -f $v.DriveLetter, $v.FileSystemLabel) ('{0} libres sur {1} ({2} %)' -f (Format-Bytes $v.SizeRemaining), (Format-Bytes $v.Size), $pct) $st $(if ($st -ne 'OK') { 'Gardez au moins 15 % d''espace libre, surtout sur le disque système (mises à jour, fichier d''échange).' } else { '' })
            $rows += [pscustomobject]@{ Lecteur = "$($v.DriveLetter):"; Nom = $v.FileSystemLabel; Système = $v.FileSystem; Taille = (Format-Bytes $v.Size); Libre = (Format-Bytes $v.SizeRemaining); 'Libre %' = $pct; État = "$($v.HealthStatus)" }
        }
        Add-DiagTable $s 'Volumes' $rows
    }

    # --- Santé des disques --------------------------------------------------------
    Update-DiagProgress $Ctx 10 'Santé des disques…'
    Add-DiagSection $r 'Santé des disques' -Body {
        param($s)
        $admin = Test-IsAdmin
        foreach ($d in @(Get-PhysicalDisk -ErrorAction SilentlyContinue | Sort-Object DeviceId)) {
            $st = switch ("$($d.HealthStatus)") { 'Healthy' { 'OK' } 'Warning' { 'Warn' } 'Unhealthy' { 'Crit' } default { 'Info' } }
            $health = switch ("$($d.HealthStatus)") { 'Healthy' { 'Sain' } 'Warning' { 'Avertissement' } 'Unhealthy' { 'Défaillant' } default { "$($d.HealthStatus)" } }
            Add-DiagItem $s $d.FriendlyName ('{0} · {1} {2} · {3}' -f $health, $d.MediaType, $d.BusType, (Format-Bytes $d.Size)) $st
            $rc = try { $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch { $null }
            if ($rc) {
                if ($null -ne $rc.Wear) { Add-DiagItem $s '  Usure' ('{0} %' -f $rc.Wear) $(if ($rc.Wear -ge 90) { 'Crit' } elseif ($rc.Wear -ge 70) { 'Warn' } else { 'OK' }) 'Pourcentage de la durée de vie estimée déjà consommée (SSD).' }
                if ($rc.Temperature) { Add-DiagItem $s '  Température' ('{0} °C' -f $rc.Temperature) $(if ($rc.Temperature -ge 70) { 'Crit' } elseif ($rc.Temperature -ge 60) { 'Warn' } else { 'OK' }) }
                if ($null -ne $rc.ReadErrorsUncorrected) { Add-DiagItem $s '  Erreurs de lecture non corrigées' $rc.ReadErrorsUncorrected $(if ($rc.ReadErrorsUncorrected -gt 0) { 'Crit' } else { 'OK' }) }
                if ($rc.PowerOnHours) { Add-DiagItem $s '  Heures de fonctionnement' ('{0:N0} h' -f $rc.PowerOnHours) 'Info' }
            }
        }
        if (-not $admin) { Add-DiagNote $s 'Mode standard : usure, température et erreurs SMART nécessitent les droits administrateur (bouton « Relancer en administrateur »).' }
    }

    # --- Dossiers courants ---------------------------------------------------------
    $known = [ordered]@{
        'Téléchargements'         = (Join-Path $env:USERPROFILE 'Downloads')
        'Bureau'                  = [Environment]::GetFolderPath('Desktop')
        'Documents'               = [Environment]::GetFolderPath('MyDocuments')
        'Vidéos'                  = [Environment]::GetFolderPath('MyVideos')
        'Temp utilisateur'        = $env:TEMP
        'Temp Windows'            = (Join-Path $env:windir 'Temp')
        'Cache Windows Update'    = (Join-Path $env:windir 'SoftwareDistribution\Download')
        'Cache shaders DirectX'   =(Join-Path $env:LOCALAPPDATA 'D3DSCache')
        'Ancien Windows'          = 'C:\Windows.old'
    }
    Add-DiagSection $r 'Dossiers volumineux connus' -Body {
        param($s)
        $rows = @(); $i = 0
        foreach ($k in $known.Keys) {
            if (Test-DiagCancel $Ctx) { break }
            $i++; Update-DiagProgress $Ctx (12 + [int](28 * $i / $known.Count)) "Taille de : $k…"
            $st = Get-FolderStats -Path $known[$k] -Ctx $Ctx
            if (-not $st) { continue }
            $rows += [pscustomobject]@{ Dossier = $k; Taille = (Format-Bytes $st.Bytes); Fichiers = $st.Files; Chemin = $known[$k]; '_b' = $st.Bytes; Inaccessibles = $st.Denied }
        }
        foreach ($row in $rows | Where-Object { $_.Dossier -in 'Temp utilisateur', 'Temp Windows', 'Cache Windows Update' -and $_._b -gt 2GB }) {
            Add-DiagItem $s $row.Dossier $row.Taille 'Warn' 'Peut être nettoyé en toute sécurité (module Maintenance ou Nettoyage de disque Windows).'
        }
        if ($rows | Where-Object Dossier -eq 'Ancien Windows') { Add-DiagItem $s 'Windows.old' (($rows | Where-Object Dossier -eq 'Ancien Windows').Taille) 'Warn' 'Ancienne installation de Windows, supprimable via Nettoyage de disque > Nettoyer les fichiers système.' }
        Add-DiagTable $s 'Tailles' ($rows | Sort-Object _b -Descending) @('Dossier', 'Taille', 'Fichiers', 'Inaccessibles', 'Chemin')
        $rb = 0
        try { $sh = New-Object -ComObject Shell.Application; foreach ($it in $sh.Namespace(10).Items()) { $rb += [long]$it.Size } } catch { }
        Add-DiagItem $s 'Corbeille' (Format-Bytes $rb) $(if ($rb -gt 5GB) { 'Warn' } else { 'Info' })
    }

    # --- Gros fichiers ------------------------------------------------------------
    if (-not (Test-DiagCancel $Ctx)) {
        Update-DiagProgress $Ctx 42 "Recherche des fichiers de plus de $BigFileMB Mo…"
        Add-DiagSection $r ("Gros fichiers dans {0}" -f $ScanPath) -Body {
            param($s)
            Update-DiagProgress $Ctx 45
            $st = Get-FolderStats -Path $ScanPath -BigThreshold ($BigFileMB * 1MB) -Ctx $Ctx -StatusPrefix 'Recherche des gros fichiers :'
            if (-not $st) { Add-DiagItem $s 'Dossier' "Introuvable : $ScanPath" 'Crit'; return }
            Add-DiagItem $s 'Taille totale analysée' ('{0} · {1:N0} fichiers · {2:N0} dossiers' -f (Format-Bytes $st.Bytes), $st.Files, $st.Dirs) 'Info'
            if ($st.Denied) { Add-DiagItem $s 'Dossiers inaccessibles (ignorés)' $st.Denied 'Info' 'Dossiers protégés par Windows : normal en mode standard.' }
            $top = $st.Big | Sort-Object Size -Descending | Select-Object -First 30
            Add-DiagItem $s ("Fichiers ≥ $BigFileMB Mo") ('{0} trouvé(s), {1} au total' -f $st.Big.Count, (Format-Bytes (($st.Big | Measure-Object Size -Sum).Sum))) 'Info'
            Add-DiagTable $s 'Les 30 plus gros fichiers' ($top | ForEach-Object { [pscustomobject]@{ Taille = (Format-Bytes $_.Size); Modifié = $_.Modified.ToString('dd/MM/yyyy'); Fichier = $_.Path } })
            Add-DiagNote $s 'Lecture seule : rien n''est supprimé. Vérifiez chaque fichier avant de le supprimer vous-même.'
        }
    }
    if (Test-DiagCancel $Ctx) { $r.Cancelled = $true }

    Update-DiagProgress $Ctx 100 'Terminé'
    $r
}

Export-ModuleMember -Function Invoke-StorageDiagnostic, Get-FolderStats
