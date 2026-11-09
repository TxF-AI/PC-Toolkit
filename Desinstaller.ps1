#requires -Version 5.1
<#
    Désinstallation de PC Toolkit (utilisateur courant)
    ---------------------------------------------------
    Lancée depuis « Paramètres > Applications installées » ou à la main.
    - retire les raccourcis « ⚡ PC∕∕TOOLKIT » qui pointent vers CETTE installation ;
    - retire l'entrée « PC Toolkit » des applications installées ;
    - supprime le dossier d'installation (l'historique Data\ peut être conservé).
    Rien n'est supprimé sans confirmation, sauf avec -Quiet (tests).

    Paramètres : -InstallDir, -ShortcutFolders, -KeepData, -Quiet.
#>
param(
    [string]$InstallDir = $PSScriptRoot,
    [string[]]$ShortcutFolders = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs')),
    [switch]$KeepData,
    [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
# Langue (FR / EN) : repli sur la clé si le module est absent
try { Import-Module (Join-Path $PSScriptRoot 'Modules\I18n.psm1') -Force -DisableNameChecking } catch { function Get-Text { param([string]$Key) $Key } }
$regKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\PCToolkit'

try {
    $dir = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
    Write-Host ''
    Write-Host '  ' -NoNewline; Write-Host "$([char]0x26A1) PC//TOOLKIT" -ForegroundColor Red -NoNewline; Write-Host (Get-Text 'Uni.004')
    Write-Host ''

    # Garde-fou : on ne supprime qu'un dossier qui est bien une installation de PC Toolkit
    if (-not (Test-Path -LiteralPath (Join-Path $dir 'PCToolkit.ps1')) -or -not (Test-Path -LiteralPath (Join-Path $dir 'Modules\Core.psm1'))) {
        throw (Get-Text 'Uni.005' $dir)
    }
    $forbidden = @($env:SystemDrive + '\', $env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA, $env:windir, [Environment]::GetFolderPath('Desktop')) | ForEach-Object { $_.TrimEnd('\') }
    if ($forbidden -contains $dir) { throw (Get-Text 'Uni.007' $dir) }

    $hasData = Test-Path -LiteralPath (Join-Path $dir 'Data')
    if (-not $Quiet) {
        Write-Host (Get-Text 'Uni.009' $dir)
        $r = Read-Host (Get-Text 'Uni.010')
        if ($r -notmatch '^[oOyY]') { Write-Host (Get-Text 'Uni.011'); exit 0 }
        if ($hasData -and -not $KeepData) {
            $k = Read-Host (Get-Text 'Uni.012')
            $KeepData = $k -match '^[oOyY]'
        }
    }

    # 1. Raccourcis pointant vers cette installation
    # Shell.Application lit les raccourcis au nom Unicode (⚡), contrairement à WScript.Shell
    $shell = New-Object -ComObject Shell.Application
    $target = Join-Path $dir 'PCToolkit.ps1'
    foreach ($folder in $ShortcutFolders) {
        if (-not (Test-Path -LiteralPath $folder)) { continue }
        $ns = $shell.Namespace($folder)
        foreach ($lnk in Get-ChildItem -LiteralPath $folder -Filter '*.lnk' -File) {
            $lnkArgs = try { $ns.ParseName($lnk.Name).GetLink.Arguments } catch { '' }
            if ($lnkArgs -like "*`"$target`"*") {
                Remove-Item -LiteralPath $lnk.FullName -Force
                Write-Host (Get-Text 'Uni.013' $($lnk.FullName))
            }
        }
    }

    # 2. Entrée « Applications installées » (seulement si elle désigne ce dossier)
    if (Test-Path $regKey) {
        $loc = (Get-ItemProperty $regKey -ErrorAction SilentlyContinue).InstallLocation
        if ($loc -and $loc.TrimEnd('\') -eq $dir) { Remove-Item $regKey -Recurse -Force; Write-Host (Get-Text 'Uni.014') }
    }

    # 3. Fichiers (le script lui-même est déjà en mémoire : il peut être supprimé)
    Set-Location -LiteralPath $env:TEMP
    foreach ($item in Get-ChildItem -LiteralPath $dir -Force) {
        if ($KeepData -and $item.Name -eq 'Data') { continue }
        Remove-Item -LiteralPath $item.FullName -Recurse -Force
    }
    if (-not $KeepData -or -not $hasData) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }

    Write-Host ''
    Write-Host (Get-Text 'Uni.016') -ForegroundColor Green
    if ($KeepData -and $hasData) { Write-Host (Get-Text 'Uni.017' $dir) }
    if (-not $Quiet) { Read-Host (Get-Text 'Uni.018') | Out-Null }
} catch {
    Write-Host ''
    Write-Host (Get-Text 'Uni.019' $($_.Exception.Message)) -ForegroundColor Red
    if (-not $Quiet) { Read-Host (Get-Text 'Uni.020') | Out-Null }
    exit 1
}
