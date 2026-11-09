#requires -Version 5.1
<#
    Confidentialité & désencombrement de Windows 11 — script autonome
    ------------------------------------------------------------------
    1. Télémétrie et publicité : services DiagTrack / dmwappushservice, tâches planifiées de collecte,
       ID de publicité, réglages de télémétrie du registre.
    2. Recherche : Bing, suggestions web et Cortana retirés du menu Démarrer.
    3. Applications préinstallées : Candy Crush, Solitaire, Actualités, Météo, Skype, Cortana…
       CONSERVÉS volontairement (jeux, Game Pass, système) : Xbox Game Bar, Xbox Identity Provider,
       Gaming Services, application Xbox (Microsoft.GamingApp), Microsoft Store.
    4. Widgets, publicités et suggestions (menu Démarrer, écran de verrouillage, Explorateur, Paramètres).
    5. Sécurité : aperçu de tout ce qui va changer, confirmation, point de restauration,
       sauvegarde des valeurs d'origine (annulation avec -Restaurer), bilan final enregistré.

    Usage (PowerShell en administrateur — le script propose de se relancer en admin) :
      .\Confidentialite-Debloat-Win11.ps1            aperçu, confirmation, puis application
      .\Confidentialite-Debloat-Win11.ps1 -Apercu    montre ce qui serait modifié, ne change rien
      .\Confidentialite-Debloat-Win11.ps1 -Restaurer .\Sauvegardes\confidentialite-AAAAMMJJ-HHMMSS.json

    Notes :
    - Windows 11 Famille ne descend pas sous « Données de diagnostic requises » : AllowTelemetry=0
      y est traité comme 1. Désactiver le service DiagTrack reste efficace.
    - Les réglages « utilisateur » (HKCU) s'appliquent au compte qui lance le script.
    - Les applications supprimées se réinstallent depuis le Microsoft Store (-Restaurer ne les recrée pas).
    - Le PC n'est jamais redémarré automatiquement.
#>
param(
    [switch]$Apercu,
    [switch]$Oui,
    [string]$Restaurer
)
$ErrorActionPreference = 'Stop'

function Wait-Fin { if (-not $Oui) { Read-Host '  Appuyez sur Entrée pour fermer' | Out-Null } }
function Confirm-OuiNon([string]$Question) {
    if ($Oui) { return $true }
    return ((Read-Host "  $Question (O/N)") -match '^[oOyY]')
}

# ---------- Administrateur (relance via UAC si l'utilisateur l'accepte) ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host ''
    Write-Host '  Ce script doit être lancé en administrateur.' -ForegroundColor Yellow
    if ((Read-Host '  Le relancer en administrateur maintenant ? (O/N)') -match '^[oOyY]') {
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
        if ($Apercu) { $argList += '-Apercu' }
        if ($Oui) { $argList += '-Oui' }
        if ($Restaurer) { $argList += @('-Restaurer', "`"$((Resolve-Path -LiteralPath $Restaurer).Path)`"") }
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
    }
    exit
}

# ---------- État ----------
$script:DryRun = $true
$script:Bilan = [ordered]@{}
$script:Sauvegarde = New-Object System.Collections.ArrayList
$script:Provisionnees = $null
$script:Rang = @{ ABSENT = 0; DEJA = 1; CHANGE = 2; ECHEC = 3 }
$dossierSauv = Join-Path $PSScriptRoot 'Sauvegardes'

function Add-Bilan([string]$Cat, [string]$Label, [string]$Etat, [string]$Detail = '') {
    $key = "$Cat|$Label"
    $cur = $script:Bilan[$key]
    if (-not $cur) { $script:Bilan[$key] = [pscustomobject]@{ Cat = $Cat; Label = $Label; Etat = $Etat; Detail = $Detail }; return }
    if ($script:Rang[$Etat] -gt $script:Rang[$cur.Etat]) { $cur.Etat = $Etat; $cur.Detail = $Detail }
}

# ---------- Actions (chacune lit d'abord, ne modifie qu'en passe d'application) ----------
function Set-Reg([string]$Cat, [string]$Label, [string]$Path, [string]$Name, [int]$Value) {
    try {
        $existe = $false; $ancien = $null; $type = $null
        if (Test-Path -LiteralPath $Path) {
            $cle = Get-Item -LiteralPath $Path
            if ($cle.GetValueNames() -contains $Name) {
                $existe = $true
                $ancien = $cle.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                $type = $cle.GetValueKind($Name).ToString()
            }
        }
        if ($existe -and $type -eq 'DWord' -and $ancien -eq $Value) { Add-Bilan $Cat $Label 'DEJA'; return }
        if ($script:DryRun) { Add-Bilan $Cat $Label 'CHANGE'; return }
        [void]$script:Sauvegarde.Add([pscustomobject]@{ Type = 'Registre'; Path = $Path; Name = $Name; Existait = $existe; Ancien = $ancien; TypeValeur = $type })
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
        Add-Bilan $Cat $Label 'CHANGE'
    } catch { Add-Bilan $Cat $Label 'ECHEC' $_.Exception.Message }
}

function Disable-Svc([string]$Cat, [string]$Label, [string]$Name) {
    try {
        $svc = Get-CimInstance Win32_Service -Filter "Name='$Name'"
        if (-not $svc) { Add-Bilan $Cat $Label 'ABSENT'; return }
        if ($svc.StartMode -eq 'Disabled' -and $svc.State -eq 'Stopped') { Add-Bilan $Cat $Label 'DEJA'; return }
        if ($script:DryRun) { Add-Bilan $Cat $Label 'CHANGE'; return }
        $delayed = (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" -ErrorAction SilentlyContinue).DelayedAutostart -eq 1
        $start = switch ($svc.StartMode) {
            'Auto' { if ($delayed) { 'delayed-auto' } else { 'auto' } }
            'Disabled' { 'disabled' }
            default { 'demand' }
        }
        [void]$script:Sauvegarde.Add([pscustomobject]@{ Type = 'Service'; Name = $Name; Demarrage = $start })
        if ($svc.State -ne 'Stopped') { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
        $out = & sc.exe config $Name start= disabled
        if ($LASTEXITCODE -ne 0) { throw "sc.exe : $($out -join ' ')" }
        Add-Bilan $Cat $Label 'CHANGE'
    } catch { Add-Bilan $Cat $Label 'ECHEC' $_.Exception.Message }
}

function Disable-Task([string]$Cat, [string]$Label, [string]$TaskPath, [string]$TaskName) {
    try {
        $t = try { Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop } catch { $null }
        if (-not $t) { Add-Bilan $Cat $Label 'ABSENT'; return }
        if ($t.State -eq 'Disabled') { Add-Bilan $Cat $Label 'DEJA'; return }
        if ($script:DryRun) { Add-Bilan $Cat $Label 'CHANGE'; return }
        [void]$script:Sauvegarde.Add([pscustomobject]@{ Type = 'Tache'; Path = $TaskPath; Name = $TaskName })
        Disable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName | Out-Null
        Add-Bilan $Cat $Label 'CHANGE'
    } catch { Add-Bilan $Cat $Label 'ECHEC' $_.Exception.Message }
}

function Remove-App([string]$Label, [string]$Pattern) {
    $Cat = 'Applications préinstallées'
    try {
        if ($null -eq $script:Provisionnees) {
            # Sur certains PC, cette liste renvoie « Accès refusé » même en administrateur : on continue avec les applis installées
            try { $script:Provisionnees = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop) } catch { $script:Provisionnees = @() }
        }
        $pkgs = @(Get-AppxPackage -AllUsers -Name $Pattern -ErrorAction SilentlyContinue)
        $prov = @($script:Provisionnees | Where-Object { $_.DisplayName -like $Pattern })
        if (-not $pkgs.Count -and -not $prov.Count) { Add-Bilan $Cat $Label 'ABSENT'; return }
        if ($script:DryRun) { Add-Bilan $Cat $Label 'CHANGE'; return }
        foreach ($p in $pkgs) {
            try { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop }
            catch { Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop }
        }
        foreach ($p in $prov) { Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop | Out-Null }
        $noms = @(@($pkgs | ForEach-Object { $_.Name }) + @($prov | ForEach-Object { $_.DisplayName }) | Sort-Object -Unique)
        [void]$script:Sauvegarde.Add([pscustomobject]@{ Type = 'Application'; Name = $Label; Paquets = $noms })
        Add-Bilan $Cat $Label 'CHANGE'
    } catch { Add-Bilan $Cat $Label 'ECHEC' $_.Exception.Message }
}

# ---------- Le plan complet ----------
function Invoke-Plan {
    # 1. Télémétrie
    $c = 'Télémétrie'
    Disable-Svc $c 'Service DiagTrack (télémétrie)' 'DiagTrack'
    Disable-Svc $c 'Service dmwappushservice (routage des messages WAP)' 'dmwappushservice'
    Set-Reg $c 'Niveau de télémétrie au minimum' 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
    Set-Reg $c 'Niveau de télémétrie au minimum' 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' 0
    Set-Reg $c 'Demandes de commentaires' 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'DoNotShowFeedbackNotifications' 1
    Set-Reg $c 'Demandes de commentaires' 'HKCU:\Software\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' 0
    Set-Reg $c 'Expériences personnalisées (données de diagnostic)' 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0
    Set-Reg $c 'Envoi de l''historique d''activités' 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 0
    Set-Reg $c 'Envoi de l''historique d''activités' 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'UploadUserActivities' 0
    $taches = @(
        @('\Microsoft\Windows\Application Experience\', 'Microsoft Compatibility Appraiser'),
        @('\Microsoft\Windows\Application Experience\', 'ProgramDataUpdater'),
        @('\Microsoft\Windows\Customer Experience Improvement Program\', 'Consolidator'),
        @('\Microsoft\Windows\Customer Experience Improvement Program\', 'UsbCeip'),
        @('\Microsoft\Windows\Feedback\Siuf\', 'DmClient'),
        @('\Microsoft\Windows\Feedback\Siuf\', 'DmClientOnScenarioDownload')
    )
    foreach ($t in $taches) { Disable-Task $c 'Tâches planifiées de collecte' $t[0] $t[1] }

    # 1 bis. Publicité
    $c = 'Publicité'
    Set-Reg $c 'Identifiant de publicité' 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
    Set-Reg $c 'Identifiant de publicité' 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy' 1
    Set-Reg $c 'Sites web : accès à la liste des langues' 'HKCU:\Control Panel\International\User Profile' 'HttpAcceptLanguageOptOut' 1

    # 2. Recherche
    $c = 'Recherche Windows'
    Set-Reg $c 'Résultats Bing / web dans le menu Démarrer' 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
    Set-Reg $c 'Résultats Bing / web dans le menu Démarrer' 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0
    Set-Reg $c 'Résultats Bing / web dans le menu Démarrer' 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'ConnectedSearchUseWeb' 0
    Set-Reg $c 'Cortana' 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'CortanaConsent' 0
    Set-Reg $c 'Cortana' 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 0
    Set-Reg $c 'Points forts de la recherche (contenu du jour)' 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsDynamicSearchBoxEnabled' 0

    # 3. Applications préinstallées (liste explicite : aucun composant Xbox nécessaire aux jeux n'y figure)
    $apps = @(
        @('Candy Crush et jeux King', 'king.com.*'),
        @('Microsoft Solitaire Collection', 'Microsoft.MicrosoftSolitaireCollection'),
        @('Actualités (Microsoft News)', 'Microsoft.BingNews'),
        @('Météo', 'Microsoft.BingWeather'),
        @('Skype', 'Microsoft.SkypeApp'),
        @('Cortana', 'Microsoft.549981C3F5F10'),
        @('Xbox Console Companion (ancienne appli)', 'Microsoft.XboxApp'),
        @('Astuces (Prise en main)', 'Microsoft.Getstarted'),
        @('Microsoft 365 (Office Hub)', 'Microsoft.MicrosoftOfficeHub'),
        @('Hub de commentaires', 'Microsoft.WindowsFeedbackHub')
    )
    foreach ($a in $apps) { Remove-App $a[0] $a[1] }

    # 4. Widgets & suggestions
    $c = 'Widgets et suggestions'
    Set-Reg $c 'Panneau Widgets (barre des tâches)' 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
    $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    Set-Reg $c 'Installation silencieuse d''applis suggérées' $cdm 'SilentInstalledAppsEnabled' 0
    Set-Reg $c 'Installation silencieuse d''applis suggérées' $cdm 'OemPreInstalledAppsEnabled' 0
    Set-Reg $c 'Installation silencieuse d''applis suggérées' $cdm 'PreInstalledAppsEnabled' 0
    Set-Reg $c 'Suggestions dans le menu Démarrer' $cdm 'SystemPaneSuggestionsEnabled' 0
    Set-Reg $c 'Suggestions dans le menu Démarrer' $cdm 'SubscribedContent-338388Enabled' 0
    Set-Reg $c 'Suggestions dans le menu Démarrer' 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_IrisRecommendations' 0
    Set-Reg $c 'Astuces et conseils Windows' $cdm 'SubscribedContent-338389Enabled' 0
    Set-Reg $c 'Astuces et conseils Windows' $cdm 'SoftLandingEnabled' 0
    Set-Reg $c 'Écran « Bienvenue » après les mises à jour' $cdm 'SubscribedContent-310093Enabled' 0
    Set-Reg $c '« Terminons la configuration de votre PC »' 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' 'ScoobeSystemSettingEnabled' 0
    Set-Reg $c 'Contenu suggéré dans Paramètres' $cdm 'SubscribedContent-338393Enabled' 0
    Set-Reg $c 'Contenu suggéré dans Paramètres' $cdm 'SubscribedContent-353694Enabled' 0
    Set-Reg $c 'Contenu suggéré dans Paramètres' $cdm 'SubscribedContent-353696Enabled' 0
    Set-Reg $c 'Astuces sur l''écran de verrouillage' $cdm 'SubscribedContent-338387Enabled' 0
    Set-Reg $c 'Astuces sur l''écran de verrouillage' $cdm 'RotatingLockScreenOverlayEnabled' 0
    Set-Reg $c 'Publicités dans l''Explorateur (OneDrive / Office)' 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowSyncProviderNotifications' 0
}

# ---------- Affichage du bilan ----------
function Show-Bilan([switch]$Plan) {
    $txt = @{ CHANGE = $(if ($Plan) { 'à désactiver' } else { 'désactivé' }); DEJA = 'déjà en place'; ABSENT = 'non présent'; ECHEC = 'échec' }
    $sym = @{ CHANGE = $(if ($Plan) { '[>]' } else { '[+]' }); DEJA = '[=]'; ABSENT = '[ ]'; ECHEC = '[!]' }
    $col = @{ CHANGE = $(if ($Plan) { 'Yellow' } else { 'Green' }); DEJA = 'DarkGray'; ABSENT = 'DarkGray'; ECHEC = 'Red' }
    $lignes = New-Object System.Collections.ArrayList
    $cats = $script:Bilan.Values | ForEach-Object { $_.Cat } | Select-Object -Unique
    foreach ($cat in $cats) {
        Write-Host ''; Write-Host "  $cat" -ForegroundColor Red
        [void]$lignes.Add(''); [void]$lignes.Add($cat)
        foreach ($b in ($script:Bilan.Values | Where-Object { $_.Cat -eq $cat })) {
            $l = "    $($sym[$b.Etat]) $($b.Label) — $($txt[$b.Etat])"
            if ($b.Detail) { $l += " ($($b.Detail))" }
            Write-Host $l -ForegroundColor $col[$b.Etat]
            [void]$lignes.Add($l)
        }
    }
    return , $lignes
}

# ---------- Point de restauration ----------
function New-PointRestauration {
    $debut = Get-Date
    $desc = "Avant confidentialité/debloat ($($debut.ToString('yyyy-MM-dd HH:mm')))"
    Write-Host ''; Write-Host '  Création du point de restauration (peut prendre une minute)…'
    try { Checkpoint-Computer -Description $desc -RestorePointType MODIFY_SETTINGS -WarningAction SilentlyContinue }
    catch {
        Write-Host "  Impossible : $($_.Exception.Message)" -ForegroundColor Yellow
        if (-not $Oui -and (Confirm-OuiNon "La protection du système est peut-être désactivée sur $env:SystemDrive. L'activer puis réessayer ?")) {
            try {
                Enable-ComputerRestore -Drive "$env:SystemDrive\"
                Checkpoint-Computer -Description $desc -RestorePointType MODIFY_SETTINGS -WarningAction SilentlyContinue
            } catch { Write-Host "  Toujours impossible : $($_.Exception.Message)" -ForegroundColor Yellow }
        }
    }
    $points = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue |
        ForEach-Object { [Management.ManagementDateTimeConverter]::ToDateTime($_.CreationTime) } | Sort-Object -Descending)
    if ($points.Count -and $points[0] -ge $debut.AddMinutes(-1)) { return @{ Etat = 'NOUVEAU'; Date = $points[0] } }
    if ($points.Count -and $points[0] -ge $debut.AddDays(-1)) { return @{ Etat = 'RECENT'; Date = $points[0] } }
    return @{ Etat = 'AUCUN' }
}

# ---------- Annulation depuis une sauvegarde ----------
function Invoke-Restauration([string]$Fichier) {
    $items = @(Get-Content -LiteralPath $Fichier -Raw -Encoding UTF8 | ConvertFrom-Json)
    $applis = @($items | Where-Object { $_.Type -eq 'Application' })
    $reglages = @($items | Where-Object { $_.Type -ne 'Application' })
    Write-Host "  Sauvegarde : $Fichier"
    Write-Host "  $($reglages.Count) réglage(s) à remettre comme avant."
    if (-not (Confirm-OuiNon 'Restaurer ces réglages ?')) { Write-Host '  Annulé : rien n''a été modifié.'; return }
    [array]::Reverse($reglages)
    $ok = 0; $ko = 0
    foreach ($i in $reglages) {
        try {
            switch ($i.Type) {
                'Registre' {
                    if ($i.Existait) {
                        if (-not (Test-Path -LiteralPath $i.Path)) { New-Item -Path $i.Path -Force | Out-Null }
                        $v = if ($i.TypeValeur -eq 'Binary') { [byte[]]$i.Ancien } else { $i.Ancien }
                        New-ItemProperty -LiteralPath $i.Path -Name $i.Name -Value $v -PropertyType $i.TypeValeur -Force | Out-Null
                    } else { Remove-ItemProperty -LiteralPath $i.Path -Name $i.Name -ErrorAction SilentlyContinue }
                }
                'Service' {
                    $out = & sc.exe config $i.Name start= $i.Demarrage
                    if ($LASTEXITCODE -ne 0) { throw "sc.exe : $($out -join ' ')" }
                }
                'Tache' { Enable-ScheduledTask -TaskPath $i.Path -TaskName $i.Name | Out-Null }
            }
            $ok++
        } catch { $ko++; Write-Host "  [!] $($i.Type) $($i.Name) : $($_.Exception.Message)" -ForegroundColor Red }
    }
    Write-Host ''
    Write-Host "  Restauré : $ok réglage(s), échec : $ko." -ForegroundColor Green
    if ($applis.Count) {
        Write-Host '  Applications supprimées (à réinstaller si besoin depuis le Microsoft Store) :'
        $applis | ForEach-Object { Write-Host "    - $($_.Name)" }
    }
    Write-Host '  Redémarrez le PC pour que tout s''applique.'
}

# ---------- Programme principal ----------
try {
    Write-Host ''
    Write-Host '  ' -NoNewline; Write-Host "$([char]0x26A1) PC//TOOLKIT" -ForegroundColor Red -NoNewline; Write-Host ' — confidentialité & désencombrement de Windows 11'

    if ($Restaurer) { Invoke-Restauration (Resolve-Path -LiteralPath $Restaurer).Path; Wait-Fin; exit 0 }

    Write-Host '  Analyse de la configuration actuelle (lecture seule)…'
    $script:DryRun = $true
    Invoke-Plan
    [void](Show-Bilan -Plan)
    $aFaire = @($script:Bilan.Values | Where-Object { $_.Etat -eq 'CHANGE' }).Count
    Write-Host ''
    Write-Host '  Conservés volontairement : Xbox Game Bar, Xbox Identity Provider, Gaming Services, appli Xbox, Microsoft Store.' -ForegroundColor DarkGray
    if (-not $aFaire) { Write-Host '  Rien à modifier : tout est déjà en place.' -ForegroundColor Green; Wait-Fin; exit 0 }
    if ($Apercu) { Write-Host "  Aperçu uniquement : $aFaire élément(s) seraient modifiés, rien n'a été changé."; Wait-Fin; exit 0 }
    if (-not (Confirm-OuiNon "Appliquer ces $aFaire modification(s) ?")) { Write-Host '  Annulé : rien n''a été modifié.'; Wait-Fin; exit 0 }

    $pr = New-PointRestauration
    switch ($pr.Etat) {
        'NOUVEAU' { Write-Host "  Point de restauration créé ($($pr.Date))." -ForegroundColor Green }
        'RECENT' {
            Write-Host "  Windows n'autorise qu'un point de restauration par 24 h. Le plus récent date du $($pr.Date) : il servira de retour arrière." -ForegroundColor Yellow
            if (-not (Confirm-OuiNon 'Continuer ?')) { Write-Host '  Annulé : rien n''a été modifié.'; Wait-Fin; exit 0 }
        }
        default {
            Write-Host '  Aucun point de restauration disponible.' -ForegroundColor Yellow
            if ($Oui -or -not (Confirm-OuiNon 'Continuer quand même ? (la sauvegarde permettra d''annuler les réglages, pas les applications)')) {
                Write-Host '  Annulé : rien n''a été modifié.'; Wait-Fin; exit 1
            }
        }
    }

    Write-Host ''; Write-Host '  Application des modifications…'
    $script:Bilan = [ordered]@{}
    $script:DryRun = $false
    Invoke-Plan

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    New-Item -ItemType Directory -Path $dossierSauv -Force | Out-Null
    $fJson = Join-Path $dossierSauv "confidentialite-$stamp.json"
    $json = if ($script:Sauvegarde.Count) { ConvertTo-Json -InputObject @($script:Sauvegarde) -Depth 4 } else { '[]' }
    [IO.File]::WriteAllText($fJson, $json, (New-Object Text.UTF8Encoding($false)))

    Write-Host ''; Write-Host '  ===== BILAN =====' -ForegroundColor Red
    $lignes = Show-Bilan
    $fTxt = Join-Path $dossierSauv "confidentialite-$stamp-bilan.txt"
    $entete = @("PC Toolkit — confidentialité & désencombrement — $(Get-Date -Format 'dd/MM/yyyy HH:mm')", "Point de restauration : $($pr.Etat) $($pr.Date)")
    [IO.File]::WriteAllLines($fTxt, [string[]](@($entete) + @($lignes)), (New-Object Text.UTF8Encoding($true)))

    $faits = @($script:Bilan.Values | Where-Object { $_.Etat -eq 'CHANGE' }).Count
    $echecs = @($script:Bilan.Values | Where-Object { $_.Etat -eq 'ECHEC' }).Count
    Write-Host ''
    Write-Host "  $faits élément(s) désactivé(s) ou supprimé(s), $echecs échec(s)." -ForegroundColor $(if ($echecs) { 'Yellow' } else { 'Green' })
    Write-Host "  Sauvegarde des anciennes valeurs : $fJson"
    Write-Host "  Bilan enregistré : $fTxt"
    Write-Host "  Pour annuler : .\Confidentialite-Debloat-Win11.ps1 -Restaurer `"$fJson`""
    if ((Get-CimInstance Win32_OperatingSystem).Caption -match 'Famille|Home') {
        Write-Host '  Windows Famille : le niveau de télémétrie reste au minimum « requis » (Windows ne permet pas moins) ; DiagTrack est coupé.' -ForegroundColor DarkGray
    }
    Write-Host '  Redémarrez le PC (ou déconnectez-vous) pour que tout s''applique — rien n''a été redémarré automatiquement.' -ForegroundColor Yellow
    Wait-Fin
} catch {
    Write-Host ''
    Write-Host "  Erreur : $($_.Exception.Message)" -ForegroundColor Red
    Wait-Fin
    exit 1
}
