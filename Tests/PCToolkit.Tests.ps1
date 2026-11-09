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

    It 'Les 11 indicateurs (8 de base + sécurité + profil d''optimisation)' {
        $rows.Count | Should Be 11
        foreach ($n in 'Disque*', 'RAM utilisée', 'RAM disponible', 'Services actifs', 'Processus', 'Périphériques audio', 'Programmes au démarrage', 'Éléments suspects actifs', 'Menaces en quarantaine', 'Profil d''optimisation', 'Fichiers temporaires') { @($rows | Where-Object { $_.Indicateur -like $n }).Count | Should Be 1 }
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
        $bilan.Sections[1].Tables[0].Rows.Count | Should Be 11
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

Describe 'Nettoyage automatique du demarrage' {
    function New-FakeEntry($Name, $Path, $Enabled = $true, $Scope = 'User', $Key = 'HKCU:\Software\PCToolkitTest\Auto') {
        [pscustomobject]@{ Name = $Name; Command = "`"$Path`""; Path = $Path; Source = 'test'; Scope = $Scope; Kind = 'Registry'; Enabled = $Enabled; Missing = $false; KeyPath = 'x'; ValueName = $Name; ApprovedKey = $Key }
    }
    $apps = 'C:\Users\x\AppData\Roaming'
    It 'Detecte les applications superflues connues' {
        foreach ($n in 'Spotify', 'Discord', 'Steam', 'Skype', 'OneDrive', 'GoogleUpdaterTaskUser157', 'SunJavaUpdateSched', 'MicrosoftEdgeAutoLaunch_ABC', 'Adobe Acrobat Update', 'CyberLink Launcher', 'Microsoft Teams') {
            (Get-StartupRule (New-FakeEntry $n "$apps\$n\$n.exe")) | Should Not Be $null
        }
    }
    It 'Liste blanche : pilotes graphiques, audio, securite et systeme ne sont jamais proteges a tort' {
        $prot = @(
            @('NVIDIA Display Container', 'C:\Program Files\NVIDIA Corporation\nvcpl.exe'), @('AMDNoiseSuppression', 'C:\Program Files\AMD\amd.exe'),
            @('Intel Graphics Software', 'C:\Program Files\Intel\igcc.exe'), @('RtkAudUService', 'C:\Windows\System32\RtkAudUService64.exe'),
            @('WavesLocalServer', 'C:\Program Files\Waves\wls.exe'), @('Focusrite Notifier', 'C:\Program Files\Focusrite\fn.exe'),
            @('SecurityHealth', 'C:\Windows\System32\SecurityHealthSystray.exe'), @('Windows Defender notify', 'C:\Program Files\Windows Defender\x.exe'),
            @('Avast Antivirus', 'C:\Program Files\Avast\avast.exe'), @('Riot Vanguard', 'C:\Program Files\Riot Vanguard\vgtray.exe'),
            @('Pilote ASIO4ALL', 'C:\Program Files\ASIO4ALL\a.exe'), @('Outil', 'C:\Windows\System32\quelquechose.exe'))
        foreach ($p in $prot) {
            $e = New-FakeEntry $p[0] $p[1]
            Test-StartupProtected $e | Should Be $true
            (Get-StartupRule $e) | Should Be $null
        }
    }
    It 'La liste blanche l''emporte meme si le nom evoque une cible (updater NVIDIA, Discord Audio)' {
        (Get-StartupRule (New-FakeEntry 'NVIDIA Updater' 'C:\Program Files\NVIDIA\updater.exe')) | Should Be $null
        (Get-StartupRule (New-FakeEntry 'Realtek Update Check' 'C:\Program Files\Realtek\u.exe')) | Should Be $null
    }
    It 'Un programme inconnu n''est pas touche' {
        (Get-StartupRule (New-FakeEntry 'MonOutilPerso' "$apps\MonOutil\outil.exe")) | Should Be $null
    }
    It 'Le plan ne retient que les cibles actives et compte les elements proteges' {
        $es = @((New-FakeEntry 'Spotify' "$apps\Spotify.exe"), (New-FakeEntry 'Discord' "$apps\Discord.exe" $false), (New-FakeEntry 'RtkAudUService' 'C:\Windows\System32\r.exe'), (New-FakeEntry 'MonOutilPerso' "$apps\o.exe"))
        $plan = Get-StartupCleanupPlan -Entries $es
        @($plan.Targets).Count | Should Be 1
        $plan.Targets[0].Name | Should Be 'Spotify'
        @($plan.Protected).Count | Should Be 1
    }
    It 'Les cibles systeme sont ecartees sans droits administrateur' {
        $plan = Get-StartupCleanupPlan -Entries @(New-FakeEntry 'Spotify' "$apps\s.exe" $true 'Machine') -AssumeAdmin:$false
        if (Test-IsAdmin) { Set-TestInconclusive 'session administrateur'; return }
        @($plan.Targets).Count | Should Be 0
        @($plan.NeedAdmin).Count | Should Be 1
    }
    It 'Invoke-StartupAutoClean et Restore-StartupBackup exigent -Confirmed' {
        { Invoke-StartupAutoClean } | Should Throw
        { Restore-StartupBackup } | Should Throw
    }
    It 'Nettoyage : sauvegarde, desactive les cibles, ignore la liste blanche meme forcee, puis restaure l''etat exact' {
        $key = 'HKCU:\Software\PCToolkitTest\Auto'
        $bk = Join-Path $TestDrive 'StartupBackup.json'
        try {
            [void](New-Item -Path $key -Force)
            # Spotify : valeur "activee" explicite (06) ; Discord : valeur absente
            Set-ItemProperty -LiteralPath $key -Name 'Spotify' -Value ([byte[]](6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) -Type Binary
            $es = @((New-FakeEntry 'Spotify' "$apps\Spotify.exe"), (New-FakeEntry 'Discord' "$apps\Discord.exe"), (New-FakeEntry 'RtkAudUService' 'C:\Windows\System32\r.exe'))
            $r = Invoke-StartupAutoClean -Confirmed -Entries $es -BackupPath $bk
            @($r.Disabled | ForEach-Object Name) -join ',' | Should Be 'Spotify,Discord'
            $r.Protected | Should Be 1
            Test-StartupApprovedEnabled (Get-ItemProperty $key).Spotify | Should Be $false
            Test-StartupApprovedEnabled (Get-ItemProperty $key).Discord | Should Be $false
            (Get-ItemProperty $key).PSObject.Properties.Name -contains 'RtkAudUService' | Should Be $false
            $b = Read-StartupBackup -Path $bk
            @($b.Items).Count | Should Be 2
            $rr = Restore-StartupBackup -Confirmed -BackupPath $bk
            @($rr.Restored).Count | Should Be 2
            ((Get-ItemProperty $key).Spotify)[0] | Should Be 6
            (Get-ItemProperty $key).PSObject.Properties.Name -contains 'Discord' | Should Be $false
            Test-Path $bk | Should Be $false
        } finally { Remove-Item 'HKCU:\Software\PCToolkitTest' -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'Sans cible, aucune sauvegarde n''est creee' {
        $bk = Join-Path $TestDrive 'vide.json'
        $r = Invoke-StartupAutoClean -Confirmed -Entries @(New-FakeEntry 'MonOutilPerso' "$apps\o.exe") -BackupPath $bk
        @($r.Disabled).Count | Should Be 0
        Test-Path $bk | Should Be $false
    }
    It 'Restauration sans sauvegarde : refus' {
        { Restore-StartupBackup -Confirmed -BackupPath (Join-Path $TestDrive 'rien.json') } | Should Throw
    }
    It 'Le bilan compte les programmes de demarrage purges' {
        $b = [pscustomobject]@{ Date = 'a'; IsAdmin = $true; StartupActive = 9 }
        $a = [pscustomobject]@{ Date = 'b'; IsAdmin = $true; StartupActive = 5 }
        $row = @(Get-SnapshotComparison -Before $b -After $a) | Where-Object Indicateur -eq 'Programmes au démarrage'
        $row.Gain | Should Be '-4 programmes purgés'
        $row.Status | Should Be 'OK'
    }
    It 'Garde-fou : l''interface appelle le nettoyage, la restauration et le bilan' {
        $src = Get-Content -LiteralPath (Join-Path $Root 'PCToolkit.ps1') -Raw -Encoding UTF8
        $src | Should Match 'Invoke-StartupAutoClean -Confirmed'
        $src | Should Match 'Restore-StartupBackup -Confirmed'
        $src | Should Match "Start-BilanCapture 'nettoyage du démarrage' -Force"
    }
}

Describe 'Security Guard : indices et heuristique' {
    function Get-ReasonText([string]$Path, [string]$Command, [string]$Signature) { (@(Get-SuspicionReasons -Path $Path -Command $Command -Signature $Signature) | ForEach-Object Reason) -join ' | ' }
    function Get-ScoreOf([string]$Path, [string]$Command, [string]$Signature) { $s = 0; foreach ($r in @(Get-SuspicionReasons -Path $Path -Command $Command -Signature $Signature)) { $s += $r.Weight }; $s }
    It 'Double extension (executable deguise en document)' {
        Get-ReasonText 'C:\Users\x\Downloads\facture.pdf.exe' '' 'NotSigned' | Should Match 'double extension'
    }
    It 'Caractere de lecture inversee dans le nom' {
        Get-ReasonText ('C:\x\photo' + [char]0x202E + 'gpj.exe') '' '' | Should Match 'lecture inversée'
    }
    It 'Executable non signe dans Temp => suspect' {
        $sc = Get-ScoreOf 'C:\Users\x\AppData\Local\Temp\a.exe' '' 'NotSigned'
        Get-ThreatLevel $sc | Should Be 'Crit'
    }
    It 'Programme legitime signe dans Program Files : aucun indice' {
        @(Get-SuspicionReasons -Path 'C:\Program Files\App\app.exe' -Signature 'Signed').Count | Should Be 0
    }
    It 'Nom de processus Windows hors du dossier Windows' {
        Get-ReasonText 'C:\Users\x\AppData\Roaming\svchost.exe' '' 'Signed' | Should Match 'processus Windows'
        Get-ReasonText 'C:\Windows\System32\svchost.exe' '' 'Signed' | Should Not Match 'processus Windows'
    }
    It 'Signature invalide = suspect' {
        Get-ThreatLevel (Get-ScoreOf 'C:\Program Files\App\a.exe' '' 'Invalid') | Should Be 'Crit'
    }
    It 'Commande PowerShell encodee' {
        Get-ReasonText '' ('powershell.exe -NoP -enc ' + ('A' * 30)) '' | Should Match 'encodée'
    }
    It 'Commande ordinaire : aucun indice' {
        @(Get-SuspicionReasons -Path 'C:\Windows\notepad.exe' -Command 'notepad.exe C:\a.txt' -Signature 'Signed').Count | Should Be 0
    }
    It 'Niveaux 0 / 2 / 4' {
        Get-ThreatLevel 0 | Should Be 'OK'
        Get-ThreatLevel 2 | Should Be 'Warn'
        Get-ThreatLevel 4 | Should Be 'Crit'
    }
    It 'Motif de test antivirus EICAR reconnu dans un texte (rien n est ecrit sur disque)' {
        $e = 'X5O!P%@AP[4\PZX54(P^)7CC)7}$' + 'EICAR-STANDARD-' + 'ANTIVIRUS-TEST-FILE!' + '$H+H*'
        @(Test-MaliciousScriptContent $e).Count | Should BeGreaterThan 0
    }
    It 'Script banal : aucun motif' {
        @(Test-MaliciousScriptContent "Write-Host 'bonjour'`nGet-ChildItem C:\").Count | Should Be 0
    }
    It 'Les scripts ne sont pas juges sur l absence de signature' {
        Get-FileSignatureState (Join-Path $Root 'PCToolkit.ps1') | Should Be 'NA'
        Get-FileSignatureState (Join-Path $Root 'inexistant.exe') | Should Be 'Missing'
    }
}

Describe 'Security Guard : scan de fichiers' {
    $dir = Join-Path $TestDrive 'scan'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $dir 'facture.pdf.exe') -Value 'faux executable de test'
    Set-Content -LiteralPath (Join-Path $dir 'outil.bat') -Value 'echo bonjour'
    Set-Content -LiteralPath (Join-Path $dir 'notes.txt') -Value 'ignore (extension non analysee)'
    $sha = (Get-FileHash -LiteralPath (Join-Path $dir 'outil.bat') -Algorithm SHA256).Hash.ToLower()
    $res = @(Invoke-FileHeuristicScan -Ctx $null -Path $dir -KnownHashes @{ $sha = 'Programme de test' })
    $sum = $res | Where-Object { $_.PSObject.Properties['ScanSummary'] } | Select-Object -Last 1
    $found = @($res | Where-Object { $_.PSObject.Properties['Level'] })
    It 'Resume : 2 fichiers analyses, le .txt est ignore' {
        $sum.Scanned | Should Be 2
        $sum.Hashed | Should Be 2
    }
    It 'Double extension signalee' {
        $f = $found | Where-Object Name -eq 'facture.pdf.exe'
        $f.Reasons | Should Match 'double extension'
        $f.Level | Should Be 'Crit'
    }
    It 'Empreinte connue signalee' {
        $f = $found | Where-Object Name -eq 'outil.bat'
        $f.Reasons | Should Match 'empreinte connue : Programme de test'
        $f.Sha256 | Should Be $sha
    }
    It 'Dossier sain : rien a signaler' {
        $clean = Join-Path $TestDrive 'propre'; New-Item -ItemType Directory -Path $clean -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $clean 'a.txt') -Value 'rien'
        $r = @(Invoke-FileHeuristicScan -Ctx $null -Path $clean)
        @($r | Where-Object { $_.PSObject.Properties['Level'] }).Count | Should Be 0
    }
    It 'Annulation respectee' {
        $r = @(Invoke-FileHeuristicScan -Ctx @{ Progress = 0; Status = ''; Cancel = $true } -Path $dir) | Where-Object { $_.PSObject.Properties['ScanSummary'] }
        $r.Cancelled | Should Be $true
    }
    It 'Chemin inexistant : erreur claire' {
        { Invoke-FileHeuristicScan -Ctx $null -Path (Join-Path $TestDrive 'nulle-part') } | Should Throw
    }
    It 'Le scan est en lecture seule (les fichiers sont toujours la)' {
        Test-Path (Join-Path $dir 'facture.pdf.exe') | Should Be $true
        Test-Path (Join-Path $dir 'outil.bat') | Should Be $true
    }
}

Describe 'Security Guard : quarantaine securisee' {
    $q = Join-Path $TestDrive 'quar'
    $src = Join-Path $TestDrive 'depot'
    New-Item -ItemType Directory -Path $src -Force | Out-Null
    $f = Join-Path $src 'suspect.exe'
    Set-Content -LiteralPath $f -Value 'contenu de test'
    $sha0 = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLower()
    It 'Refuse sans -Confirmed' {
        { Move-FileToQuarantine -Path $f -QuarantineDir $q } | Should Throw
        Test-Path $f | Should Be $true
    }
    It 'Isole le fichier (extension neutralisee), l inscrit dans l index, puis le restaure a l identique' {
        $item = Move-FileToQuarantine -Path $f -Reason 'test' -Confirmed -QuarantineDir $q
        Test-Path $f | Should Be $false
        $item.Stored | Should Match '\.quar$'
        Test-Path (Join-Path $q $item.Stored) | Should Be $true
        $item.Sha256 | Should Be $sha0
        @(Get-QuarantineItems -QuarantineDir $q).Count | Should Be 1
        [void](Restore-FromQuarantine -Id $item.Id -Confirmed -QuarantineDir $q)
        Test-Path $f | Should Be $true
        (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLower() | Should Be $sha0
        @(Get-QuarantineItems -QuarantineDir $q).Count | Should Be 0
    }
    It 'La restauration n ecrase jamais un fichier existant' {
        $item = Move-FileToQuarantine -Path $f -Confirmed -QuarantineDir $q
        Set-Content -LiteralPath $f -Value 'nouveau fichier au meme endroit'
        { Restore-FromQuarantine -Id $item.Id -Confirmed -QuarantineDir $q } | Should Throw
        (Get-Content -LiteralPath $f -Raw) | Should Match 'nouveau fichier'
        Remove-Item -LiteralPath $f -Force
        [void](Restore-FromQuarantine -Id $item.Id -Confirmed -QuarantineDir $q)
        Test-Path $f | Should Be $true
    }
    It 'Refuse les fichiers du dossier Windows' {
        { Move-FileToQuarantine -Path (Join-Path $env:windir 'System32\notepad.exe') -Confirmed -QuarantineDir $q } | Should Throw
        Test-Path (Join-Path $env:windir 'System32\notepad.exe') | Should Be $true
    }
    It 'Refuse les fichiers de PC Toolkit lui-meme' {
        { Move-FileToQuarantine -Path (Join-Path $Root 'PCToolkit.ps1') -Confirmed -QuarantineDir $q } | Should Throw
        Test-Path (Join-Path $Root 'PCToolkit.ps1') | Should Be $true
    }
    It 'Fichier introuvable : erreur claire' {
        { Move-FileToQuarantine -Path (Join-Path $src 'fantome.exe') -Confirmed -QuarantineDir $q } | Should Throw
    }
    It 'Les taches Microsoft ne sont jamais desactivees' {
        { Disable-SuspiciousTask -TaskName 'Test' -TaskPath '\Microsoft\Windows\Test\' -Confirmed -QuarantineDir $q } | Should Throw
        { Disable-SuspiciousTask -TaskName 'Test' -TaskPath '\Autre\' -QuarantineDir $q } | Should Throw
    }
    It 'La liste blanche du demarrage l emporte (pilote graphique)' {
        $e = [pscustomobject]@{ Name = 'NVIDIA Display Container'; Command = '"C:\Program Files\NVIDIA Corporation\nvcpl.exe"'; Path = 'C:\Program Files\NVIDIA Corporation\nvcpl.exe'; Source = 'test'; Scope = 'User'; Kind = 'Registry'; Enabled = $true; Missing = $false; KeyPath = 'x'; ValueName = 'NVIDIA'; ApprovedKey = 'HKCU:\Software\PCToolkitTest\Sec' }
        { Disable-SuspiciousStartup -Entry $e -Confirmed -QuarantineDir $q } | Should Throw
    }
    It 'Un programme de demarrage suspect se desactive (cle de test) et se reactive' {
        $key = 'HKCU:\Software\PCToolkitTest\Sec2'
        try {
            $e = [pscustomobject]@{ Name = 'Outil douteux'; Command = '"C:\Users\x\AppData\Local\Temp\x.exe"'; Path = 'C:\Users\x\AppData\Local\Temp\x.exe'; Source = 'test'; Scope = 'User'; Kind = 'Registry'; Enabled = $true; Missing = $false; KeyPath = 'x'; ValueName = 'OutilDouteux'; ApprovedKey = $key }
            $item = Disable-SuspiciousStartup -Entry $e -Reason 'test' -Confirmed -QuarantineDir $q
            Test-StartupApprovedEnabled ((Get-ItemProperty -LiteralPath $key -Name 'OutilDouteux').OutilDouteux) | Should Be $false
            @(Get-QuarantineItems -QuarantineDir $q | Where-Object Kind -eq 'Startup').Count | Should Be 1
            [void](Restore-FromQuarantine -Id $item.Id -Confirmed -QuarantineDir $q)
            Test-StartupApprovedEnabled ((Get-ItemProperty -LiteralPath $key -Name 'OutilDouteux').OutilDouteux) | Should Be $true
        } finally { Remove-Item -LiteralPath 'HKCU:\Software\PCToolkitTest' -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Security Guard : audit, rapport et bilan' {
    It 'Audit : lignes valides, en lecture seule' {
        $a = @(Invoke-SecurityAudit -Ctx $null)
        $a.Count | Should BeGreaterThan 0
        foreach ($x in $a) { $x.Status | Should Match '^(OK|Warn|Crit|Info|NA)$'; $x.Label | Should Not BeNullOrEmpty }
    }
    It 'Analyse rapide du demarrage : constats bien formes' {
        $p = @(Get-StartupThreatFindings -Ctx $null -Quick)
        foreach ($x in $p) { $x.Level | Should Match '^(OK|Warn|Crit)$' }
    }
    It 'Rapport exportable en TXT et HTML (resultat standard)' {
        $f1 = New-SecurityFinding -Kind 'Fichier' -Name 'facture.pdf.exe' -Path 'C:\x\facture.pdf.exe' -Signature 'NotSigned'
        $res = New-SecurityResult -Audit @([pscustomobject]@{ Label = 'Pare-feu'; Value = 'Actif'; Status = 'OK'; Detail = $null }) -Persistence @($f1) -FileScan $null
        $res.Module | Should Be 'Security'
        $t = Join-Path $TestDrive 'sec.txt'
        [void](Export-DiagText -Results @($res) -Path $t)
        (Get-Content -LiteralPath $t -Raw -Encoding UTF8) | Should Match 'double extension'
        $h = Join-Path $TestDrive 'sec.html'
        [void](Export-DiagHtml -Results @($res) -Path $h)
        (Get-Content -LiteralPath $h -Raw -Encoding UTF8) | Should Match 'facture.pdf.exe'
    }
    It 'Bilan : menaces neutralisees et profil d optimisation raccordes au tableau' {
        function Snap($o) { $s = [ordered]@{ Date = '2026-01-01 10:00:00'; IsAdmin = $false; DiskFreeBytes = [long]100GB; RamUsedPct = 50; RamUsedMB = 16000; RamFreeMB = 16000; ServicesRunning = 100; Processes = 200; AudioGhost = 0; StartupActive = 10; CacheBytes = [long]0; SuspectActive = 3; Quarantined = 0; TuningProfile = 'Aucun' }; foreach ($k in $o.Keys) { $s[$k] = $o[$k] }; [pscustomobject]$s }
        $rows = @(Get-SnapshotComparison -Before (Snap @{}) -After (Snap @{ SuspectActive = 1; Quarantined = 2; TuningProfile = 'Preset Jeu' }))
        $r1 = $rows | Where-Object { $_.Indicateur -eq 'Éléments suspects actifs' }
        $r1.Gain | Should Be '-2 neutralisés'; $r1.Status | Should Be 'OK'
        $r2 = $rows | Where-Object { $_.Indicateur -eq 'Menaces en quarantaine' }
        $r2.Gain | Should Be '+2 isolées'; $r2.Status | Should Be 'OK'
        $r3 = $rows | Where-Object { $_.Indicateur -like 'Profil d*optimisation' }
        $r3.Avant | Should Be 'Aucun'; $r3.Apres | Should Be 'Preset Jeu'; $r3.Gain | Should Be 'Preset Jeu appliqué'
    }
    It 'La photo reelle expose les nouvelles mesures' {
        $s = Get-SystemSnapshot -Ctx $null
        ($s.PSObject.Properties.Name -contains 'SuspectActive') | Should Be $true
        ($s.PSObject.Properties.Name -contains 'Quarantined') | Should Be $true
        $s.TuningProfile | Should Not BeNullOrEmpty
    }
}

Describe 'Presets d optimisation (Jeu / MAO / Bureautique)' {
    $profiles = @(Get-TuningProfiles)
    It 'Trois presets' {
        ($profiles.Id -join ',') | Should Be 'Game,MAO,Office'
    }
    It 'Services : sous-ensemble de la liste officielle, jamais un service audio' {
        $official = @(Get-GameModeServiceList | ForEach-Object Name)
        foreach ($p in $profiles) { foreach ($s in $p.Services) { ($official -contains $s) | Should Be $true; $s | Should Not Match 'Audio' } }
    }
    It 'MAO ne vide pas la RAM (les echantillons restent en memoire), Jeu oui' {
        ($profiles | Where-Object Id -eq 'MAO').FlushRam | Should Be $false
        ($profiles | Where-Object Id -eq 'Game').FlushRam | Should Be $true
    }
    It 'Bureautique : plan et demarrage inchanges, nettoyage des temporaires' {
        $o = $profiles | Where-Object Id -eq 'Office'
        $o.Power | Should Be $false; $o.CleanStartup | Should Be $false; $o.CleanTemp | Should Be $true
    }
    It 'Refuse sans -Confirmed et refuse un preset inconnu' {
        { Invoke-TuningProfile -Id 'Game' } | Should Throw
        { Invoke-TuningProfile -Id 'Inconnu' -Confirmed } | Should Throw
    }
    It 'L apercu est en lecture seule et decrit le preset' {
        $pl = Get-TuningPlan -Id 'Office'
        $pl.Profile.Id | Should Be 'Office'
        $pl.NeedsAdmin | Should Be $true
    }
    It 'Enable-GameMode accepte les options des presets (services limites, plan conserve, nom du profil)' {
        $k = (Get-Command Enable-GameMode).Parameters.Keys
        foreach ($n in 'OnlyServices', 'SkipPowerPlan', 'ProfileName') { ($k -contains $n) | Should Be $true }
    }
}

Describe 'Interface v1.5 : jauges, console, transitions, Security Guard' {
    $xaml = Get-Content -LiteralPath (Join-Path $Root 'UI\MainWindow.xaml') -Raw -Encoding UTF8
    $code = Get-Content -LiteralPath (Join-Path $Root 'PCToolkit.ps1') -Raw -Encoding UTF8
    It 'XAML : jauges CPU / RAM / disque, console, navigation Security Guard' {
        foreach ($n in 'GaugeCpu', 'GaugeRam', 'GaugeDisk', 'LogBox', 'BtnLogClear', 'NavSecurity') { $xaml | Should Match "x:Name=`"$n`"" }
    }
    It 'Code : animations et mise a jour en direct' {
        foreach ($f in 'Set-SmoothValue', 'Start-PageTransition', 'Update-LiveGauges', 'Update-LogConsole', 'Show-SecurityPage', 'Invoke-TuningPreset') { $code | Should Match "function $f" }
    }
    It 'Security Guard est une page, et ses actions passent par une confirmation' {
        $code | Should Match "Security\s+= @\{ Nav = 'NavSecurity'"
        $code | Should Match 'Move-FileToQuarantine -Path \$F\.Path -Reason \$F\.Reasons -Confirmed'
        ([regex]::Matches($code, 'Confirm-Action')).Count | Should BeGreaterThan 6
    }
    It 'Les neutralisations alimentent le bilan' {
        $code | Should Match 'Complete-Bilan -NoNavigate'
    }
}
