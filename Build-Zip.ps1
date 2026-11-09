#requires -Version 5.1
<#
    Fabrique le zip à partager : PC-Toolkit-v<VERSION>.zip + empreinte SHA-256.
    - liste blanche de fichiers : jamais d'historique (Data), de rapports, ni de fichiers de développement ;
    - contrôle avant emballage : syntaxe des scripts, encodage UTF-8 avec BOM, XAML valide.
    Usage : clic droit > Exécuter avec PowerShell, ou  powershell -File Build-Zip.ps1 [-OutDir <dossier>]
#>
param([string]$OutDir = [Environment]::GetFolderPath('Desktop'))
$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
$version = (Get-Content -LiteralPath (Join-Path $src 'VERSION') -TotalCount 1).Trim()
$include = 'PCToolkit.ps1', 'app.ico', 'README.md', 'CHANGELOG.md', 'VERSION', 'Lancer PC Toolkit.cmd', 'Installer.cmd', 'Installer.ps1', 'Desinstaller.ps1', 'Modules', 'UI'

# 1. Contrôles
$problems = @()
foreach ($i in $include) { if (-not (Test-Path -LiteralPath (Join-Path $src $i))) { $problems += "manquant : $i" } }
foreach ($f in Get-ChildItem -LiteralPath $src -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1' -and $_.FullName -notmatch '\\(graphify-out|Data|Reports)\\' }) {
    $err = $null; [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$err)
    if ($err.Count) { $problems += "syntaxe : $($f.Name) ligne $($err[0].Extent.StartLineNumber) — $($err[0].Message)" }
    $b = [IO.File]::ReadAllBytes($f.FullName)
    if ($b.Length -lt 3 -or $b[0] -ne 0xEF -or $b[1] -ne 0xBB -or $b[2] -ne 0xBF) { $problems += "encodage : $($f.Name) n'est pas en UTF-8 avec BOM" }
}
try { [xml](Get-Content -LiteralPath (Join-Path $src 'UI\MainWindow.xaml') -Raw -Encoding UTF8) | Out-Null } catch { $problems += 'XAML invalide' }
if ($problems) { $problems | ForEach-Object { Write-Host "  ✖ $_" -ForegroundColor Red }; throw "$($problems.Count) problème(s) : zip non créé." }

# 2. Copie de travail puis zip (dossier racine « PC Toolkit » dans l'archive)
$stage = Join-Path $env:TEMP ('PCToolkit-build-' + [guid]::NewGuid().ToString('N'))
$root = Join-Path $stage 'PC Toolkit'
New-Item -ItemType Directory -Path $root -Force | Out-Null
try {
    foreach ($i in $include) { Copy-Item -LiteralPath (Join-Path $src $i) -Destination $root -Recurse -Force }
    $zip = Join-Path $OutDir "PC-Toolkit-v$version.zip"
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    Compress-Archive -Path $root -DestinationPath $zip -CompressionLevel Optimal
} finally { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }

# 3. Empreinte (permet au destinataire de vérifier que le fichier n'a pas été modifié)
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
$hashFile = "$zip.sha256.txt"
[IO.File]::WriteAllText($hashFile, "$hash  $(Split-Path $zip -Leaf)`r`n", (New-Object Text.UTF8Encoding($false)))

Write-Host ''
Write-Host "  Zip créé : $zip ($([math]::Round((Get-Item $zip).Length / 1KB)) Ko)" -ForegroundColor Green
Write-Host "  SHA-256  : $hash"
Write-Host "  Empreinte enregistrée dans : $hashFile"
