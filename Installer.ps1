#requires -Version 5.1
<#
    Installation de PC Toolkit pour l'utilisateur courant
    ------------------------------------------------------
    - copie l'application dans %LocalAppData%\PCToolkit (aucun droit administrateur requis) ;
    - crée les raccourcis « ⚡ PC∕∕TOOLKIT » sur le Bureau et dans le menu Démarrer ;
    - une réinstallation met à jour les fichiers sans toucher à l'historique (Data\).
    - ajoute « PC Toolkit » dans Paramètres > Applications installées (clé HKCU, sans droits admin),
      ce qui permet de le désinstaller comme n'importe quelle application.
    Rien d'autre n'est modifié : pas de service, pas de démarrage automatique.

    Désinstallation : Paramètres > Applications installées > PC Toolkit, ou Desinstaller.ps1.

    Paramètres avancés (tests) : -Destination, -ShortcutFolders, -NoRegister, -Quiet (pas de question finale).
#>
param(
    [string]$Destination = (Join-Path $env:LOCALAPPDATA 'PCToolkit'),
    [string[]]$ShortcutFolders = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs')),
    [switch]$NoRegister,
    [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
$files = 'PCToolkit.ps1', 'app.ico', 'README.md', 'CHANGELOG.md', 'VERSION', 'Lancer PC Toolkit.cmd', 'Installer.cmd', 'Installer.ps1', 'Desinstaller.ps1'
$version = try { (Get-Content -LiteralPath (Join-Path $src 'VERSION') -TotalCount 1).Trim() } catch { '0.0.0' }
$dirs = 'Modules', 'UI', 'Lang'
# « / » est interdit dans un nom de fichier Windows : on utilise la barre de division Unicode (∕), identique à l'écran.
$shortcutName = [string][char]0x26A1 + ' PC' + [char]0x2215 + [char]0x2215 + 'TOOLKIT'

try {
    Write-Host ''
    Write-Host '  ' -NoNewline; Write-Host "$([char]0x26A1) PC//TOOLKIT" -ForegroundColor Red -NoNewline; Write-Host " $version — installation"
    Write-Host ''

    foreach ($x in @('PCToolkit.ps1', 'app.ico') + $dirs) {
        if (-not (Test-Path -LiteralPath (Join-Path $src $x))) { throw "Fichier manquant : $x. Extrayez tout le zip avant d'installer." }
    }

    # 1. Copie des fichiers (Data\ existant conservé)
    $dest = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
    if ((Resolve-Path -LiteralPath $src).Path.TrimEnd('\') -ne $dest) {
        Write-Host "  Copie vers $dest…"
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        foreach ($d in $dirs) {
            $t = Join-Path $dest $d
            if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Recurse -Force }
            Copy-Item -LiteralPath (Join-Path $src $d) -Destination $t -Recurse -Force
        }
        foreach ($f in $files) { $p = Join-Path $src $f; if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination $dest -Force } }
    } else { Write-Host '  Déjà dans le dossier d''installation : mise à jour des raccourcis seulement.' }

    # 2. Retire la marque « téléchargé depuis Internet » des fichiers installés (évite les avertissements Windows)
    Get-ChildItem -LiteralPath $dest -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

    # 3. Raccourcis
    $sh = New-Object -ComObject WScript.Shell
    foreach ($folder in $ShortcutFolders) {
        if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
        $lnk = Join-Path $folder "$shortcutName.lnk"
        # WScript.Shell ne gère pas ⚡ ni ∕ dans le nom : création sous un nom simple puis renommage
        $tmp = Join-Path $folder 'PCToolkit-temp.lnk'
        $s = $sh.CreateShortcut($tmp)
        $s.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $s.Arguments = "-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"$dest\PCToolkit.ps1`""
        $s.WorkingDirectory = $dest
        $s.IconLocation = "$dest\app.ico,0"
        $s.WindowStyle = 7   # minimisé : pas de flash de console
        $s.Description = 'PC Toolkit — maintenance et diagnostic'
        $s.Save()
        Move-Item -LiteralPath $tmp -Destination $lnk -Force
        Write-Host "  Raccourci créé : $lnk"
    }

    # 4. Entrée « Applications installées » (utilisateur courant uniquement)
    if (-not $NoRegister) {
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\PCToolkit'
        New-Item -Path $key -Force | Out-Null
        $sizeKb = [int]((Get-ChildItem -LiteralPath $dest -Recurse -File | Measure-Object Length -Sum).Sum / 1KB)
        $uninstall = "powershell.exe -ExecutionPolicy Bypass -NoProfile -File `"$dest\Desinstaller.ps1`""
        $values = [ordered]@{
            DisplayName = 'PC Toolkit'; DisplayVersion = $version; Publisher = 'PC Toolkit'
            DisplayIcon = "$dest\app.ico"; InstallLocation = $dest; UninstallString = $uninstall
            InstallDate = (Get-Date -Format 'yyyyMMdd')
        }
        foreach ($n in $values.Keys) { Set-ItemProperty -Path $key -Name $n -Value $values[$n] }
        foreach ($n in 'NoModify', 'NoRepair') { New-ItemProperty -Path $key -Name $n -Value 1 -PropertyType DWord -Force | Out-Null }
        New-ItemProperty -Path $key -Name EstimatedSize -Value $sizeKb -PropertyType DWord -Force | Out-Null
        Write-Host '  Ajouté à Paramètres > Applications installées (désinstallation possible depuis Windows).'
    }

    Write-Host ''
    Write-Host '  Installation terminée.' -ForegroundColor Green
    Write-Host '  Lancez PC Toolkit avec le raccourci du Bureau ou du menu Démarrer.'
    if (-not $Quiet) {
        $r = Read-Host '  Lancer PC Toolkit maintenant ? (O/N)'
        if ($r -match '^[oOyY]') { Start-Process powershell.exe -ArgumentList '-ExecutionPolicy', 'Bypass', '-NoProfile', '-WindowStyle', 'Hidden', '-File', "`"$dest\PCToolkit.ps1`"" }
    }
} catch {
    Write-Host ''
    Write-Host "  Échec de l'installation : $($_.Exception.Message)" -ForegroundColor Red
    if (-not $Quiet) { Read-Host '  Appuyez sur Entrée pour fermer' | Out-Null }
    exit 1
}
