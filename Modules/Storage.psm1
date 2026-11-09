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
        if ($Ctx -and $StatusPrefix -and ($dirs % 300 -eq 0)) { $Ctx.Status = (Get-Text 'St.001' $StatusPrefix $dirs) }
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
    $r = New-DiagResult -Module 'Storage' -Title (Get-Text 'St.003') -Ctx $Ctx

    # --- Volumes ---------------------------------------------------------------
    Update-DiagProgress $Ctx 3 (Get-Text 'St.004')
    Add-DiagSection $r (Get-Text 'St.005') -Body {
        param($s)
        $vols = Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and $_.Size -gt 0 } | Sort-Object DriveLetter
        $rows = @()
        foreach ($v in $vols) {
            $pct = [math]::Round($v.SizeRemaining / $v.Size * 100, 1)
            $st = if ($pct -lt 8) { 'Crit' } elseif ($pct -lt 15) { 'Warn' } else { 'OK' }
            Add-DiagItem $s ('{0}:  {1}' -f $v.DriveLetter, $v.FileSystemLabel) ((Get-Text 'St.006') -f (Format-Bytes $v.SizeRemaining), (Format-Bytes $v.Size), $pct) $st $(if ($st -ne 'OK') { (Get-Text 'St.007') } else { '' })
            $rows += [pscustomobject]@{ Lecteur = "$($v.DriveLetter):"; Nom = $v.FileSystemLabel; Système = $v.FileSystem; Taille = (Format-Bytes $v.Size); Libre = (Format-Bytes $v.SizeRemaining); 'Libre %' = $pct; État = "$($v.HealthStatus)" }
        }
        Add-DiagTable $s (Get-Text 'St.008') $rows
    }

    # --- Santé des disques --------------------------------------------------------
    Update-DiagProgress $Ctx 10 (Get-Text 'St.009')
    Add-DiagSection $r (Get-Text 'St.010') -Body {
        param($s)
        $admin = Test-IsAdmin
        foreach ($d in @(Get-PhysicalDisk -ErrorAction SilentlyContinue | Sort-Object DeviceId)) {
            $st = switch ("$($d.HealthStatus)") { 'Healthy' { 'OK' } 'Warning' { 'Warn' } 'Unhealthy' { 'Crit' } default { 'Info' } }
            $health = switch ("$($d.HealthStatus)") { 'Healthy' { (Get-Text 'St.011') } 'Warning' { (Get-Text 'St.012') } 'Unhealthy' { (Get-Text 'St.013') } default { "$($d.HealthStatus)" } }
            Add-DiagItem $s $d.FriendlyName ('{0} · {1} {2} · {3}' -f $health, $d.MediaType, $d.BusType, (Format-Bytes $d.Size)) $st
            $rc = try { $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch { $null }
            if ($rc) {
                if ($null -ne $rc.Wear) { Add-DiagItem $s (Get-Text 'St.014') ('{0} %' -f $rc.Wear) $(if ($rc.Wear -ge 90) { 'Crit' } elseif ($rc.Wear -ge 70) { 'Warn' } else { 'OK' }) (Get-Text 'St.015') }
                if ($rc.Temperature) { Add-DiagItem $s (Get-Text 'St.016') ('{0} °C' -f $rc.Temperature) $(if ($rc.Temperature -ge 70) { 'Crit' } elseif ($rc.Temperature -ge 60) { 'Warn' } else { 'OK' }) }
                if ($null -ne $rc.ReadErrorsUncorrected) { Add-DiagItem $s (Get-Text 'St.017') $rc.ReadErrorsUncorrected $(if ($rc.ReadErrorsUncorrected -gt 0) { 'Crit' } else { 'OK' }) }
                if ($rc.PowerOnHours) { Add-DiagItem $s (Get-Text 'St.018') ('{0:N0} h' -f $rc.PowerOnHours) 'Info' }
            }
        }
        if (-not $admin) { Add-DiagNote $s (Get-Text 'St.019') }
    }

    # --- Dossiers courants ---------------------------------------------------------
    $known = [ordered]@{
        (Get-Text 'Fld.Downloads') = (Join-Path $env:USERPROFILE 'Downloads')
        (Get-Text 'Fld.Desktop')   = [Environment]::GetFolderPath('Desktop')
        (Get-Text 'Fld.Documents') = [Environment]::GetFolderPath('MyDocuments')
        (Get-Text 'Fld.Videos')    = [Environment]::GetFolderPath('MyVideos')
        (Get-Text 'Fld.TempUser')  = $env:TEMP
        (Get-Text 'Fld.TempWin')   = (Join-Path $env:windir 'Temp')
        (Get-Text 'Fld.WUCache')   = (Join-Path $env:windir 'SoftwareDistribution\Download')
        (Get-Text 'Fld.Shaders')   = (Join-Path $env:LOCALAPPDATA 'D3DSCache')
        (Get-Text 'Fld.OldWin')    = 'C:\Windows.old'
    }
    Add-DiagSection $r (Get-Text 'St.025') -Body {
        param($s)
        $rows = @(); $i = 0
        foreach ($k in $known.Keys) {
            if (Test-DiagCancel $Ctx) { break }
            $i++; Update-DiagProgress $Ctx (12 + [int](28 * $i / $known.Count)) (Get-Text 'St.026' $k)
            $st = Get-FolderStats -Path $known[$k] -Ctx $Ctx
            if (-not $st) { continue }
            $rows += [pscustomobject]@{ Dossier = $k; Taille = (Format-Bytes $st.Bytes); Fichiers = $st.Files; Chemin = $known[$k]; '_b' = $st.Bytes; Inaccessibles = $st.Denied }
        }
        foreach ($row in $rows | Where-Object { $_.Dossier -in (Get-Text 'Fld.TempUser'), (Get-Text 'Fld.TempWin'), (Get-Text 'Fld.WUCache') -and $_._b -gt 2GB }) {
            Add-DiagItem $s $row.Dossier $row.Taille 'Warn' (Get-Text 'St.027')
        }
        if ($rows | Where-Object Dossier -eq (Get-Text 'Fld.OldWin')) { Add-DiagItem $s 'Windows.old' (($rows | Where-Object Dossier -eq (Get-Text 'Fld.OldWin')).Taille) 'Warn' (Get-Text 'St.028') }
        Add-DiagTable $s (Get-Text 'St.029') ($rows | Sort-Object _b -Descending) @('Dossier', 'Taille', 'Fichiers', 'Inaccessibles', 'Chemin')
        $rb = 0
        try { $sh = New-Object -ComObject Shell.Application; foreach ($it in $sh.Namespace(10).Items()) { $rb += [long]$it.Size } } catch { }
        Add-DiagItem $s (Get-Text 'St.035') (Format-Bytes $rb) $(if ($rb -gt 5GB) { 'Warn' } else { 'Info' })
    }

    # --- Gros fichiers ------------------------------------------------------------
    if (-not (Test-DiagCancel $Ctx)) {
        Update-DiagProgress $Ctx 42 (Get-Text 'St.036' $BigFileMB)
        Add-DiagSection $r ((Get-Text 'St.037') -f $ScanPath) -Body {
            param($s)
            Update-DiagProgress $Ctx 45
            $st = Get-FolderStats -Path $ScanPath -BigThreshold ($BigFileMB * 1MB) -Ctx $Ctx -StatusPrefix (Get-Text 'St.038')
            if (-not $st) { Add-DiagItem $s (Get-Text 'St.039') (Get-Text 'St.040' $ScanPath) 'Crit'; return }
            Add-DiagItem $s (Get-Text 'St.041') ((Get-Text 'St.042') -f (Format-Bytes $st.Bytes), $st.Files, $st.Dirs) 'Info'
            if ($st.Denied) { Add-DiagItem $s (Get-Text 'St.043') $st.Denied 'Info' (Get-Text 'St.044') }
            $top = $st.Big | Sort-Object Size -Descending | Select-Object -First 30
            Add-DiagItem $s ((Get-Text 'St.045' $BigFileMB)) ((Get-Text 'St.046') -f $st.Big.Count, (Format-Bytes (($st.Big | Measure-Object Size -Sum).Sum))) 'Info'
            Add-DiagTable $s (Get-Text 'St.047') ($top | ForEach-Object { [pscustomobject]@{ Taille = (Format-Bytes $_.Size); Modifié = $_.Modified.ToString('dd/MM/yyyy'); Fichier = $_.Path } })
            Add-DiagNote $s (Get-Text 'St.048')
        }
    }
    if (Test-DiagCancel $Ctx) { $r.Cancelled = $true }

    Update-DiagProgress $Ctx 100 (Get-Text 'St.049')
    $r
}

Export-ModuleMember -Function Invoke-StorageDiagnostic, Get-FolderStats
