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
        [pscustomobject]@{ Id = 'dismcheck';  Group = 'Verif';   Title = 'Vérifier l''image Windows (DISM)'; Kind = 'ReadOnly'; Admin = $true;  Desc = 'DISM /ScanHealth : recherche une corruption du magasin de composants Windows, sans rien réparer. 5 à 15 min.' }
        [pscustomobject]@{ Id = 'chkdsk';     Group = 'Verif';   Title = 'Vérifier le disque C: (CHKDSK)'; Kind = 'ReadOnly'; Admin = $true;  Desc = 'chkdsk C: /scan : analyse en ligne du système de fichiers, sans redémarrage ni réparation.' }
        [pscustomobject]@{ Id = 'temp';       Group = 'Clean';   Title = 'Fichiers temporaires';          Kind = 'Modify';   Admin = $false; Desc = "Analyse puis supprime les fichiers temporaires de plus de $($script:TempMinAgeDays) jours (dossier Temp utilisateur, et Temp Windows en mode administrateur). Les fichiers en cours d'utilisation sont ignorés." }
        [pscustomobject]@{ Id = 'recycle';    Group = 'Clean';   Title = 'Vider la corbeille';            Kind = 'Modify';   Admin = $false; Desc = 'Vidage complet de la corbeille de tous les disques, après affichage de son contenu et confirmation. Irréversible.' }
        [pscustomobject]@{ Id = 'dns';        Group = 'Clean';   Title = 'Vider le cache DNS';            Kind = 'Modify';   Admin = $false; Desc = 'Efface le cache de résolution DNS de Windows (sans risque, utile après un changement de DNS ou un site inaccessible).' }
        [pscustomobject]@{ Id = 'sfc';        Group = 'Clean';   Title = 'Réparer les fichiers système (SFC)'; Kind = 'Modify'; Admin = $true; Desc = 'sfc /scannow : vérifie les fichiers protégés de Windows et remplace ceux qui sont corrompus. 10 à 20 min.' }
        [pscustomobject]@{ Id = 'dismrepair'; Group = 'Clean';   Title = 'Réparer l''image Windows (DISM)';  Kind = 'Modify'; Admin = $true; Desc = 'DISM /RestoreHealth : répare le magasin de composants via Windows Update. À lancer si SFC n''arrive pas à tout réparer.' }
        [pscustomobject]@{ Id = 'restore';    Group = 'Clean';   Title = 'Créer un point de restauration'; Kind = 'Modify';   Admin = $true;  Desc = 'Crée un point de restauration système (conseillé avant toute mise à jour de pilote ou modification).' }
        [pscustomobject]@{ Id = 'recent';     Group = 'Privacy'; Title = 'Fichiers récents et listes de raccourcis'; Kind = 'Modify'; Admin = $false; Desc = 'Vide « Fichiers récents » de l''Explorateur et les listes de raccourcis (clic droit sur les icônes de la barre des tâches). Vos fichiers eux-mêmes ne sont pas touchés.' }
        [pscustomobject]@{ Id = 'partialdl';  Group = 'Privacy'; Title = 'Téléchargements inachevés';     Kind = 'Modify';   Admin = $false; Desc = 'Supprime les restes de téléchargements interrompus dans Téléchargements (.crdownload, .part, .partial…). L''historique des navigateurs n''est pas touché : il se vide depuis le navigateur.' }
        [pscustomobject]@{ Id = 'srum';       Group = 'Privacy'; Title = 'Réinitialiser les compteurs de données réseau'; Kind = 'Modify'; Admin = $true; Desc = 'Remet à zéro la base SRUM de Windows (consommation de données par application, historique d''applications du Gestionnaire des tâches). L''ancienne base est conservée en sauvegarde.' }
        [pscustomobject]@{ Id = 'datausage';  Group = 'Privacy'; Title = 'Utilisation des données (Windows)'; Kind = 'Open';   Admin = $false; Desc = 'Ouvre la page Windows qui affiche la consommation par application, avec son propre bouton de réinitialisation par carte réseau.' }
        [pscustomobject]@{ Id = 'cleanmgr';   Group = 'Open';    Title = 'Nettoyage de disque Windows';   Kind = 'Open';     Admin = $false; Desc = 'Ouvre l''outil Windows : vous choisissez vous-même ce qui est supprimé.' }
        [pscustomobject]@{ Id = 'reliab';     Group = 'Open';    Title = 'Moniteur de fiabilité';          Kind = 'Open';     Admin = $false; Desc = 'Historique visuel des plantages, mises à jour et erreurs.' }
        [pscustomobject]@{ Id = 'devmgmt';    Group = 'Open';    Title = 'Gestionnaire de périphériques';  Kind = 'Open';     Admin = $false; Desc = 'Pilotes et périphériques (lecture, aucune modification automatique).' }
        [pscustomobject]@{ Id = 'eventvwr';   Group = 'Open';    Title = 'Observateur d''événements';      Kind = 'Open';     Admin = $false; Desc = 'Journaux Windows complets.' }
        [pscustomobject]@{ Id = 'wu';         Group = 'Open';    Title = 'Windows Update';                 Kind = 'Open';     Admin = $false; Desc = 'Ouvre les paramètres de mise à jour.' }
        [pscustomobject]@{ Id = 'logs';       Group = 'Open';    Title = 'Journal des actions';            Kind = 'Open';     Admin = $false; Desc = 'Ouvre le dossier des journaux de PC Toolkit (toutes les actions effectuées y sont tracées).' }
    )
}

#region Historique et confidentialité -----------------------------------------------------

function Get-RecentItemsPreview {
    <# Lecture seule : éléments récents (.lnk) et listes de raccourcis (Jump Lists). #>
    param($Ctx, [string]$Root = (Join-Path $env:APPDATA 'Microsoft\Windows\Recent'))
    $recent = @(Get-ChildItem -LiteralPath $Root -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq '.lnk' })
    $jump = @(foreach ($d in 'AutomaticDestinations', 'CustomDestinations') { Get-ChildItem -LiteralPath (Join-Path $Root $d) -File -Force -ErrorAction SilentlyContinue })
    Update-DiagProgress $Ctx 100 'Analyse terminée'
    [pscustomobject]@{ Root = $Root; RecentCount = $recent.Count; JumpCount = $jump.Count; Files = @(@($recent.FullName) + @($jump.FullName) | Where-Object { $_ }) }
}

function Get-PartialDownloadsPreview {
    <# Lecture seule : téléchargements inachevés laissés par les navigateurs et clients de téléchargement. #>
    param($Ctx, [string]$Root = (Join-Path $env:USERPROFILE 'Downloads'))
    $ext = '.crdownload', '.part', '.partial', '.download', '.opdownload', '.!ut', '.!qb', '.!bt'
    Update-DiagProgress $Ctx 30 "Analyse de $Root…"
    $files = @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $ext -contains $_.Extension.ToLower() })
    Update-DiagProgress $Ctx 100 'Analyse terminée'
    [pscustomobject]@{ Root = $Root; Count = $files.Count; Bytes = [long](($files | Measure-Object Length -Sum).Sum); Files = @($files.FullName | Where-Object { $_ }) }
}

function Remove-FilesUnder {
    <#
        Supprime une liste de fichiers, uniquement s'ils se trouvent sous $Root (garde-fou).
        Les fichiers verrouillés ou protégés sont ignorés. Exige -Confirmed.
    #>
    param($Ctx, [string[]]$Files, [string]$Root, [string]$Label, [switch]$Confirmed)
    if (-not $Confirmed) { throw 'Action refusée : confirmation explicite requise.' }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $done = 0; $freed = [long]0; $skipped = 0; $i = 0
    foreach ($f in $Files) {
        $i++
        if ($i % 25 -eq 0) { Update-DiagProgress $Ctx ([int](100 * $i / [math]::Max(1, $Files.Count))) "Suppression… $i / $($Files.Count)" }
        if (-not ([IO.Path]::GetFullPath($f)).StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { $skipped++; continue }
        try { $len = (Get-Item -LiteralPath $f -Force -ErrorAction Stop).Length; Remove-Item -LiteralPath $f -Force -ErrorAction Stop; $done++; $freed += $len }
        catch { $skipped++ }
    }
    Write-AppLog ("{0} : {1} fichier(s) supprimé(s) ({2}), {3} ignoré(s)" -f $Label, $done, (Format-Bytes $freed), $skipped) 'ACTION'
    Update-DiagProgress $Ctx 100 'Terminé'
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
        Update-DiagProgress $Ctx 30 "Analyse de $root…"
        foreach ($f in Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue) {
            if ($f.LastWriteTime -lt $limit -and -not ($f.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $files.Add($f.FullName); $bytes += $f.Length }
        }
    }
    Update-DiagProgress $Ctx 100 'Analyse terminée'
    [pscustomobject]@{ Roots = $roots; Files = $files.ToArray(); Count = $files.Count; Bytes = $bytes }
}

function Invoke-TempCleanup {
    <# Supprime les fichiers listés par l'aperçu. Exige -Confirmed. Ne touche qu'aux fichiers situés sous les dossiers Temp. #>
    param($Ctx, [string[]]$Files, [string[]]$Roots, [switch]$Confirmed)
    if (-not $Confirmed) { throw 'Action refusée : confirmation explicite requise.' }
    $done = 0; $freed = [long]0; $skipped = 0; $i = 0
    foreach ($f in $Files) {
        $i++
        if ($i % 50 -eq 0) { Update-DiagProgress $Ctx ([int](100 * $i / [math]::Max(1, $Files.Count))) "Suppression… $i / $($Files.Count)" }
        if (-not ($Roots | Where-Object { $f.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) })) { $skipped++; continue }  # garde-fou
        try { $len = (Get-Item -LiteralPath $f -Force -ErrorAction Stop).Length; Remove-Item -LiteralPath $f -Force -ErrorAction Stop; $done++; $freed += $len }
        catch { $skipped++ }
    }
    Write-AppLog ("Nettoyage Temp : {0} fichiers supprimés ({1}), {2} ignorés" -f $done, (Format-Bytes $freed), $skipped) 'ACTION'
    Update-DiagProgress $Ctx 100 'Terminé'
    [pscustomobject]@{ Deleted = $done; Freed = $freed; Skipped = $skipped }
}

function Get-RecycleBinSize {
    $size = [long]0; $n = 0
    try { $sh = New-Object -ComObject Shell.Application; foreach ($it in $sh.Namespace(10).Items()) { $size += [long]$it.Size; $n++ } } catch { }
    [pscustomobject]@{ Bytes = $size; Count = $n }
}

function Clear-RecycleBinConfirmed {
    param([switch]$Confirmed)
    if (-not $Confirmed) { throw 'Action refusée : confirmation explicite requise.' }
    $before = Get-RecycleBinSize
    # Vide la corbeille de tous les lecteurs. Certaines versions échouent sur un lecteur sans corbeille
    # alors que les autres sont bien vidés : on vérifie donc le résultat réel plutôt que l'erreur.
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
    $after = Get-RecycleBinSize
    if ($after.Count -gt 0) { throw ("{0} élément(s) n'ont pas pu être supprimés de la corbeille." -f $after.Count) }
    Write-AppLog ("Corbeille vidée : {0} éléments, {1}" -f $before.Count, (Format-Bytes $before.Bytes)) 'ACTION'
    $before
}

function Clear-DnsCacheConfirmed {
    param([switch]$Confirmed)
    if (-not $Confirmed) { throw 'Action refusée : confirmation explicite requise.' }
    Clear-DnsClientCache -ErrorAction Stop
    Write-AppLog 'Cache DNS vidé' 'ACTION'
}

function Start-ElevatedConsole {
    <#
        Ouvre une console administrateur visible qui exécute la commande puis reste ouverte.
        Windows affiche la demande UAC : un refus annule simplement l'action.
    #>
    param([string]$Title, [string]$Command, [switch]$PowerShell, [switch]$Confirmed)
    if (-not $Confirmed) { throw 'Action refusée : confirmation explicite requise.' }
    if ($PowerShell) {
        $ps = "`$host.UI.RawUI.WindowTitle='PC Toolkit - $Title'`n$Command`nWrite-Host ''`nWrite-Host 'Terminé. Vous pouvez fermer cette fenêtre.' -ForegroundColor Green"
        # Commande encodée en Base64 (UTF-16) : les guillemets et retours à la ligne passent intacts
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ps))
        Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-NoExit', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded -Verb RunAs -ErrorAction Stop | Out-Null
    } else {
        Start-Process -FilePath 'cmd.exe' -ArgumentList '/k', "title PC Toolkit - $Title & $Command & echo. & echo Termine. Vous pouvez fermer cette fenetre." -Verb RunAs -ErrorAction Stop | Out-Null
    }
    Write-AppLog "Console administrateur lancée : $Title ($Command)" 'ACTION'
}

Export-ModuleMember -Function Get-MaintenanceTools, Get-RecentItemsPreview, Get-PartialDownloadsPreview, Remove-FilesUnder, Get-SrumResetCommand, Get-TempCleanupPreview, Invoke-TempCleanup, Get-RecycleBinSize, Clear-RecycleBinConfirmed, Clear-DnsCacheConfirmed, Start-ElevatedConsole
