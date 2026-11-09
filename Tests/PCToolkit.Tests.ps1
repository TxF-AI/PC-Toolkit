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
        $s = [ordered]@{ Date = '2026-01-01 10:00:00'; IsAdmin = $false; DiskFreeBytes = [long]100GB; RamUsedPct = 72; RamUsedMB = 23040; RamFreeMB = 8960; ServicesRunning = 145; Processes = 300; AudioGhost = 37; TempBytes = [long]2GB; RecycleBytes = [long]0; CacheBytes = [long]2GB }
        foreach ($k in $o.Keys) { $s[$k] = $o[$k] }
        [pscustomobject]$s
    }
    $avant = New-FakeSnap
    $apres = New-FakeSnap @{ DiskFreeBytes = [long](104.6 * 1GB); RamUsedPct = 54; RamUsedMB = 20700; RamFreeMB = 11300; ServicesRunning = 128; Processes = 290; AudioGhost = 0; CacheBytes = [long]0 }
    $rows = @(Get-SnapshotComparison -Before $avant -After $apres)
    function Get-Row([string]$Pattern) { $rows | Where-Object { $_.Indicateur -like $Pattern } }
    $bilan = New-BilanResult -Before $avant -After $apres -Operation 'test'
    $diag = New-DiagResult -Module 'Test' -Title 'Mon diagnostic' -Ctx $null
    Add-DiagSection $diag 'Section' -Body { param($s) Add-DiagItem $s 'Mesure' 'valeur' 'OK' }

    It 'Les 7 indicateurs demandés' {
        $rows.Count | Should Be 7
        ($rows.Indicateur -join '|') | Should Match 'Disque .* libre\|RAM utilisée\|RAM disponible\|Services actifs\|Processus\|Périphériques audio\|Fichiers temporaires'
    }
    It 'Disque : gain en Go libérés' {
        (Get-Row 'Disque*').Gain | Should Match '^\+4[,.]6 Go libérés$'
        (Get-Row 'Disque*').Status | Should Be 'OK'
    }
    It 'RAM : pourcentage, Go et Mo disponibles' {
        (Get-Row 'RAM utilisée').Avant | Should Match '^72 % \(22[,.]5 Go\)$'
        (Get-Row 'RAM utilisée').Gain | Should Match '^-18 % \(-2[,.]3 Go\)$'
        (Get-Row 'RAM utilisée').Status | Should Be 'OK'
        (Get-Row 'RAM disponible').Gain | Should Match '^\+2\D?340 Mo$'
    }
    It 'Services coupés, périphériques purgés, temporaires nettoyés' {
        (Get-Row 'Services*').Gain | Should Be '-17 services coupés'
        (Get-Row 'Périphériques*').Avant | Should Be '37 fantômes'
        (Get-Row 'Périphériques*').Apres | Should Be '0'
        (Get-Row 'Périphériques*').Gain | Should Be '-37 purgés'
        (Get-Row 'Fichiers*').Gain | Should Match '^-2[,.]0 Go nettoyés$'
    }
    It 'Processus : variation neutre (jamais présentée comme un gain)' {
        (Get-Row 'Processus').Gain | Should Be '-10 processus'
        (Get-Row 'Processus').Status | Should Be 'Info'
    }
    It 'Valeur identique = Aucun changement (neutre)' {
        $r = @(Get-SnapshotComparison -Before $avant -After $avant) | Where-Object { $_.Indicateur -like 'Services*' }
        $r.Gain | Should Be 'Aucun changement'
        $r.Status | Should Be 'Info'
    }
    It 'Dégradation signalée (Warn)' {
        $r = @(Get-SnapshotComparison -Before $avant -After (New-FakeSnap @{ ServicesRunning = 146 })) | Where-Object { $_.Indicateur -like 'Services*' }
        $r.Status | Should Be 'Warn'
        $r.Gain | Should Be '+1 service'
    }
    It 'Mesure manquante : Non disponible, jamais inventée' {
        $r = @(Get-SnapshotComparison -Before $avant -After (New-FakeSnap @{ DiskFreeBytes = $null; AudioGhost = $null })) | Where-Object { $_.Indicateur -like 'Disque*' -or $_.Indicateur -like 'Périphériques*' }
        @($r | Where-Object { $_.Status -eq 'NA' -and $_.Gain -eq 'Non disponible' -and $_.Apres -eq 'Non disponible' }).Count | Should Be 2
    }
    It 'Résultat standard : tableau Indicateur / Avant / Après / Gain net' {
        $bilan.Module | Should Be 'Bilan'
        $bilan.Sections.Count | Should Be 2
        ($bilan.Sections[1].Tables[0].Columns -join '|') | Should Be 'Indicateur|Avant|Après|Gain net'
        $bilan.Sections[1].Tables[0].Rows.Count | Should Be 7
    }
    It 'Export TXT : le bilan est ajouté automatiquement à la fin du rapport' {
        $f = Join-Path $TestDrive 'rapport.txt'
        [void](Export-DiagText -Results @($diag) -Bilan $bilan -Path $f)
        $t = Get-Content -LiteralPath $f -Raw -Encoding UTF8
        $t | Should Match "BILAN D'OPTIMISATION - PC TOOLKIT"
        $t | Should Match 'INDICATEUR +\| AVANT +\| APRÈS +\| GAIN / NET'
        $t | Should Match 'Services actifs +\| 145 +\| 128 +\| -17 services coupés'
        $t.IndexOf("BILAN D'OPTIMISATION") | Should BeGreaterThan $t.IndexOf('MON DIAGNOSTIC')
    }
    It 'Export TXT et HTML : même si le bilan est passé en premier dans -Results, il reste en dernier' {
        $f = Join-Path $TestDrive 'ordre.txt'
        [void](Export-DiagText -Results @($bilan, $diag) -Path $f)
        $t = Get-Content -LiteralPath $f -Raw -Encoding UTF8
        $t.IndexOf("BILAN D'OPTIMISATION") | Should BeGreaterThan $t.IndexOf('MON DIAGNOSTIC')
        $h = Join-Path $TestDrive 'ordre.html'
        [void](Export-DiagHtml -Results @($bilan, $diag) -Path $h)
        $x = Get-Content -LiteralPath $h -Raw -Encoding UTF8
        $x.IndexOf('Gain net') | Should BeGreaterThan $x.IndexOf('Mon diagnostic')
        $x | Should Match 'Services actifs'
    }
    It 'Export sans bilan : rapport inchangé (aucune section bilan)' {
        $f = Join-Path $TestDrive 'sans.txt'
        [void](Export-DiagText -Results @($diag) -Path $f)
        (Get-Content -LiteralPath $f -Raw -Encoding UTF8) | Should Not Match "BILAN D'OPTIMISATION"
    }
    It 'La photo réelle est lisible et n''écrit aucun fichier' {
        $dir = Join-Path $Root 'Data\Snapshots'
        $s = Get-SystemSnapshot -Ctx $null
        $s.Date | Should Not BeNullOrEmpty
        $s.DiskFreeBytes | Should BeGreaterThan 0
        $s.RamUsedPct | Should BeLessThan 101
        $s.ServicesRunning | Should BeGreaterThan 0
        $s.Processes | Should BeGreaterThan 0
        Test-Path $dir | Should Be $false
    }
    It 'Le flux est branché dans l''interface (baseline au diagnostic, bilan à la fin, export)' {
        $code = Get-Content -LiteralPath (Join-Path $Root 'PCToolkit.ps1') -Raw -Encoding UTF8
        $code | Should Match '-Baseline -OnComplete'
        $code | Should Match 'Set-BilanBaseline \$base'
        ([regex]::Matches($code, 'Complete-Bilan')).Count | Should BeGreaterThan 4
        ([regex]::Matches($code, 'Start-BilanCapture')).Count | Should BeGreaterThan 4
        $code | Should Match 'Export-Report \$Format @\(\$res\) \$bilan'
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

Describe 'Demarrage et Mode Performance' {
    It 'Octets StartupApproved : active = pair, desactive = impair avec date' {
        $on = Get-StartupApprovedBytes -Enabled $true
        $off = Get-StartupApprovedBytes -Enabled $false
        $on.Count | Should Be 12
        Test-StartupApprovedEnabled $on | Should Be $true
        Test-StartupApprovedEnabled $off | Should Be $false
        ([BitConverter]::ToInt64($off, 4)) -gt 0 | Should Be $true
    }
    It 'Valeur absente ou octet 6 = active, octet 3 ou 7 = desactive' {
        Test-StartupApprovedEnabled $null | Should Be $true
        Test-StartupApprovedEnabled ([byte[]](6, 0, 0, 0)) | Should Be $true
        Test-StartupApprovedEnabled ([byte[]](3, 0, 0, 0)) | Should Be $false
        Test-StartupApprovedEnabled ([byte[]](7, 0, 0, 0)) | Should Be $false
    }
    It 'Get-CommandExecutable gere guillemets, arguments et espaces' {
        Get-CommandExecutable '"C:\Program Files\App\app.exe" --minimized' | Should Be 'C:\Program Files\App\app.exe'
        Get-CommandExecutable 'C:\Program Files\App\app.exe /s' | Should Be 'C:\Program Files\App\app.exe'
        Get-CommandExecutable 'C:\Tools\run.exe' | Should Be 'C:\Tools\run.exe'
        Get-CommandExecutable '' | Should Be ''
    }
    It 'Get-StartupItems est en lecture seule et renvoie des champs complets' {
        $before = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue | Out-String)
        $e = @(Get-StartupItems)
        (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue | Out-String) | Should Be $before
        foreach ($x in $e) { [string]::IsNullOrEmpty([string]$x.Name) | Should Be $false; [string]::IsNullOrEmpty([string]$x.Source) | Should Be $false; ($x.Enabled -is [bool]) | Should Be $true }
    }
    It 'Set-StartupEntryState exige -Confirmed' {
        $en = [pscustomobject]@{ Name = 'x'; Scope = 'User'; ApprovedKey = 'HKCU:\Software\PCToolkitTest\A'; ValueName = 'x'; Source = 't' }
        { Set-StartupEntryState -Entry $en -Enabled $false } | Should Throw
    }
    It 'Desactiver puis reactiver ne touche que StartupApproved' {
        $key = 'HKCU:\Software\PCToolkitTest\Approved'
        try {
            $en = [pscustomobject]@{ Name = 'Test'; Scope = 'User'; ApprovedKey = $key; ValueName = 'Test'; Source = 'test' }
            Set-StartupEntryState -Entry $en -Enabled $false -Confirmed | Out-Null
            Test-StartupApprovedEnabled (Get-ItemProperty $key).Test | Should Be $false
            Set-StartupEntryState -Entry $en -Enabled $true -Confirmed | Out-Null
            Test-StartupApprovedEnabled (Get-ItemProperty $key).Test | Should Be $true
        } finally { Remove-Item 'HKCU:\Software\PCToolkitTest' -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'Un programme systeme est refuse sans droits administrateur' {
        if (Test-IsAdmin) { Set-TestInconclusive 'session administrateur'; return }
        $en = [pscustomobject]@{ Name = 'M'; Scope = 'Machine'; ApprovedKey = 'HKCU:\Software\PCToolkitTest\M'; ValueName = 'M'; Source = 't' }
        { Set-StartupEntryState -Entry $en -Enabled $false -Confirmed } | Should Throw
        Test-Path 'HKCU:\Software\PCToolkitTest' | Should Be $false
    }
    It 'Liste des services du mode : les 7 services prevus' {
        $n = @(Get-GameModeServiceList | ForEach-Object Name)
        foreach ($s in 'Spooler', 'SysMain', 'wuauserv', 'DiagTrack', 'MapsBroker', 'Fax', 'RemoteRegistry') { $n -contains $s | Should Be $true }
        $n.Count | Should Be 7
    }
    It 'Get-GameModeStatus est en lecture seule (pas de fichier d''etat cree)' {
        $p = Join-Path $TestDrive 'etat.json'
        $s = Get-GameModeStatus -StatePath $p
        $s.ModeActive | Should Be $false
        $s.Services.Count | Should Be 7
        Test-Path $p | Should Be $false
    }
    It 'Enable-GameMode et Restore-GameMode exigent -Confirmed' {
        { Enable-GameMode } | Should Throw
        { Restore-GameMode } | Should Throw
        { Invoke-RamTrim } | Should Throw
    }
    It 'Enable-GameMode sans droits administrateur ne modifie rien' {
        if (Test-IsAdmin) { Set-TestInconclusive 'session administrateur'; return }
        $p = Join-Path $TestDrive 'etat2.json'
        { Enable-GameMode -Confirmed -StatePath $p } | Should Throw
        Test-Path $p | Should Be $false
    }
    It 'Restore-GameMode sans etat sauvegarde refuse' {
        { Restore-GameMode -Confirmed -StatePath (Join-Path $TestDrive 'absent.json') } | Should Throw
    }
    It 'Restore-GameMode avec un etat vide supprime le fichier d''etat' {
        $p = Join-Path $TestDrive 'etat3.json'
        Write-GameModeState -Path $p -State ([ordered]@{ Date = 'x'; PreviousPlanGuid = $null; PreviousPlanName = $null; CreatedPlanGuid = $null; ServicesToStop = @(); ServicesStopped = @() })
        (Get-GameModeStatus -StatePath $p).ModeActive | Should Be $true
        $r = Restore-GameMode -Confirmed -StatePath $p
        $r.Started.Count | Should Be 0
        Test-Path $p | Should Be $false
    }
    It 'Etat sauvegarde : aller-retour JSON sans perte' {
        $p = Join-Path $TestDrive 'etat4.json'
        Write-GameModeState -Path $p -State ([ordered]@{ Date = 'd'; PreviousPlanGuid = 'g'; PreviousPlanName = 'Équilibré'; ServicesStopped = @('Spooler', 'SysMain') })
        $s = Read-GameModeState -Path $p
        $s.PreviousPlanName | Should Be 'Équilibré'
        @($s.ServicesStopped).Count | Should Be 2
    }
    It 'Les gains du Mode Performance apparaissent dans le bilan (services coupes, RAM)' {
        $b = [pscustomobject]@{ Date = '2026-01-01 10:00:00'; IsAdmin = $true; DiskFreeBytes = 1GB; RamUsedPct = 60.0; RamUsedMB = 9600; RamFreeMB = 6400; ServicesRunning = 120; Processes = 200; AudioGhost = 0; CacheBytes = 0 }
        $a = [pscustomobject]@{ Date = '2026-01-01 10:01:00'; IsAdmin = $true; DiskFreeBytes = 1GB; RamUsedPct = 55.0; RamUsedMB = 8800; RamFreeMB = 7200; ServicesRunning = 114; Processes = 198; AudioGhost = 0; CacheBytes = 0 }
        $rows = @(Get-SnapshotComparison -Before $b -After $a)
        ($rows | Where-Object Indicateur -eq 'Services actifs').Gain | Should Match '6 services coupés'
        ($rows | Where-Object Indicateur -eq 'RAM disponible').Status | Should Be 'OK'
    }
    It 'Garde-fou : l''interface branche les pages et le bilan' {
        $src = Get-Content -LiteralPath (Join-Path $Root 'PCToolkit.ps1') -Raw -Encoding UTF8
        $src | Should Match "'Startup' \{ Show-StartupPage \}"
        $src | Should Match "'Perf' \{ Show-PerfPage \}"
        $src | Should Match "Start-BilanCapture 'mode performance' -Force"
        $src | Should Match 'Enable-GameMode -Confirmed'
        $src | Should Match 'Restore-GameMode -Confirmed'
        $src | Should Match 'Set-StartupEntryState -Entry \$Entry -Enabled \$enable -Confirmed'
    }
}

Describe 'Modules : pas de fonction en double' {
    It 'Aucun nom de fonction n''est defini dans deux modules (le dernier importe ecraserait l''autre)' {
        $names = Get-ChildItem -LiteralPath (Join-Path $Root 'Modules') -Filter '*.psm1' | ForEach-Object {
            Select-String -LiteralPath $_.FullName -Pattern '^function\s+([\w-]+)' | ForEach-Object { $_.Matches[0].Groups[1].Value }
        }
        $dups = @($names | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name)
        ($dups -join ', ') | Should Be ''
    }
}
