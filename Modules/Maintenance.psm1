#requires -Version 5.1
<#
    Maintenance.psm1 — Outils de vérification et nettoyage contrôlé
    -----------------------------------------------------------------
    Règles de sécurité :
      - toutes les fonctions qui modifient quelque chose exigent le commutateur -Confirmed
        (l'interface ne le passe qu'après une confirmation explicite de l'utilisateur) ;
      - chaque action est inscrite dans Data\Logs (journal des actions) ;
      - les outils système (SFC, DISM, CHKDSK, point de restauration) s'ouvrent dans une console
        administrateur visible : Windows affiche sa propre demande d'autorisation (UAC).
#>

$script:TempMinAgeDays = 2

function Get-MaintenanceTools {
    <#
        Catalogue des outils affichés dans l'interface.
        Kind  : ReadOnly | Modify | Open   (badge et style du bouton)
        Group : Verif | Clean | Privacy | Open   (section de la page)
    #>
    @(
        [pscustomobject]@{ Id = 'dismcheck';  Group = 'Verif';   Title = (Get-Text 'Mnt.003'); Kind = 'ReadOnly'; Admin = $true;  Desc = (Get-Text 'Mnt.005') }
        [pscustomobject]@{ Id = 'chkdsk';     Group = 'Verif';   Title = (Get-Text 'Mnt.008'); Kind = 'ReadOnly'; Admin = $true;  Desc = (Get-Text 'Mnt.010') }
        [pscustomobject]@{ Id = 'temp';       Group = 'Clean';   Title = (Get-Text 'Mnt.013');          Kind = 'Modify';   Admin = $false; Desc = (Get-Text 'Mnt.015' $($script:TempMinAgeDays)) }
        [pscustomobject]@{ Id = 'recycle';    Group = 'Clean';   Title = (Get-Text 'Mnt.018');            Kind = 'Modify';   Admin = $false; Desc = (Get-Text 'Mnt.020') }
        [pscustomobject]@{ Id = 'dns';        Group = 'Clean';   Title = (Get-Text 'Mnt.022');            Kind = 'Modify';   Admin = $false; Desc = (Get-Text 'Mnt.024') }
        [pscustomobject]@{ Id = 'sfc';        Group = 'Clean';   Title = (Get-Text 'Mnt.026'); Kind = 'Modify'; Admin = $true; Desc = (Get-Text 'Mnt.028') }
        [pscustomobject]@{ Id = 'dismrepair'; Group = 'Clean';   Title = (Get-Text 'Mnt.031');  Kind = 'Modify'; Admin = $true; Desc = (Get-Text 'Mnt.033') }
        [pscustomobject]@{ Id = 'restore';    Group = 'Clean';   Title = (Get-Text 'Mnt.036'); Kind = 'Modify';   Admin = $true;  Desc = (Get-Text 'Mnt.038') }
        [pscustomobject]@{ Id = 'recent';     Group = 'Privacy'; Title = (Get-Text 'Mnt.041'); Kind = 'Modify'; Admin = $false; Desc = (Get-Text 'Mnt.043') }
        [pscustomobject]@{ Id = 'partialdl';  Group = 'Privacy'; Title = (Get-Text 'Mnt.046');     Kind = 'Modify';   Admin = $false; Desc = (Get-Text 'Mnt.048') }
        [pscustomobject]@{ Id = 'srum';       Group = 'Privacy'; Title = (Get-Text 'Mnt.051'); Kind = 'Modify'; Admin = $true; Desc = (Get-Text 'Mnt.053') }
        [pscustomobject]@{ Id = 'datausage';  Group = 'Privacy'; Title = (Get-Text 'Mnt.056'); Kind = 'Open';   Admin = $false; Desc = (Get-Text 'Mnt.058') }
        [pscustomobject]@{ Id = 'cleanmgr';   Group = 'Open';    Title = (Get-Text 'Mnt.061');   Kind = 'Open';     Admin = $false; Desc = (Get-Text 'Mnt.063') }
        [pscustomobject]@{ Id = 'reliab';     Group = 'Open';    Title = (Get-Text 'Mnt.066');          Kind = 'Open';     Admin = $false; Desc = (Get-Text 'Mnt.068') }
        [pscustomobject]@{ Id = 'devmgmt';    Group = 'Open';    Title = (Get-Text 'Mnt.071');  Kind = 'Open';     Admin = $false; Desc = (Get-Text 'Mnt.073') }
        [pscustomobject]@{ Id = 'eventvwr';   Group = 'Open';    Title = (Get-Text 'Mnt.076');      Kind = 'Open';     Admin = $false; Desc = (Get-Text 'Mnt.078') }
        [pscustomobject]@{ Id = 'wu';         Group = 'Open';    Title = (Get-Text 'Mnt.080');                 Kind = 'Open';     Admin = $false; Desc = (Get-Text 'Mnt.082') }
        [pscustomobject]@{ Id = 'logs';       Group = 'Open';    Title = (Get-Text 'Mnt.085');            Kind = 'Open';     Admin = $false; Desc = (Get-Text 'Mnt.087') }
    )
}

#region Historique et confidentialité -----------------------------------------------------

function Get-RecentItemsPreview {
    <# Lecture seule : éléments récents (.lnk) et listes de raccourcis (Jump Lists). #>
    param($Ctx, [string]$Root = (Join-Path $env:APPDATA 'Microsoft\Windows\Recent'))
    $recent = @(Get-ChildItem -LiteralPath $Root -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq '.lnk' })
    $jump = @(foreach ($d in 'AutomaticDestinations', 'CustomDestinations') { Get-ChildItem -LiteralPath (Join-Path $Root $d) -File -Force -ErrorAction SilentlyContinue })
    Update-DiagProgress $Ctx 100 (Get-Text 'Mnt.090')
    [pscustomobject]@{ Root = $Root; RecentCount = $recent.Count; JumpCount = $jump.Count; Files = @(@($recent.FullName) + @($jump.FullName) | Where-Object { $_ }) }
}

function Get-PartialDownloadsPreview {
    <# Lecture seule : téléchargements inachevés laissés par les navigateurs et clients de téléchargement. #>
    param($Ctx, [string]$Root = (Join-Path $env:USERPROFILE 'Downloads'))
    $ext = '.crdownload', '.part', '.partial', '.download', '.opdownload', '.!ut', '.!qb', '.!bt'
    Update-DiagProgress $Ctx 30 (Get-Text 'Mnt.095' $Root)
    $files = @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $ext -contains $_.Extension.ToLower() })
    Update-DiagProgress $Ctx 100 (Get-Text 'Mnt.096')
    [pscustomobject]@{ Root = $Root; Count = $files.Count; Bytes = [long](($files | Measure-Object Length -Sum).Sum); Files = @($files.FullName | Where-Object { $_ }) }
}

function Remove-FilesUnder {
    <#
        Supprime une liste de fichiers, uniquement s'ils se trouvent sous $Root (garde-fou).
        Les fichiers verrouillés ou protégés sont ignorés. Exige -Confirmed.
    #>
    param($Ctx, [string[]]$Files, [string]$Root, [string]$Label, [switch]$Confirmed)
    if (-not $Confirmed) { throw (Get-Text 'Mnt.097') }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $done = 0; $freed = [long]0; $skipped = 0; $i = 0
    foreach ($f in $Files) {
        $i++
        if ($i % 25 -eq 0) { Update-DiagProgress $Ctx ([int](100 * $i / [math]::Max(1, $Files.Count))) (Get-Text 'Mnt.098' $i $($Files.Count)) }
        if (-not ([IO.Path]::GetFullPath($f)).StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { $skipped++; continue }
        try { $len = (Get-Item -LiteralPath $f -Force -ErrorAction Stop).Length; Remove-Item -LiteralPath $f -Force -ErrorAction Stop; $done++; $freed += $len }
        catch { $skipped++ }
    }
    Write-AppLog ((Get-Text 'Mnt.099') -f $Label, $done, (Format-Bytes $freed), $skipped) 'ACTION'
    Update-DiagProgress $Ctx 100 (Get-Text 'Mnt.101')
    [pscustomobject]@{ Deleted = $done; Freed = $freed; Skipped = $skipped }
}

function Get-SrumResetCommand {
    <#
        Commande exécutée dans une console administrateur pour remettre à zéro la base SRUM :
        arrêt du service « Stratégie de diagnostic » (DPS) qui la tient ouverte, déplacement de la base
        dans un dossier de sauvegarde daté, redémarrage du service (Windows recrée une base vide).
        Volontairement PAS de « netsh int ip reset » : cela réinitialise toute la pile réseau (DNS, IP fixes)
        sans remettre les compteurs à zéro.
    #>
    @'
$sru = Join-Path $env:windir 'System32\sru'
$bak = Join-Path $env:windir ('System32\sru.sauvegarde-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
try {
    Write-Host 'Arrêt du service Stratégie de diagnostic (DPS)…'
    Stop-Service -Name DPS -Force -ErrorAction Stop
    New-Item -ItemType Directory -Path $bak -ErrorAction Stop | Out-Null
    Get-ChildItem -LiteralPath $sru -Force | Move-Item -Destination $bak -Force -ErrorAction Stop
    Write-Host "Compteurs remis à zéro. Ancienne base sauvegardée dans : $bak" -ForegroundColor Green
} catch {
    Write-Host "Échec : $($_.Exception.Message)" -ForegroundColor Red
} finally {
    Start-Service -Name DPS -ErrorAction SilentlyContinue
    Write-Host ('Service DPS : ' + (Get-Service DPS).Status)
}
'@
}

#endregion

function Get-TempCleanupPreview {
    <# Lecture seule : liste ce qui serait supprimé. #>
    param($Ctx)
    $limit = (Get-Date).AddDays(-$script:TempMinAgeDays)
    $roots = @($env:TEMP)
    if (Test-IsAdmin) { $roots += (Join-Path $env:windir 'Temp') }
    $files = New-Object System.Collections.Generic.List[string]; $bytes = [long]0
    foreach ($root in $roots | Select-Object -Unique) {
        Update-DiagProgress $Ctx 30 (Get-Text 'Mnt.103' $root)
        foreach ($f in Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue) {
            if ($f.LastWriteTime -lt $limit -and -not ($f.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $files.Add($f.FullName); $bytes += $f.Length }
        }
    }
    Update-DiagProgress $Ctx 100 (Get-Text 'Mnt.104')
    [pscustomobject]@{ Roots = $roots; Files = $files.ToArray(); Count = $files.Count; Bytes = $bytes }
}

function Invoke-TempCleanup {
    <# Supprime les fichiers listés par l'aperçu. Exige -Confirmed. Ne touche qu'aux fichiers situés sous les dossiers Temp. #>
    param($Ctx, [string[]]$Files, [string[]]$Roots, [switch]$Confirmed)
    if (-not $Confirmed) { throw (Get-Text 'Mnt.105') }
    $done = 0; $freed = [long]0; $skipped = 0; $i = 0
    foreach ($f in $Files) {
        $i++
        if ($i % 50 -eq 0) { Update-DiagProgress $Ctx ([int](100 * $i / [math]::Max(1, $Files.Count))) (Get-Text 'Mnt.106' $i $($Files.Count)) }
        if (-not ($Roots | Where-Object { $f.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) })) { $skipped++; continue }  # garde-fou
        try { $len = (Get-Item -LiteralPath $f -Force -ErrorAction Stop).Length; Remove-Item -LiteralPath $f -Force -ErrorAction Stop; $done++; $freed += $len }
        catch { $skipped++ }
    }
    Write-AppLog ((Get-Text 'Mnt.107') -f $done, (Format-Bytes $freed), $skipped) 'ACTION'
    Update-DiagProgress $Ctx 100 (Get-Text 'Mnt.109')
    [pscustomobject]@{ Deleted = $done; Freed = $freed; Skipped = $skipped }
}

function Get-RecycleBinSize {
    $size = [long]0; $n = 0
    try { $sh = New-Object -ComObject Shell.Application; foreach ($it in $sh.Namespace(10).Items()) { $size += [long]$it.Size; $n++ } } catch { }
    [pscustomobject]@{ Bytes = $size; Count = $n }
}

function Clear-RecycleBinConfirmed {
    param([switch]$Confirmed)
    if (-not $Confirmed) { throw (Get-Text 'Mnt.110') }
    $before = Get-RecycleBinSize
    # Vide la corbeille de tous les lecteurs. Certaines versions échouent sur un lecteur sans corbeille
    # alors que les autres sont bien vidés : on vérifie donc le résultat réel plutôt que l'erreur.
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
    $after = Get-RecycleBinSize
    if ($after.Count -gt 0) { throw ((Get-Text 'Mnt.111') -f $after.Count) }
    Write-AppLog ((Get-Text 'Mnt.112') -f $before.Count, (Format-Bytes $before.Bytes)) 'ACTION'
    $before
}

function Clear-DnsCacheConfirmed {
    param([switch]$Confirmed)
    if (-not $Confirmed) { throw (Get-Text 'Mnt.114') }
    Clear-DnsClientCache -ErrorAction Stop
    Write-AppLog (Get-Text 'Mnt.115') 'ACTION'
}

function Start-ElevatedConsole {
    <#
        Ouvre une console administrateur visible qui exécute la commande puis reste ouverte.
        Windows affiche la demande UAC : un refus annule simplement l'action.
    #>
    param([string]$Title, [string]$Command, [switch]$PowerShell, [switch]$Confirmed)
    if (-not $Confirmed) { throw (Get-Text 'Mnt.117') }
    if ($PowerShell) {
        $ps = (Get-Text 'Mnt.118' $Title $Command)
        # Commande encodée en Base64 (UTF-16) : les guillemets et retours à la ligne passent intacts
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ps))
        Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-NoExit', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded -Verb RunAs -ErrorAction Stop | Out-Null
    } else {
        Start-Process -FilePath 'cmd.exe' -ArgumentList '/k', (Get-Text 'Mnt.120' $Title $Command) -Verb RunAs -ErrorAction Stop | Out-Null
    }
    Write-AppLog (Get-Text 'Mnt.121' $Title $Command) 'ACTION'
}

Export-ModuleMember -Function Get-MaintenanceTools, Get-RecentItemsPreview, Get-PartialDownloadsPreview, Remove-FilesUnder, Get-SrumResetCommand, Get-TempCleanupPreview, Invoke-TempCleanup, Get-RecycleBinSize, Clear-RecycleBinConfirmed, Clear-DnsCacheConfirmed, Start-ElevatedConsole
