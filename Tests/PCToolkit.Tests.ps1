# Tests Pester 3.4 (fourni avec Windows) — lancer avec .\Run-Tests.ps1
$Root = Split-Path $PSScriptRoot -Parent
$ModDir = Join-Path $Root 'Modules'
Get-ChildItem -LiteralPath $ModDir -Filter '*.psm1' | ForEach-Object { Import-Module $_.FullName -Force -DisableNameChecking }

Describe 'Fichiers du projet' {
    $scripts = Get-ChildItem -LiteralPath $Root -Recurse -File |
        Where-Object { $_.Extension -in '.ps1', '.psm1' -and $_.FullName -notmatch '\\(graphify-out|Data|Reports)\\' }

    foreach ($f in $scripts) {
        It "$($f.Name) : syntaxe valide" {
            $err = $null
            [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$err)
            $err.Count | Should Be 0
        }
        It "$($f.Name) : UTF-8 avec BOM" {
            $b = [IO.File]::ReadAllBytes($f.FullName)
            ('{0},{1},{2}' -f $b[0], $b[1], $b[2]) | Should Be '239,187,191'
        }
    }

    It 'MainWindow.xaml est un XML valide' {
        { [xml](Get-Content -LiteralPath (Join-Path $Root 'UI\MainWindow.xaml') -Raw -Encoding UTF8) } | Should Not Throw
    }

    It 'Chaque élément XAML nommé utilisé par PCToolkit.ps1 existe' {
        $xaml = Get-Content -LiteralPath (Join-Path $Root 'UI\MainWindow.xaml') -Raw -Encoding UTF8
        $code = Get-Content -LiteralPath (Join-Path $Root 'PCToolkit.ps1') -Raw -Encoding UTF8
        $used = [regex]::Matches($code, '\$UI\.(\w+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        $missing = @($used | Where-Object { $xaml -notmatch "x:Name=`"$_`"" })
        ($missing -join ', ') | Should Be ''
    }
}

Describe 'Core' {
    It 'Get-AppVersion lit le fichier VERSION' {
        Get-AppVersion | Should Be (Get-Content -LiteralPath (Join-Path $Root 'VERSION') -TotalCount 1).Trim()
    }
    It 'Format-Bytes' {
        Format-Bytes 512 | Should Be '512 o'
        Format-Bytes (1.5GB) | Should Be ('{0:N1} Go' -f 1.5)
    }
    It 'Format-Span' {
        Format-Span (New-TimeSpan -Minutes 5) | Should Be '5 min'
        Format-Span (New-TimeSpan -Days 2 -Hours 3 -Minutes 7) | Should Be '2 j 3 h 07 min'
    }
    It 'ConvertTo-HtmlSafe échappe le HTML' {
        ConvertTo-HtmlSafe '<script>&' | Should Be '&lt;script&gt;&amp;'
    }
}

Describe 'Windows : fin de support (liste unique)' {
    It '23H2 a une date de fin de support' { Get-WindowsSupportEnd '23H2' | Should BeOfType [datetime] }
    It 'Version inconnue => rien' { Get-WindowsSupportEnd '99H9' | Should BeNullOrEmpty }
    It 'Version vide => rien' { Get-WindowsSupportEnd '' | Should BeNullOrEmpty }
}

Describe 'Réseau : statistiques de ping' {
    It 'Calcule pertes et moyenne' {
        $s = Get-PingStats @(10, 20, -1, 30)
        $s.Sent | Should Be 4
        $s.Received | Should Be 3
        $s.LossPct | Should Be 25
    }
    It 'Aucune réponse => NoReply' {
        (Get-PingStats @(-1, -1)).NoReply | Should Be $true
    }
}

Describe 'Maintenance : garde-fous de suppression' {
    $dir = Join-Path $TestDrive 'zone'
    $outside = Join-Path $TestDrive 'dehors.txt'

    BeforeEach {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'a.txt') -Value 'a'
        Set-Content -LiteralPath $outside -Value 'x'
    }

    It 'Refuse sans -Confirmed' {
        { Remove-FilesUnder -Files (Join-Path $dir 'a.txt') -Root $dir -Label 'Test Pester' } | Should Throw
        Test-Path (Join-Path $dir 'a.txt') | Should Be $true
    }
    It 'Supprime sous la racine, ignore ce qui est en dehors' {
        $r = Remove-FilesUnder -Files @((Join-Path $dir 'a.txt'), $outside) -Root $dir -Label 'Test Pester' -Confirmed
        $r.Deleted | Should Be 1
        $r.Skipped | Should Be 1
        Test-Path $outside | Should Be $true
    }
    It 'La commande SRUM sauvegarde la base et n''utilise pas netsh' {
        $cmd = Get-SrumResetCommand
        $cmd | Should Match 'sru\.sauvegarde-'
        $cmd | Should Not Match 'netsh'
        $err = $null; [void][Management.Automation.Language.Parser]::ParseInput($cmd, [ref]$null, [ref]$err)
        $err.Count | Should Be 0
    }
}

Describe 'Bilan avant/après (en mémoire)' {
    function New-FakeSnap($o = @{}) {
        $s = [ordered]@{ Date = '2026-01-01 10:00:00'; IsAdmin = $false; DiskFreeBytes = [long]100GB; RamUsedPct = 68; RamUsedMB = 21760; ServicesRunning = 142; AudioGhost = 37; TempBytes = [long]2GB; RecycleBytes = [long]0; CacheBytes = [long]2GB }
        foreach ($k in $o.Keys) { $s[$k] = $o[$k] }
        [pscustomobject]$s
    }
    $avant = New-FakeSnap
    $apres = New-FakeSnap @{ DiskFreeBytes = [long](104.6 * 1GB); RamUsedPct = 51; RamUsedMB = 19600; ServicesRunning = 128; AudioGhost = 0; CacheBytes = [long]0 }
    $rows = @(Get-SnapshotComparison -Before $avant -After $apres)
    function Get-Row([string]$Pattern) { $rows | Where-Object { $_.Indicateur -like $Pattern } }

    It 'Les 5 indicateurs demandés' {
        $rows.Count | Should Be 5
        ($rows.Indicateur -join '|') | Should Match 'Disque .* libre\|RAM utilisée\|Services actifs\|Périphériques audio fantômes\|Fichiers temporaires'
    }
    It 'Disque : gain en Go' {
        (Get-Row 'Disque*').Gain | Should Match '^\+4[,.]6 Go$'
        (Get-Row 'Disque*').Status | Should Be 'OK'
    }
    It 'RAM : pourcentage et Go' {
        (Get-Row 'RAM*').Avant | Should Match '^68 % \(21[,.]3 Go\)$'
        (Get-Row 'RAM*').Gain | Should Match '^-17 % \(-2[,.]1 Go\)$'
        (Get-Row 'RAM*').Status | Should Be 'OK'
    }
    It 'Services et fantômes purgés' {
        (Get-Row 'Services*').Gain | Should Be '-14 services'
        (Get-Row '*fantômes').Gain | Should Be '-37 fantômes'
        (Get-Row 'Fichiers*').Gain | Should Match '^-2[,.]0 Go$'
    }
    It 'Valeur identique = Aucun changement (neutre)' {
        $r = @(Get-SnapshotComparison -Before $avant -After $avant) | Where-Object { $_.Indicateur -like 'Services*' }
        $r.Gain | Should Be 'Aucun changement'
        $r.Status | Should Be 'Info'
    }
    It 'Dégradation signalée (Warn)' {
        $r = @(Get-SnapshotComparison -Before $avant -After (New-FakeSnap @{ ServicesRunning = 143 })) | Where-Object { $_.Indicateur -like 'Services*' }
        $r.Status | Should Be 'Warn'
        $r.Gain | Should Be '+1 service'
    }
    It 'Mesure manquante : Non disponible, jamais inventée' {
        $r = @(Get-SnapshotComparison -Before $avant -After (New-FakeSnap @{ DiskFreeBytes = $null; AudioGhost = $null })) | Where-Object { $_.Indicateur -like 'Disque*' -or $_.Indicateur -like '*fantômes' }
        @($r | Where-Object { $_.Status -eq 'NA' -and $_.Gain -eq 'Non disponible' -and $_.Apres -eq 'Non disponible' }).Count | Should Be 2
    }
    It 'Résultat standard : tableau Indicateur / Avant / Après / Gain net, exportable' {
        $res = New-BilanResult -Before $avant -After $apres -Operation 'test'
        $res.Module | Should Be 'Bilan'
        $res.Sections.Count | Should Be 2
        ($res.Sections[1].Tables[0].Columns -join '|') | Should Be 'Indicateur|Avant|Après|Gain net'
        $res.Sections[1].Tables[0].Rows.Count | Should Be 5
        $txt = (Format-TextTable $res.Sections[1].Tables[0]) -join "`n"
        $txt | Should Match 'Gain net'
    }
    It 'La photo réelle est lisible et n''écrit aucun fichier' {
        $dir = Join-Path $Root 'Data\Snapshots'
        $s = Get-SystemSnapshot -Ctx $null
        $s.Date | Should Not BeNullOrEmpty
        $s.DiskFreeBytes | Should BeGreaterThan 0
        $s.RamUsedPct | Should BeLessThan 101
        $s.ServicesRunning | Should BeGreaterThan 0
        Test-Path $dir | Should Be $false
    }
}

Describe 'Distribution : zip, installation, désinstallation' {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $version = (Get-Content -LiteralPath (Join-Path $Root 'VERSION') -TotalCount 1).Trim()

    It 'Build-Zip crée le zip et son empreinte, sans données personnelles' {
        & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'Build-Zip.ps1') -OutDir $TestDrive | Out-Null
        $zip = Join-Path $TestDrive "PC-Toolkit-v$version.zip"
        Test-Path $zip | Should Be $true
        Test-Path "$zip.sha256.txt" | Should Be $true
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $z = [IO.Compression.ZipFile]::OpenRead($zip)
        try { $names = @($z.Entries.FullName) } finally { $z.Dispose() }
        @($names | Where-Object { $_ -match '(Data|Reports|graphify-out|Tests)[\\/]|CLAUDE\.md|Build-Zip' }).Count | Should Be 0
        @($names | Where-Object { $_ -match 'Desinstaller\.ps1$' }).Count | Should Be 1
        Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $TestDrive 'extrait')
    }

    $src = Join-Path $TestDrive 'extrait\PC Toolkit'
    $dest = Join-Path $TestDrive 'install'
    $lnkDir = Join-Path $TestDrive 'raccourcis'

    It 'Installer copie les fichiers et crée le raccourci' {
        & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $src 'Installer.ps1') -Destination $dest -ShortcutFolders $lnkDir -NoRegister -Quiet | Out-Null
        Test-Path (Join-Path $dest 'PCToolkit.ps1') | Should Be $true
        @(Get-ChildItem -LiteralPath $lnkDir -Filter '*.lnk').Count | Should Be 1
    }

    It 'Desinstaller refuse un dossier qui n''est pas PC Toolkit' {
        & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dest 'Desinstaller.ps1') -InstallDir $lnkDir -ShortcutFolders $lnkDir -Quiet | Out-Null
        @(Get-ChildItem -LiteralPath $lnkDir -Filter '*.lnk').Count | Should Be 1
    }

    It 'Desinstaller retire le raccourci et le dossier, garde les autres raccourcis' {
        $w = New-Object -ComObject WScript.Shell
        $o = $w.CreateShortcut((Join-Path $lnkDir 'autre.lnk')); $o.TargetPath = "$env:windir\notepad.exe"; $o.Save()
        & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dest 'Desinstaller.ps1') -ShortcutFolders $lnkDir -Quiet | Out-Null
        Test-Path $dest | Should Be $false
        (Get-ChildItem -LiteralPath $lnkDir -Filter '*.lnk').Name | Should Be 'autre.lnk'
    }
}
