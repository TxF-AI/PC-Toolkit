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
