#requires -Version 5.1
<#
    Performance.psm1 — Gestionnaire de démarrage et Mode Performance (Game Mode)
    ---------------------------------------------------------------------------
    1. Démarrage : liste les programmes lancés avec Windows (clés Run, dossiers Démarrage) et les active /
       désactive par le mécanisme natif de Windows (clés « StartupApproved », celles du Gestionnaire des tâches).
       Aucune clé ni aucun raccourci n'est supprimé ou déplacé : réactiver remet exactement l'état d'origine.
    2. Mode Performance : plan d'alimentation haute performance + arrêt temporaire de services secondaires,
       avec sauvegarde de l'état dans Data\GameMode.json pour tout remettre en un clic (même après un redémarrage de l'appli).
    Toute modification exige -Confirmed et est journalisée. Les lectures ne modifient rien.
#>

$script:UltimateGuid = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$script:HighPerfGuid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'

# Services secondaires arrêtés par le Mode Performance (aucun n'est nécessaire à un jeu ou à une session MAO)
$script:GameModeServiceList = @(
    @{ Name = 'Spooler';        Why = 'Prf.002' }
    @{ Name = 'SysMain';        Why = 'Prf.004' }
    @{ Name = 'wuauserv';       Why = 'Prf.006' }
    @{ Name = 'DiagTrack';      Why = 'Prf.008' }
    @{ Name = 'MapsBroker';     Why = 'Prf.010' }
    @{ Name = 'Fax';            Why = 'Prf.011' }
    @{ Name = 'RemoteRegistry'; Why = 'Prf.013' }
)

#region Démarrage ---------------------------------------------------------------------------

function Get-StartupApprovedBytes {
    <# Valeur binaire « StartupApproved » : 03 = désactivé (+ date), 02 = activé. Format utilisé par Windows lui-même. #>
    param([Parameter(Mandatory)][bool]$Enabled)
    $b = New-Object byte[] 12
    if ($Enabled) { $b[0] = 2 }
    else {
        $b[0] = 3
        [BitConverter]::GetBytes((Get-Date).ToFileTime()).CopyTo($b, 4)
    }
    , $b
}

function Test-StartupApprovedEnabled {
    <# Octet 0 pair (2, 6…) = activé ; impair (3, 7…) = désactivé ; valeur absente = activé. #>
    param($Bytes)
    if ($null -eq $Bytes -or @($Bytes).Count -eq 0) { return $true }
    (([int]@($Bytes)[0]) % 2) -eq 0
}

function Get-CommandExecutable {
    <# Extrait le chemin du programme d'une ligne de commande de démarrage (avec ou sans guillemets). #>
    param([string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return '' }
    $c = [Environment]::ExpandEnvironmentVariables($Command.Trim())
    if ($c -match '^"([^"]+)"') { return $Matches[1] }
    if ($c -match '^(.+?\.(?:exe|bat|cmd|com|lnk|vbs|ps1|msc|cpl))(\s|$)') { return $Matches[1] }
    ($c -split '\s+')[0]
}

function Get-StartupItems {
    <#
        Lecture seule. Une ligne par programme de démarrage :
        Name, Command, Path, Source, Scope (User|Machine), Kind (Registry|Folder), Enabled, Missing, KeyPath, ValueName, ApprovedKey.
    #>
    param()
    $out = New-Object System.Collections.ArrayList
    $approvedRoot = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'

    $regSources = @(
        @{ Hive = 'HKCU'; Key = 'Software\Microsoft\Windows\CurrentVersion\Run';             Approved = 'Run';   Scope = 'User';    Source = (Get-Text 'Prf.016') }
        @{ Hive = 'HKLM'; Key = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run';             Approved = 'Run';   Scope = 'Machine'; Source = (Get-Text 'Prf.019') }
        @{ Hive = 'HKLM'; Key = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = 'Run32'; Scope = 'Machine'; Source = (Get-Text 'Prf.022') }
    )
    foreach ($s in $regSources) {
        try {
            $path = "$($s.Hive):\$($s.Key)"
            if (-not (Test-Path -LiteralPath $path)) { continue }
            $approvedKey = "$($s.Hive):\$approvedRoot\$($s.Approved)"
            $item = Get-Item -LiteralPath $path -ErrorAction Stop
            foreach ($n in $item.GetValueNames()) {
                if ([string]::IsNullOrEmpty($n)) { continue }
                $cmd = [string]$item.GetValue($n)
                $bytes = $null
                try { $bytes = (Get-ItemProperty -LiteralPath $approvedKey -Name $n -ErrorAction Stop).$n } catch { }
                $exe = Get-CommandExecutable $cmd
                [void]$out.Add([pscustomobject]@{
                    Name = $n; Command = $cmd; Path = $exe; Source = $s.Source; Scope = $s.Scope; Kind = 'Registry'
                    Enabled = (Test-StartupApprovedEnabled $bytes)
                    Missing = [bool]($exe -and ($exe -match '^[A-Za-z]:\\') -and -not (Test-Path -LiteralPath $exe))
                    KeyPath = $path; ValueName = $n; ApprovedKey = $approvedKey
                })
            }
        } catch { Write-AppLog (Get-Text 'Prf.024' $($s.Hive) $($_.Exception.Message)) 'WARN' }
    }

    $folders = @(
        @{ Dir = (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'); Scope = 'User';    Source = (Get-Text 'Prf.027'); Hive = 'HKCU' }
        @{ Dir = (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\StartUp'); Scope = 'Machine'; Source = (Get-Text 'Prf.031'); Hive = 'HKLM' }
    )
    $shell = $null
    foreach ($f in $folders) {
        try {
            if (-not (Test-Path -LiteralPath $f.Dir)) { continue }
            $approvedKey = "$($f.Hive):\$approvedRoot\StartupFolder"
            foreach ($file in @(Get-ChildItem -LiteralPath $f.Dir -File -Force -ErrorAction Stop | Where-Object { $_.Name -ne 'desktop.ini' })) {
                $target = $file.FullName
                if ($file.Extension -eq '.lnk') {
                    try {
                        if (-not $shell) { $shell = New-Object -ComObject WScript.Shell }
                        $t = $shell.CreateShortcut($file.FullName).TargetPath
                        if ($t) { $target = $t }
                    } catch { }
                }
                $bytes = $null
                try { $bytes = (Get-ItemProperty -LiteralPath $approvedKey -Name $file.Name -ErrorAction Stop).($file.Name) } catch { }
                [void]$out.Add([pscustomobject]@{
                    Name = [IO.Path]::GetFileNameWithoutExtension($file.Name); Command = $file.FullName; Path = $target; Source = $f.Source; Scope = $f.Scope; Kind = 'Folder'
                    Enabled = (Test-StartupApprovedEnabled $bytes)
                    Missing = [bool](($target -match '^[A-Za-z]:\\') -and -not (Test-Path -LiteralPath $target))
                    KeyPath = $f.Dir; ValueName = $file.Name; ApprovedKey = $approvedKey
                })
            }
        } catch { Write-AppLog (Get-Text 'Prf.034' $($f.Dir) $($_.Exception.Message)) 'WARN' }
    }
    if ($shell) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) } catch { } }
    @($out | Sort-Object @{ Expression = { -not $_.Enabled } }, Name)   # actifs d'abord
}

function Set-StartupEntryState {
    <# Active ou désactive UN programme de démarrage (écrit seulement la clé StartupApproved). Exige -Confirmed. #>
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][bool]$Enabled,
        [switch]$Confirmed
    )
    if (-not $Confirmed) { throw (Get-Text 'Prf.035') }
    if ($Entry.Scope -eq 'Machine' -and -not (Test-IsAdmin)) { throw (Get-Text 'Prf.037') }
    if (-not $Entry.ApprovedKey -or -not $Entry.ValueName) { throw (Get-Text 'Prf.038') }
    try {
        if (-not (Test-Path -LiteralPath $Entry.ApprovedKey)) { [void](New-Item -Path $Entry.ApprovedKey -Force -ErrorAction Stop) }
        Set-ItemProperty -LiteralPath $Entry.ApprovedKey -Name $Entry.ValueName -Value (Get-StartupApprovedBytes -Enabled $Enabled) -Type Binary -ErrorAction Stop
    } catch {
        Write-AppLog (Get-Text 'Prf.039' $($Entry.Name) $($_.Exception.Message)) 'ERROR'
        throw (Get-Text 'Prf.041' $($Entry.Name) $($_.Exception.Message))
    }
    Write-AppLog ((Get-Text 'Prf.042') -f $Entry.Name, $(if ($Enabled) { (Get-Text 'Prf.043') } else { (Get-Text 'Prf.044') }), $Entry.Source) 'ACTION'
    $true
}

#endregion

#region Nettoyage automatique du démarrage --------------------------------------------------

# LISTE BLANCHE : ces éléments ne sont JAMAIS désactivés automatiquement (pilotes graphiques et audio, sécurité,
# anti-triche, utilitaires système). Elle l'emporte toujours sur la liste de cibles. En cas de doute : protégé.
$script:StartupProtectPattern = '(?i)nvidia|nvcpl|nvbackend|nvtray|geforce|nvdisplay|\bamd\b|radeon|ati2|atieclxx|atiesrxx|cnext|igfx|intel|igcc|realtek|\brtk|ravbg|waves|maxx|asio|focusrite|goxlr|tc.?helicon|steinberg|native instruments|presonus|audio|sound|defender|windows security|securityhealth|mpcmdrun|msmpeng|antimalware|kaspersky|avast|\bavg\b|norton|mcafee|bitdefender|\beset\b|malwarebytes|sophos|trend micro|vanguard|vgc|vgtray|easyanticheat|battleye|faceit|ctfmon|explorer\.exe|sihost|synaptics|touchpad|bluetooth|[a-z]:\\windows\\(system32|syswow64)'

# CIBLES : applications de confort qui n'ont pas besoin de démarrer avec Windows (elles s'ouvrent à la demande).
$script:StartupTargetRules = @(
    @{ Category = 'Prf.047';          Label = 'Prf.048'; Pattern = '(?i)googleupdate|google ?updater|adobe.*(update|arm\b|aam)|adobegc|armsvc|jusched|sunjavaupdate|java update|microsoftedgeautolaunch|edgeupdate|microsoft edge update|update ?sched|update ?check|updater' }
    @{ Category = 'Prf.050';           Label = 'Prf.051';          Pattern = '(?i)telemetry|customer ?experience|\bceip\b' }
    @{ Category = 'Prf.053'; Label = 'Prf.054';        Pattern = '(?i)spotify|discord|\bsteam(\.exe|webhelper|\b)|skype|\bteams\b|msteams|cyberlink|powerdvd|youcam|epic ?games|rockstar|riotclient|riot client|curseforge|\bmedal\b|roblox|utweb|btweb|utorrent|bittorrent|slack|zoom|wondershare' }
    @{ Category = 'Prf.056'; Label = 'Prf.057'; Pattern = '(?i)onedrive|dropbox|creative ?cloud|ccxprocess' }
)

function Get-StartupBackupPath { Join-Path (Join-Path (Get-AppPath Root) 'Data') 'StartupBackup.json' }

function Test-StartupProtected {
    <# Vrai si l'élément est sur la liste blanche (nom, chemin ou commande). #>
    param([Parameter(Mandatory)]$Entry)
    $txt = "{0} {1} {2}" -f $Entry.Name, $Entry.Path, $Entry.Command
    $txt -match $script:StartupProtectPattern
}

function Get-StartupRule {
    <# Règle de nettoyage applicable ($null si aucune ou si l'élément est protégé). #>
    param([Parameter(Mandatory)]$Entry)
    if (Test-StartupProtected $Entry) { return $null }
    $txt = "{0} {1} {2}" -f $Entry.Name, $Entry.Path, $Entry.Command
    foreach ($r in $script:StartupTargetRules) { if ($txt -match $r.Pattern) { return [pscustomobject]@{ Category = (Get-Text $r.Category); Label = (Get-Text $r.Label) } } }
    $null
}

function Get-StartupCleanupPlan {
    <# Lecture seule. Targets : à désactiver ; Protected : listés protégés ; NeedAdmin : cibles système sans droits admin. #>
    param($Entries, [switch]$AssumeAdmin)
    if ($null -eq $Entries) { $Entries = @(Get-StartupItems) }
    $isAdmin = $AssumeAdmin -or (Test-IsAdmin)
    $targets = @(); $protected = @(); $needAdmin = @()
    foreach ($e in @($Entries)) {
        if (Test-StartupProtected $e) { $protected += $e; continue }
        if (-not $e.Enabled) { continue }
        $rule = Get-StartupRule $e
        if (-not $rule) { continue }
        $item = [pscustomobject]@{ Entry = $e; Name = $e.Name; Category = $rule.Category; Label = $rule.Label; Source = $e.Source }
        if ($e.Scope -eq 'Machine' -and -not $isAdmin) { $needAdmin += $item } else { $targets += $item }
    }
    [pscustomobject]@{ Targets = @($targets); NeedAdmin = @($needAdmin); Protected = @($protected) }
}

function Read-StartupBackup {
    param([string]$Path)
    if (-not $Path) { $Path = Get-StartupBackupPath }
    try { if (Test-Path -LiteralPath $Path) { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } } catch { Write-AppLog (Get-Text 'Prf.061' $($_.Exception.Message)) 'WARN' }
    $null
}

function Write-StartupBackup {
    param([string]$Path, [Parameter(Mandatory)]$Items)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    if (@($Items).Count -eq 0) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue; return }
    $obj = [ordered]@{ Date = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Items = @($Items) }
    [IO.File]::WriteAllText($Path, ($obj | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
}

function Invoke-StartupAutoClean {
    <#
        Désactive les programmes de démarrage superflus (StartupApproved uniquement, rien n'est supprimé).
        L'état initial de chaque élément est écrit dans Data\StartupBackup.json AVANT la modification.
        La liste blanche est revérifiée ici, quelle que soit la liste reçue.
    #>
    param([switch]$Confirmed, $Entries, [string]$BackupPath)
    if (-not $Confirmed) { throw (Get-Text 'Prf.063') }
    if (-not $BackupPath) { $BackupPath = Get-StartupBackupPath }
    $plan = Get-StartupCleanupPlan -Entries $Entries
    $skipped = @($plan.NeedAdmin | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Reason = (Get-Text 'Prf.064') } })
    $backup = Read-StartupBackup -Path $BackupPath
    $items = New-Object System.Collections.ArrayList
    if ($backup) { foreach ($i in @($backup.Items)) { [void]$items.Add($i) } }

    # 1. Sauvegarde de l'état initial, avant toute modification
    $todo = @()
    foreach ($t in $plan.Targets) {
        $e = $t.Entry
        $exists = $items | Where-Object { $_.ApprovedKey -eq $e.ApprovedKey -and $_.ValueName -eq $e.ValueName } | Select-Object -First 1
        if (-not $exists) {
            $prev = $null
            try { $raw = (Get-ItemProperty -LiteralPath $e.ApprovedKey -Name $e.ValueName -ErrorAction Stop).($e.ValueName); if ($raw) { $prev = [Convert]::ToBase64String([byte[]]$raw) } } catch { }
            [void]$items.Add([pscustomobject]@{ Name = $e.Name; Source = $e.Source; Scope = $e.Scope; Category = $t.Category; ApprovedKey = $e.ApprovedKey; ValueName = $e.ValueName; PreviousBytes = $prev; Applied = $false })
        }
        $todo += $t
    }
    if ($todo.Count -gt 0) { Write-StartupBackup -Path $BackupPath -Items $items }

    # 2. Désactivation élément par élément
    $disabled = @(); $failed = @()
    foreach ($t in $todo) {
        $e = $t.Entry
        try {
            [void](Set-StartupEntryState -Entry $e -Enabled $false -Confirmed)
            ($items | Where-Object { $_.ApprovedKey -eq $e.ApprovedKey -and $_.ValueName -eq $e.ValueName } | Select-Object -First 1).Applied = $true
            $disabled += [pscustomobject]@{ Name = $e.Name; Category = $t.Category; Source = $e.Source }
        } catch { $failed += [pscustomobject]@{ Name = $e.Name; Reason = $_.Exception.Message } }
        Write-StartupBackup -Path $BackupPath -Items @($items | Where-Object Applied)
    }
    Write-AppLog ((Get-Text 'Prf.065') -f $disabled.Count, $skipped.Count, $failed.Count) 'ACTION'
    [pscustomobject]@{ Disabled = @($disabled); Skipped = @($skipped); Failed = @($failed); Protected = $plan.Protected.Count }
}

function Restore-StartupBackup {
    <# Remet chaque élément dans son état initial exact (valeur StartupApproved d'origine, ou absente). #>
    param([switch]$Confirmed, [string]$BackupPath)
    if (-not $Confirmed) { throw (Get-Text 'Prf.067') }
    if (-not $BackupPath) { $BackupPath = Get-StartupBackupPath }
    $backup = Read-StartupBackup -Path $BackupPath
    if (-not $backup -or @($backup.Items).Count -eq 0) { throw (Get-Text 'Prf.068') }
    $isAdmin = Test-IsAdmin
    $restored = @(); $remaining = @(); $failed = @()
    foreach ($i in @($backup.Items)) {
        if ($i.Scope -eq 'Machine' -and -not $isAdmin) { $remaining += $i; continue }
        try {
            if ($i.PreviousBytes) { Set-ItemProperty -LiteralPath $i.ApprovedKey -Name $i.ValueName -Value ([Convert]::FromBase64String($i.PreviousBytes)) -Type Binary -ErrorAction Stop }
            else { Remove-ItemProperty -LiteralPath $i.ApprovedKey -Name $i.ValueName -ErrorAction SilentlyContinue }
            $restored += $i.Name
        } catch { $failed += $i.Name; $remaining += $i }
    }
    Write-StartupBackup -Path $BackupPath -Items $remaining
    Write-AppLog ((Get-Text 'Prf.070') -f $restored.Count, $remaining.Count) 'ACTION'
    [pscustomobject]@{ Restored = @($restored); Remaining = @($remaining | ForEach-Object Name); Failed = @($failed) }
}

#endregion

#region Mode Performance ---------------------------------------------------------------------

function Get-GameModeStatePath { Join-Path (Join-Path (Get-AppPath Root) 'Data') 'GameMode.json' }

function Get-GameModeServiceList { @($script:GameModeServiceList | ForEach-Object { [pscustomobject]$_ }) }

function Get-PowerSchemes {
    <# Lecture seule : plans d'alimentation { Guid, Name, Active }. Liste vide si powercfg échoue. #>
    $res = @()
    try {
        foreach ($line in @(& powercfg.exe /list 2>$null)) {
            if ($line -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\s+\((.+?)\)(\s*\*)?') {
                $res += [pscustomobject]@{ Guid = $Matches[1].ToLower(); Name = $Matches[2]; Active = [bool]$Matches[3] }
            }
        }
    } catch { }
    @($res)
}

function Get-GameModeStatus {
    <# Lecture seule : plan actif, état des services ciblés, mode actif ou non (état sauvegardé). #>
    param([string]$StatePath)
    if (-not $StatePath) { $StatePath = Get-GameModeStatePath }
    $schemes = Get-PowerSchemes
    $active = $schemes | Where-Object Active | Select-Object -First 1
    $svcs = foreach ($d in $script:GameModeServiceList) {
        $s = $null; try { $s = Get-Service -Name $d.Name -ErrorAction Stop } catch { }
        [pscustomobject]@{ Name = $d.Name; Why = (Get-Text $d.Why); Exists = [bool]$s; Running = [bool]($s -and $s.Status -eq 'Running'); Status = $(if ($s) { [string]$s.Status } else { 'Absent' }) }
    }
    $state = Read-GameModeState -Path $StatePath
    [pscustomobject]@{
        IsAdmin     = [bool](Test-IsAdmin)
        ActivePlan  = $(if ($active) { $active.Name } else { $null })
        ActiveGuid  = $(if ($active) { $active.Guid } else { $null })
        Services    = @($svcs)
        ModeActive  = [bool]$state
        State       = $state
    }
}

function Read-GameModeState {
    param([Parameter(Mandatory)][string]$Path)
    try { if (Test-Path -LiteralPath $Path) { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } } catch { Write-AppLog (Get-Text 'Prf.075' $($_.Exception.Message)) 'WARN' }
    $null
}

function Write-GameModeState {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$State)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    [IO.File]::WriteAllText($Path, ($State | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
}

function Invoke-RamTrim {
    <#
        Réduit l'espace de travail des processus accessibles (EmptyWorkingSet) : les pages inactives passent dans le cache
        de Windows et la RAM « disponible » augmente. Effet temporaire (les pages reviennent à l'usage). Aucun processus n'est arrêté.
    #>
    param([switch]$Confirmed)
    if (-not $Confirmed) { throw (Get-Text 'Prf.076') }
    if (-not ('PcToolkitMem' -as [type])) {
        Add-Type -Namespace '' -Name PcToolkitMem -MemberDefinition '[System.Runtime.InteropServices.DllImport("psapi.dll")] public static extern bool EmptyWorkingSet(System.IntPtr h);' -ErrorAction Stop
    }
    $freeBefore = (Get-SafeCim Win32_OperatingSystem).FreePhysicalMemory
    $n = 0
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        try { if ($p.Id -gt 4 -and [PcToolkitMem]::EmptyWorkingSet($p.Handle)) { $n++ } } catch { }
    }
    Start-Sleep -Milliseconds 600
    $freeAfter = (Get-SafeCim Win32_OperatingSystem).FreePhysicalMemory
    $freedMB = $null
    if ($freeBefore -and $freeAfter) { $freedMB = [math]::Round(($freeAfter - $freeBefore) / 1KB, 0) }
    Write-AppLog ((Get-Text 'Prf.079') -f $n, $freedMB) 'ACTION'
    [pscustomobject]@{ Processes = $n; FreedMB = $freedMB }
}

function Enable-GameMode {
    <# Sauvegarde l'état, passe en plan haute performance, arrête les services secondaires en cours d'exécution. #>
    # Presets : -OnlyServices limite la liste (sous-ensemble de la liste officielle), -SkipPowerPlan laisse le plan d'alimentation,
    # -ProfileName est mémorisé dans l'état (affiché par le bilan et la page).
    param([switch]$Confirmed, [switch]$FlushRam, [string]$StatePath, [string[]]$OnlyServices, [switch]$SkipPowerPlan, [string]$ProfileName)
    if (-not $Confirmed) { throw (Get-Text 'Prf.081') }
    if (-not $StatePath) { $StatePath = Get-GameModeStatePath }
    if (-not (Test-IsAdmin)) { throw (Get-Text 'Prf.082') }
    if (Read-GameModeState -Path $StatePath) { throw (Get-Text 'Prf.083') }

    $schemes = Get-PowerSchemes
    $before = $schemes | Where-Object Active | Select-Object -First 1
    $candidates = @($script:GameModeServiceList | Where-Object { -not $OnlyServices -or $OnlyServices -contains $_.Name })
    $running = @(foreach ($d in $candidates) {
        $s = $null; try { $s = Get-Service -Name $d.Name -ErrorAction Stop } catch { }
        if ($s -and $s.Status -eq 'Running') { $d.Name }
    })
    # Sauvegarde AVANT toute modification
    $state = [ordered]@{
        Date = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Profile = $(if ($ProfileName) { $ProfileName } else { (Get-Text 'Prf.086') })
        PreviousPlanGuid = $(if ($before -and -not $SkipPowerPlan) { $before.Guid } else { $null })
        PreviousPlanName = $(if ($before) { $before.Name } else { $null })
        CreatedPlanGuid = $null
        ServicesToStop = @($running)
        ServicesStopped = @()
    }
    Write-GameModeState -Path $StatePath -State $state
    Write-AppLog ((Get-Text 'Prf.087') -f $running.Count, $state.PreviousPlanName) 'ACTION'

    # Plan d'alimentation : Ultimate existant > Haute performance existant > création d'une copie d'Ultimate
    $planNote = ''; $target = $null
    $ult = $schemes | Where-Object { $_.Guid -eq $script:UltimateGuid } | Select-Object -First 1
    $hi = $schemes | Where-Object { $_.Guid -eq $script:HighPerfGuid } | Select-Object -First 1
    if ($SkipPowerPlan) { $planNote = (Get-Text 'Prf.089') }
    elseif ($ult) { $target = $ult } elseif ($hi) { $target = $hi }
    else {
        try {
            $o = (& powercfg.exe -duplicatescheme $script:UltimateGuid 2>$null) -join ' '
            if ($o -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
                $state.CreatedPlanGuid = $Matches[1].ToLower()
                Write-GameModeState -Path $StatePath -State $state
                $target = [pscustomobject]@{ Guid = $state.CreatedPlanGuid; Name = (Get-Text 'Prf.090') }
            }
        } catch { }
    }
    $planAfter = $null
    if ($target) {
        & powercfg.exe /setactive $target.Guid 2>$null
        if ($LASTEXITCODE -eq 0) { $planAfter = $target.Name; Write-AppLog (Get-Text 'Prf.091' $planAfter) 'ACTION' }
        else { $planNote = (Get-Text 'Prf.093') }
    } elseif (-not $SkipPowerPlan) { $planNote = (Get-Text 'Prf.094') }

    # Services
    $stopped = New-Object System.Collections.ArrayList
    $failed = New-Object System.Collections.ArrayList
    foreach ($name in $running) {
        try {
            Stop-Service -Name $name -Force -ErrorAction Stop
            [void]$stopped.Add($name)
            $state.ServicesStopped = @($stopped)
            Write-GameModeState -Path $StatePath -State $state
            Write-AppLog (Get-Text 'Prf.095' $name) 'ACTION'
        } catch {
            [void]$failed.Add($name)
            Write-AppLog (Get-Text 'Prf.097' $name $($_.Exception.Message)) 'WARN'
        }
    }

    $ram = $null
    if ($FlushRam) { try { $ram = Invoke-RamTrim -Confirmed } catch { Write-AppLog (Get-Text 'Prf.098' $($_.Exception.Message)) 'WARN' } }

    [pscustomobject]@{
        PlanBefore = $state.PreviousPlanName; PlanAfter = $planAfter; PlanNote = $planNote
        Stopped = @($stopped); Failed = @($failed); AlreadyOff = @($candidates | ForEach-Object { $_.Name } | Where-Object { $running -notcontains $_ })
        Ram = $ram
    }
}

function Restore-GameMode {
    <# Remet le plan d'alimentation d'origine et relance les services arrêtés par le Mode Performance. #>
    param([switch]$Confirmed, [string]$StatePath)
    if (-not $Confirmed) { throw (Get-Text 'Prf.099') }
    if (-not $StatePath) { $StatePath = Get-GameModeStatePath }
    $state = Read-GameModeState -Path $StatePath
    if (-not $state) { throw (Get-Text 'Prf.100') }
    $toStart = @($state.ServicesStopped)
    if ($toStart.Count -gt 0 -and -not (Test-IsAdmin)) { throw (Get-Text 'Prf.101') }

    $planNote = ''; $planBack = $null; $planDone = $true
    if ($state.PreviousPlanGuid) {
        $exists = Get-PowerSchemes | Where-Object { $_.Guid -eq $state.PreviousPlanGuid } | Select-Object -First 1
        if ($exists) {
            & powercfg.exe /setactive $state.PreviousPlanGuid 2>$null
            if ($LASTEXITCODE -eq 0) { $planBack = $state.PreviousPlanName; Write-AppLog (Get-Text 'Prf.102' $planBack) 'ACTION' }
            else { $planNote = (Get-Text 'Prf.104'); $planDone = $false }
        } else { $planNote = (Get-Text 'Prf.105') }
    }
    if ($state.CreatedPlanGuid -and $planBack) {
        & powercfg.exe /delete $state.CreatedPlanGuid 2>$null   # supprime seulement le plan créé par le Mode Performance
    }

    $started = New-Object System.Collections.ArrayList
    $failed = New-Object System.Collections.ArrayList
    foreach ($name in $toStart) {
        try { Start-Service -Name $name -ErrorAction Stop; [void]$started.Add($name); Write-AppLog (Get-Text 'Prf.106' $name) 'ACTION' }
        catch { [void]$failed.Add($name); Write-AppLog (Get-Text 'Prf.108' $name $($_.Exception.Message)) 'WARN' }
    }
    if ($failed.Count -eq 0 -and $planDone) { Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue }
    else {
        # On garde seulement ce qui reste à faire, pour pouvoir réessayer
        $state.ServicesStopped = @($failed)
        if ($planDone) { $state.PreviousPlanGuid = $null }
        Write-GameModeState -Path $StatePath -State $state
    }
    [pscustomobject]@{ PlanRestored = $planBack; PlanNote = $planNote; Started = @($started); Failed = @($failed) }
}

#endregion

Export-ModuleMember -Function Get-StartupApprovedBytes, Test-StartupApprovedEnabled, Get-CommandExecutable, Get-StartupItems, Set-StartupEntryState,
    Get-StartupBackupPath, Test-StartupProtected, Get-StartupRule, Get-StartupCleanupPlan, Read-StartupBackup, Write-StartupBackup, Invoke-StartupAutoClean, Restore-StartupBackup,
    Get-GameModeStatePath,Get-GameModeServiceList, Get-PowerSchemes, Get-GameModeStatus, Read-GameModeState, Write-GameModeState,
    Invoke-RamTrim, Enable-GameMode, Restore-GameMode
