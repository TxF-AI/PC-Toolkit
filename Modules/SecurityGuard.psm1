#requires -Version 5.1
<#
    SecurityGuard.psm1 — Security Guard : audit de sécurité léger (ce n'est PAS un antivirus)
    -----------------------------------------------------------------------------------------
    1. Invoke-SecurityAudit        état de Windows Defender, du pare-feu, du contrôle de compte (lecture seule)
    2. Invoke-StartupThreatScan      démarrage automatique (clés Run, dossiers Démarrage, tâches planifiées, Temp/AppData)
    3. Invoke-FileHeuristicScan    fichier ou dossier : signature, double extension, hash connus, contenu de scripts
    4. Quarantaine                 Move-FileToQuarantine, Disable-SuspiciousTask, Disable-SuspiciousStartup, Restore-FromQuarantine
                                   (Data\Quarantine\ ; rien n'est supprimé, tout est restaurable)
    Les analyses sont en lecture seule. Toute neutralisation exige -Confirmed et est journalisée ('ACTION').
    Heuristique = indices, pas certitudes : « non signé » ou « dans Temp » ne prouve pas qu'un fichier est dangereux.
#>

# Empreintes SHA-256 de fichiers connus comme malveillants / de test (liste volontairement courte et vérifiable)
$script:KnownBadHashes = @{
    '275a021bbfb6489e54d471899f7db9d1663fc695ec2fe2a2c4538aabf651fd0f' = 'EICAR (fichier de test antivirus)'
}
$script:SignableExt = @('.exe', '.dll', '.sys', '.scr', '.ocx', '.msi', '.cpl')   # les scripts ne sont presque jamais signés : leur absence de signature n'est pas un indice
$script:ScanExt = @('.exe', '.scr', '.com', '.pif', '.bat', '.cmd', '.vbs', '.vbe', '.js', '.jse', '.wsf', '.hta', '.ps1', '.psm1', '.lnk', '.msi', '.jar', '.cpl')
$script:ScriptExt = @('.ps1', '.psm1', '.bat', '.cmd', '.vbs', '.vbe', '.js', '.jse', '.wsf', '.hta')

# Les motifs sont écrits en morceaux : ainsi ce fichier ne ressemble pas lui-même à un programme malveillant
$script:ScriptPatterns = @(
    @{ W = 6; T = 'fichier de test antivirus EICAR'; P = [regex]::Escape(('X5O!P%@AP[4\PZX54(P^)7CC)7}$' + 'EICAR-STANDARD-' + 'ANTIVIRUS-TEST-FILE!')) }
    @{ W = 5; T = 'outil de vol de mots de passe'; P = ('(?i)mimi' + 'katz|sekur' + 'lsa::') }
    @{ W = 5; T = 'contournement de l''analyse antimalware (AMSI)'; P = ('(?i)amsi' + 'InitFailed|Amsi' + 'Utils') }
    @{ W = 4; T = 'désactivation de l''antivirus'; P = '(?i)Set-MpPreference\s+-DisableRealtimeMonitoring\s+\$true|DisableAntiSpyware' }
    @{ W = 5; T = 'destruction des sauvegardes (comportement de rançongiciel)'; P = '(?i)vssadmin(\.exe)?\s+delete\s+shadows|wbadmin\s+delete\s+(catalog|backup)' }
    @{ W = 5; T = 'téléchargement puis exécution immédiate de code'; P = '(?is)downloadstring\s*\([^)]*\)\s*\)?\s*\|\s*(iex|invoke-expression)' }
    @{ W = 4; T = 'PowerShell avec longue commande encodée'; P = '(?i)powershell(\.exe)?\s.*-e(nc(odedcommand)?)?\s+[A-Za-z0-9+/=]{40,}' }
)

#region Analyse d'indices ---------------------------------------------------------------------

function Get-FileSignatureState {
    <# Signed | NotSigned | Invalid (fichier modifié après signature) | Unknown | NA (type non signable) | Missing. Lecture seule. #>
    param([string]$Path)
    try {
        if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'Missing' }
        if ($script:SignableExt -notcontains [IO.Path]::GetExtension($Path).ToLower()) { return 'NA' }
        $s = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        switch ([string]$s.Status) { 'Valid' { 'Signed' } 'NotSigned' { 'NotSigned' } 'HashMismatch' { 'Invalid' } default { 'Unknown' } }
    } catch { 'Unknown' }
}

function Get-SuspicionReasons {
    <#
        Fonction pure (aucun accès disque) : liste les indices { Weight, Reason } pour un chemin, une ligne de commande et une signature.
        Signature : Signed | NotSigned | Invalid | NA | Missing | Unknown | '' (ignorée).
    #>
    param([string]$Path, [string]$Command, [string]$Signature)
    $r = New-Object System.Collections.ArrayList
    $name = ''; $ext = ''
    if ($Path) { $name = [IO.Path]::GetFileName($Path); $ext = [IO.Path]::GetExtension($Path).ToLower() }
    $isExec = $script:ScanExt -contains $ext
    $text = "$Path $Command"

    if ($name -match '(?i)\.(pdf|docx?|xlsx?|pptx?|txt|rtf|jpe?g|png|gif|bmp|mp3|mp4|avi|zip|rar|7z|iso)\s*\.(exe|scr|com|pif|bat|cmd|vbs|vbe|js|jse|wsf|hta|ps1|lnk|msi)$') {
        [void]$r.Add([pscustomobject]@{ Weight = 3; Reason = 'double extension (un exécutable déguisé en document)' })
    }
    if ($text.Contains([string][char]0x202E)) {
        [void]$r.Add([pscustomobject]@{ Weight = 4; Reason = 'caractère de lecture inversée dans le nom (extension masquée)' })
    }
    if ($Path -and $isExec -and $Path -match '(?i)\\(AppData\\Local\\Temp|Temp|Tmp)\\|\\Users\\Public\\|\$Recycle\.Bin\\') {
        [void]$r.Add([pscustomobject]@{ Weight = 2; Reason = 'exécutable dans un dossier temporaire, public ou la corbeille' })
    }
    elseif ($Path -and $isExec -and $Path -match '(?i)\\AppData\\(Roaming|Local)\\') {
        [void]$r.Add([pscustomobject]@{ Weight = 1; Reason = 'lancé depuis AppData' })
    }
    if ($name -match '(?i)^(svchost|explorer|lsass|csrss|winlogon|services|smss|wininit|taskhostw?|spoolsv|dwm)\.exe$' -and $Path -notmatch '(?i)^[A-Za-z]:\\Windows\\') {
        [void]$r.Add([pscustomobject]@{ Weight = 4; Reason = 'porte le nom d''un processus Windows mais n''est pas dans le dossier Windows' })
    }
    switch ($Signature) {
        'Invalid'   { [void]$r.Add([pscustomobject]@{ Weight = 4; Reason = 'signature numérique invalide (fichier modifié depuis sa signature)' }) }
        'NotSigned' { [void]$r.Add([pscustomobject]@{ Weight = 2; Reason = 'exécutable non signé' }) }
    }
    if ($Command) {
        $rules = @(
            @{ W = 4; T = 'PowerShell avec commande encodée'; P = '(?i)-e(nc(odedcommand)?)?\s+[A-Za-z0-9+/=]{20,}' }
            @{ W = 2; T = 'décodage Base64 dans la commande'; P = '(?i)frombase64string' }
            @{ W = 2; T = 'exécution dynamique de code (iex)'; P = '(?i)\b(iex|invoke-expression)\b' }
            @{ W = 3; T = 'téléchargement depuis Internet'; P = '(?i)downloadstring|downloadfile|invoke-webrequest|\biwr\b|net\.webclient|start-bitstransfer' }
            @{ W = 3; T = 'mshta (script HTML)'; P = '(?i)\bmshta(\.exe)?\b' }
            @{ W = 3; T = 'outil Windows détourné pour télécharger'; P = '(?i)certutil.*-urlcache|bitsadmin.*/transfer|regsvr32.*/i:\s*https?://' }
            @{ W = 1; T = 'fenêtre cachée'; P = '(?i)-w(indowstyle)?\s+hidden' }
            @{ W = 2; T = 'adresse IP brute dans la commande'; P = '(?i)https?://\d{1,3}(\.\d{1,3}){3}' }
        )
        foreach ($x in $rules) { if ($Command -match $x.P) { [void]$r.Add([pscustomobject]@{ Weight = $x.W; Reason = $x.T }) } }
    }
    @($r)
}

function Get-ThreatLevel {
    <# Score -> 'Crit' (>= 4, suspect), 'Warn' (>= 2, à examiner) ou 'OK'. #>
    param([int]$Score)
    if ($Score -ge 4) { 'Crit' } elseif ($Score -ge 2) { 'Warn' } else { 'OK' }
}

function Test-MaliciousScriptContent {
    <# Fonction pure : motifs de scripts malveillants connus dans un texte. Renvoie des { Weight, Reason }. #>
    param([string]$Text)
    $hits = @()
    if ($Text) { foreach ($p in $script:ScriptPatterns) { if ($Text -match $p.P) { $hits += [pscustomobject]@{ Weight = $p.W; Reason = "contenu : $($p.T)" } } } }
    @($hits)
}

function Get-KnownBadHashes { $script:KnownBadHashes.Clone() }

function New-SecurityFinding {
    param([string]$Kind, [string]$Name, [string]$Path, [string]$Command, [string]$Source, [string]$Signature, $Target,
        [object[]]$ExtraReasons, [string]$Sha256)
    $reasons = @(Get-SuspicionReasons -Path $Path -Command $Command -Signature $Signature)
    if ($ExtraReasons) { $reasons += @($ExtraReasons) }
    $score = 0; foreach ($x in $reasons) { $score += [int]$x.Weight }
    [pscustomobject]@{
        Kind = $Kind; Name = $Name; Path = $Path; Command = $Command; Source = $Source; Signature = $Signature
        Score = $score; Level = (Get-ThreatLevel $score); Reasons = (($reasons | ForEach-Object Reason) -join ' ; '); Sha256 = $Sha256; Target = $Target
    }
}

#endregion

#region Audit système -------------------------------------------------------------------------

function Invoke-SecurityAudit {
    <# Lecture seule. Renvoie des lignes { Label, Value, Status, Detail } (Status : OK | Warn | Crit | Info | NA). Jamais de valeur inventée. #>
    param($Ctx)
    $rows = New-Object System.Collections.ArrayList
    $add = { param($l, $v, $s, $d) [void]$rows.Add([pscustomobject]@{ Label = $l; Value = $v; Status = $s; Detail = $d }) }
    $yn = { param($b) if ($b) { 'Actif' } else { 'Désactivé' } }

    Update-DiagProgress $Ctx 10 'Windows Defender…'
    $mp = $null; try { $mp = Get-MpComputerStatus -ErrorAction Stop } catch { }
    if ($mp) {
        & $add 'Service antivirus Defender' (& $yn $mp.AMServiceEnabled) $(if ($mp.AMServiceEnabled) { 'OK' } else { 'Crit' }) $null
        & $add 'Protection en temps réel' (& $yn $mp.RealTimeProtectionEnabled) $(if ($mp.RealTimeProtectionEnabled) { 'OK' } else { 'Crit' }) $null
        & $add 'Moteur antivirus' (& $yn $mp.AntivirusEnabled) $(if ($mp.AntivirusEnabled) { 'OK' } else { 'Warn' }) ("Moteur $($mp.AMEngineVersion)")
        $age = $null; try { $age = [int]$mp.AntivirusSignatureAge } catch { }
        if ($null -ne $age) {
            $st = if ($age -le 3) { 'OK' } elseif ($age -le 7) { 'Warn' } else { 'Crit' }
            & $add 'Définitions de virus' $(if ($age -eq 0) { 'À jour (aujourd''hui)' } else { "Vieilles de $age jour(s)" }) $st ("Version $($mp.AntivirusSignatureVersion) · mise à jour : $($mp.AntivirusSignatureLastUpdated)")
        } else { & $add 'Définitions de virus' 'Non disponible' 'NA' $null }
        if ($null -ne $mp.IsTamperProtected) { & $add 'Protection contre les falsifications' (& $yn $mp.IsTamperProtected) $(if ($mp.IsTamperProtected) { 'OK' } else { 'Info' }) $null }
    } else {
        & $add 'Windows Defender' 'Non disponible' 'NA' 'État illisible (antivirus tiers, droits insuffisants ou service arrêté).'
    }
    try {
        $av = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntivirusProduct -ErrorAction Stop | ForEach-Object displayName | Select-Object -Unique)
        if ($av.Count) { & $add 'Antivirus enregistrés dans Windows' ($av -join ', ') 'Info' 'Centre de sécurité Windows.' }
    } catch { }

    Update-DiagProgress $Ctx 55 'Pare-feu Windows…'
    try {
        $fw = @(Get-NetFirewallProfile -ErrorAction Stop)
        foreach ($p in $fw) { & $add "Pare-feu : profil $($p.Name)" (& $yn ([bool]$p.Enabled)) $(if ($p.Enabled) { 'OK' } else { 'Crit' }) $null }
        if (-not $fw.Count) { & $add 'Pare-feu Windows' 'Non disponible' 'NA' $null }
    } catch { & $add 'Pare-feu Windows' 'Non disponible' 'NA' $_.Exception.Message }

    Update-DiagProgress $Ctx 85 'Contrôle de compte d''utilisateur…'
    try {
        $uac = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name EnableLUA -ErrorAction Stop).EnableLUA
        & $add 'Contrôle de compte (UAC)' (& $yn ($uac -eq 1)) $(if ($uac -eq 1) { 'OK' } else { 'Warn' }) $null
    } catch { & $add 'Contrôle de compte (UAC)' 'Non disponible' 'NA' $null }
    Update-DiagProgress $Ctx 100 'Audit terminé'
    @($rows)
}

#endregion

#region Persistance et fichiers ---------------------------------------------------------------

function Get-StartupThreatFindings {
    <#
        Lecture seule. Un résultat par élément analysé (tous niveaux) : programmes de démarrage actifs, tâches planifiées hors Microsoft,
        et — sauf -Quick — exécutables/scripts à la racine des dossiers Temp, AppData et Public.
    #>
    param($Ctx, [switch]$Quick, [int]$MaxFiles = 400)
    $out = New-Object System.Collections.ArrayList
    $seen = @{}

    Update-DiagProgress $Ctx 10 'Programmes de démarrage…'
    try {
        foreach ($e in @(Get-StartupItems | Where-Object Enabled)) {
            $sig = Get-FileSignatureState $e.Path
            if ($e.Path) { $seen[$e.Path.ToLower()] = $true }
            [void]$out.Add((New-SecurityFinding -Kind 'Démarrage' -Name $e.Name -Path $e.Path -Command $e.Command -Source $e.Source -Signature $sig -Target $e))
        }
    } catch { Write-AppLog "Security Guard (démarrage) : $($_.Exception.Message)" 'ERROR' }

    Update-DiagProgress $Ctx 35 'Tâches planifiées…'
    try {
        foreach ($t in @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskPath -notlike '\Microsoft\*' -and $_.State -ne 'Disabled' })) {
            $a = @($t.Actions | Where-Object { $_.PSObject.Properties['Execute'] -and $_.Execute }) | Select-Object -First 1
            if (-not $a) { continue }
            $exe = [Environment]::ExpandEnvironmentVariables([string]$a.Execute).Trim('"')
            if ($exe -and -not [IO.Path]::IsPathRooted($exe)) {
                $c = Get-Command $exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($c) { $exe = $c.Source }
            }
            $sig = Get-FileSignatureState $exe
            [void]$out.Add((New-SecurityFinding -Kind 'Tâche planifiée' -Name ($t.TaskPath + $t.TaskName) -Path $exe -Command ("$($a.Execute) $($a.Arguments)").Trim() `
                    -Source 'Planificateur de tâches' -Signature $sig -Target ([pscustomobject]@{ TaskName = $t.TaskName; TaskPath = $t.TaskPath })))
        }
    } catch { Write-AppLog "Security Guard (tâches) : $($_.Exception.Message)" 'ERROR' }

    if (-not $Quick) {
        Update-DiagProgress $Ctx 60 'Dossiers Temp, AppData et Public…'
        $roots = @($env:TEMP, $env:APPDATA, $env:PUBLIC, (Join-Path $env:LOCALAPPDATA 'Temp')) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
        $n = 0
        foreach ($root in $roots) {
            foreach ($f in @(Get-ChildItem -LiteralPath $root -File -Force -Recurse -Depth 2 -ErrorAction SilentlyContinue | Where-Object { $script:ScanExt -contains $_.Extension.ToLower() })) {
                if ($n -ge $MaxFiles -or (Test-DiagCancel $Ctx)) { break }
                if ($seen[$f.FullName.ToLower()]) { continue }
                $seen[$f.FullName.ToLower()] = $true; $n++
                [void]$out.Add((New-SecurityFinding -Kind 'Fichier' -Name $f.Name -Path $f.FullName -Source (Split-Path $f.DirectoryName -Leaf) -Signature (Get-FileSignatureState $f.FullName) -Target $f.FullName))
            }
        }
    }
    Update-DiagProgress $Ctx 100 'Analyse terminée'
    @($out)
}

function Invoke-StartupThreatScan {
    <# Point d'entrée pour l'interface : renvoie les résultats de Get-StartupThreatFindings (tâche de fond). #>
    param($Ctx)
    Get-StartupThreatFindings -Ctx $Ctx
}

function Invoke-FileHeuristicScan {
    <#
        Analyse un fichier ou un dossier (lecture seule) : signature, indices de nom/chemin, empreinte SHA-256 comparée à la liste connue,
        motifs de scripts malveillants. Émet les éléments à examiner (score >= 2) puis un résumé final { ScanSummary = $true }.
    #>
    param($Ctx, [Parameter(Mandatory)][string]$Path, [int]$MaxFiles = 5000, [hashtable]$KnownHashes)
    if (-not $KnownHashes) { $KnownHashes = Get-KnownBadHashes }
    if (-not (Test-Path -LiteralPath $Path)) { throw "Chemin introuvable : $Path" }
    $files = New-Object System.Collections.Generic.List[string]
    $truncated = $false
    if (Test-Path -LiteralPath $Path -PathType Leaf) { $files.Add((Resolve-Path -LiteralPath $Path).ProviderPath) }
    else {
        $stack = New-Object System.Collections.Generic.Stack[string]
        $stack.Push((Resolve-Path -LiteralPath $Path).ProviderPath)
        $qdir = Get-QuarantineDir
        while ($stack.Count -gt 0 -and -not (Test-DiagCancel $Ctx)) {
            $d = $stack.Pop()
            if ($d.StartsWith($qdir, [StringComparison]::OrdinalIgnoreCase)) { continue }
            foreach ($it in @(Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue)) {
                if ($it.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                if ($it.PSIsContainer) { $stack.Push($it.FullName) }
                elseif ($script:ScanExt -contains $it.Extension.ToLower()) {
                    if ($files.Count -ge $MaxFiles) { $truncated = $true; break }
                    $files.Add($it.FullName)
                }
            }
            if ($truncated) { break }
            Update-DiagProgress $Ctx 20 ("Recherche des fichiers… {0}" -f $files.Count)
        }
    }

    $i = 0; $flagged = 0; $hashed = 0
    foreach ($f in $files) {
        if (Test-DiagCancel $Ctx) { break }
        $i++
        if ($i % 10 -eq 0 -or $files.Count -lt 50) { Update-DiagProgress $Ctx (20 + [int](80 * $i / [math]::Max(1, $files.Count))) ("Analyse… {0} / {1}" -f $i, $files.Count) }
        try {
            $fi = Get-Item -LiteralPath $f -Force -ErrorAction Stop
            $extra = @(); $sha = $null
            if ($fi.Length -le 200MB) {
                $sha = (Get-FileHash -LiteralPath $f -Algorithm SHA256 -ErrorAction Stop).Hash.ToLower(); $hashed++
                if ($KnownHashes.ContainsKey($sha)) { $extra += [pscustomobject]@{ Weight = 10; Reason = "empreinte connue : $($KnownHashes[$sha])" } }
            }
            if ($script:ScriptExt -contains $fi.Extension.ToLower() -and $fi.Length -le 2MB) {
                $extra += @(Test-MaliciousScriptContent ([IO.File]::ReadAllText($f)))
            }
            $finding = New-SecurityFinding -Kind 'Fichier' -Name $fi.Name -Path $f -Source $fi.DirectoryName -Signature (Get-FileSignatureState $f) -Target $f -ExtraReasons $extra -Sha256 $sha
            if ($finding.Score -ge 2) { $flagged++; $finding }
        } catch { Write-AppLog "Security Guard (scan) $f : $($_.Exception.Message)" 'WARN' }
    }
    [pscustomobject]@{ ScanSummary = $true; Path = $Path; Scanned = $i; Hashed = $hashed; Flagged = $flagged; Truncated = $truncated; Cancelled = [bool](Test-DiagCancel $Ctx) }
}

#endregion

#region Quarantaine ---------------------------------------------------------------------------

function Get-QuarantineDir {
    $d = Join-Path (Join-Path (Get-AppPath Root) 'Data') 'Quarantine'
    if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d -Force) }
    $d
}

function Read-QuarantineIndex {
    param([string]$QuarantineDir)
    if (-not $QuarantineDir) { $QuarantineDir = Get-QuarantineDir }
    $f = Join-Path $QuarantineDir 'index.json'
    try { if (Test-Path -LiteralPath $f) { $j = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json; if ($j) { return @($j) } } }
    catch { Write-AppLog "Quarantaine (index illisible) : $($_.Exception.Message)" 'WARN' }
    @()
}

function Write-QuarantineIndex {
    param([string]$QuarantineDir, [object[]]$Items)
    if (-not $QuarantineDir) { $QuarantineDir = Get-QuarantineDir }
    if (-not (Test-Path -LiteralPath $QuarantineDir)) { [void](New-Item -ItemType Directory -Path $QuarantineDir -Force) }
    $json = if (@($Items).Count) { ConvertTo-Json -InputObject @($Items) -Depth 6 } else { '[]' }
    [IO.File]::WriteAllText((Join-Path $QuarantineDir 'index.json'), $json, (New-Object Text.UTF8Encoding($false)))
}

function Get-QuarantineItems {
    <# Éléments actuellement isolés (les éléments restaurés ne comptent plus). #>
    param([string]$QuarantineDir)
    @(Read-QuarantineIndex -QuarantineDir $QuarantineDir | Where-Object { -not $_.Restored })
}

function Test-QuarantineForbidden {
    <# Garde-fous : renvoie la raison du refus, ou $null si le fichier peut être isolé. Fonction pure (ne touche à rien). #>
    param([Parameter(Mandatory)][string]$Path, [string]$QuarantineDir, [string]$AppRoot)
    if (-not $QuarantineDir) { $QuarantineDir = Get-QuarantineDir }
    if (-not $AppRoot) { $AppRoot = Get-AppPath Root }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.Length -le 3) { return 'Une racine de disque ne peut pas être isolée.' }
    $win = [IO.Path]::GetFullPath($env:windir).TrimEnd('\') + '\'
    if ($full.StartsWith($win, [StringComparison]::OrdinalIgnoreCase)) { return 'Les fichiers du dossier Windows ne sont jamais déplacés (risque de rendre le système instable).' }
    if ($full.StartsWith(([IO.Path]::GetFullPath($QuarantineDir).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) { return 'Ce fichier est déjà en quarantaine.' }
    $root = [IO.Path]::GetFullPath($AppRoot).TrimEnd('\') + '\'
    if ($full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return 'Les fichiers de PC Toolkit lui-même ne sont jamais isolés.' }
    $null
}

function Move-FileToQuarantine {
    <# Déplace un fichier vers Data\Quarantine\<id>.quar (extension neutralisée) et l'inscrit dans l'index AVANT le déplacement. Exige -Confirmed. #>
    param([Parameter(Mandatory)][string]$Path, [string]$Reason = '', [switch]$Confirmed, [string]$QuarantineDir)
    if (-not $Confirmed) { throw 'Confirmation explicite requise (-Confirmed).' }
    if (-not $QuarantineDir) { $QuarantineDir = Get-QuarantineDir }
    if (-not (Test-Path -LiteralPath $QuarantineDir)) { [void](New-Item -ItemType Directory -Path $QuarantineDir -Force) }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'Fichier introuvable.' }
    $full = (Resolve-Path -LiteralPath $Path).ProviderPath
    $refus = Test-QuarantineForbidden -Path $full -QuarantineDir $QuarantineDir
    if ($refus) { throw $refus }
    $fi = Get-Item -LiteralPath $full -Force
    if ($fi.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Les liens symboliques ne sont pas déplacés.' }

    $id = [guid]::NewGuid().ToString('N')
    $sha = $null; try { $sha = (Get-FileHash -LiteralPath $full -Algorithm SHA256 -ErrorAction Stop).Hash.ToLower() } catch { }
    $item = [pscustomobject]@{
        Id = $id; Kind = 'File'; Name = $fi.Name; OriginalPath = $full; Sha256 = $sha; Size = [long]$fi.Length
        Date = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Reason = $Reason; Stored = "$id.quar"; Restored = $false; Extra = $null
    }
    $all = @(Read-QuarantineIndex -QuarantineDir $QuarantineDir)
    Write-QuarantineIndex -QuarantineDir $QuarantineDir -Items ($all + $item)
    try { Move-Item -LiteralPath $full -Destination (Join-Path $QuarantineDir $item.Stored) -ErrorAction Stop }
    catch {
        Write-QuarantineIndex -QuarantineDir $QuarantineDir -Items $all
        throw "Impossible d'isoler le fichier (utilisé par un programme ou droits insuffisants) : $($_.Exception.Message)"
    }
    Write-AppLog ("Security Guard : fichier isolé en quarantaine ({0}, {1})" -f $full, $Reason) 'ACTION'
    $item
}

function Disable-SuspiciousTask {
    <# Désactive (sans la supprimer) une tâche planifiée hors Microsoft et la note dans l'index. Exige -Confirmed. #>
    param([Parameter(Mandatory)][string]$TaskName, [Parameter(Mandatory)][string]$TaskPath, [string]$Reason = '', [switch]$Confirmed, [string]$QuarantineDir)
    if (-not $Confirmed) { throw 'Confirmation explicite requise (-Confirmed).' }
    if ($TaskPath -like '\Microsoft\*') { throw 'Les tâches Microsoft ne sont jamais désactivées par Security Guard.' }
    if (-not $QuarantineDir) { $QuarantineDir = Get-QuarantineDir }
    $t = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop
    $id = [guid]::NewGuid().ToString('N')
    $item = [pscustomobject]@{
        Id = $id; Kind = 'Task'; Name = ($TaskPath + $TaskName); OriginalPath = ($TaskPath + $TaskName); Sha256 = $null; Size = 0
        Date = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Reason = $Reason; Stored = $null; Restored = $false
        Extra = [pscustomobject]@{ TaskName = $TaskName; TaskPath = $TaskPath }
    }
    $all = @(Read-QuarantineIndex -QuarantineDir $QuarantineDir)
    Write-QuarantineIndex -QuarantineDir $QuarantineDir -Items ($all + $item)
    try { [void](Disable-ScheduledTask -InputObject $t -ErrorAction Stop) }
    catch {
        Write-QuarantineIndex -QuarantineDir $QuarantineDir -Items $all
        throw "Impossible de désactiver la tâche (droits administrateur requis ?) : $($_.Exception.Message)"
    }
    Write-AppLog ("Security Guard : tâche planifiée désactivée ({0}{1})" -f $TaskPath, $TaskName) 'ACTION'
    $item
}

function Disable-SuspiciousStartup {
    <# Désactive un programme de démarrage (StartupApproved, rien n'est supprimé). La liste blanche du démarrage l'emporte toujours. #>
    param([Parameter(Mandatory)]$Entry, [string]$Reason = '', [switch]$Confirmed, [string]$QuarantineDir)
    if (-not $Confirmed) { throw 'Confirmation explicite requise (-Confirmed).' }
    if (Test-StartupProtected $Entry) { throw "« $($Entry.Name) » appartient à la liste blanche (pilote, sécurité ou système) : il n'est jamais désactivé automatiquement. Utilisez la page Démarrage si vous êtes sûr." }
    if (-not $QuarantineDir) { $QuarantineDir = Get-QuarantineDir }
    $id = [guid]::NewGuid().ToString('N')
    $item = [pscustomobject]@{
        Id = $id; Kind = 'Startup'; Name = $Entry.Name; OriginalPath = $Entry.Path; Sha256 = $null; Size = 0
        Date = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Reason = $Reason; Stored = $null; Restored = $false
        Extra = [pscustomobject]@{ Name = $Entry.Name; Scope = $Entry.Scope; Source = $Entry.Source; ApprovedKey = $Entry.ApprovedKey; ValueName = $Entry.ValueName }
    }
    $all = @(Read-QuarantineIndex -QuarantineDir $QuarantineDir)
    Write-QuarantineIndex -QuarantineDir $QuarantineDir -Items ($all + $item)
    try { [void](Set-StartupEntryState -Entry $Entry -Enabled $false -Confirmed) }
    catch { Write-QuarantineIndex -QuarantineDir $QuarantineDir -Items $all; throw }
    Write-AppLog ("Security Guard : démarrage désactivé ({0})" -f $Entry.Name) 'ACTION'
    $item
}

function Restore-FromQuarantine {
    <# Remet un élément isolé tel qu'il était (fichier à son emplacement d'origine, tâche réactivée, démarrage réactivé). Exige -Confirmed. #>
    param([Parameter(Mandatory)][string]$Id, [switch]$Confirmed, [string]$QuarantineDir)
    if (-not $Confirmed) { throw 'Confirmation explicite requise (-Confirmed).' }
    if (-not $QuarantineDir) { $QuarantineDir = Get-QuarantineDir }
    $all = @(Read-QuarantineIndex -QuarantineDir $QuarantineDir)
    $item = $all | Where-Object { $_.Id -eq $Id -and -not $_.Restored } | Select-Object -First 1
    if (-not $item) { throw 'Élément de quarantaine introuvable.' }
    switch ($item.Kind) {
        'File' {
            $src = Join-Path $QuarantineDir $item.Stored
            if (-not (Test-Path -LiteralPath $src)) { throw 'Le fichier isolé a disparu du dossier de quarantaine.' }
            if (Test-Path -LiteralPath $item.OriginalPath) { throw "Un fichier existe déjà à l'emplacement d'origine : $($item.OriginalPath)" }
            $dir = Split-Path -Parent $item.OriginalPath
            if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
            Move-Item -LiteralPath $src -Destination $item.OriginalPath -ErrorAction Stop
        }
        'Task' { [void](Enable-ScheduledTask -TaskName $item.Extra.TaskName -TaskPath $item.Extra.TaskPath -ErrorAction Stop) }
        'Startup' { [void](Set-StartupEntryState -Entry $item.Extra -Enabled $true -Confirmed) }
    }
    $item.Restored = $true
    Write-QuarantineIndex -QuarantineDir $QuarantineDir -Items $all
    Write-AppLog ("Security Guard : {0} restauré ({1})" -f $item.Kind, $item.Name) 'ACTION'
    $item
}

#endregion

#region Bilan et rapport ----------------------------------------------------------------------

function Get-SecuritySnapshotValues {
    <# Pour le bilan avant/après : éléments suspects actifs (analyse rapide) et éléments en quarantaine. $null si non mesurable. #>
    $suspect = $null; $quar = $null
    try { $suspect = @(Get-StartupThreatFindings -Ctx $null -Quick | Where-Object { $_.Level -ne 'OK' }).Count } catch { }
    try { $quar = @(Get-QuarantineItems).Count } catch { }
    [pscustomobject]@{ SuspectActive = $suspect; Quarantined = $quar }
}

function New-SecurityResult {
    <# Résultat au modèle standard (affichage et exports HTML/TXT) à partir de l'audit, de la persistance et du scan de fichiers. #>
    param($Audit, $Persistence, $FileScan)
    $r = New-DiagResult -Module 'Security' -Title 'Security Guard — audit de sécurité léger' -Ctx $null
    $worst = { param($rows) if (@($rows | Where-Object Level -eq 'Crit').Count) { 'Crit' } elseif (@($rows | Where-Object Level -eq 'Warn').Count) { 'Warn' } else { 'OK' } }
    $flagTable = {
        param($s, $rows, $title)
        $t = foreach ($f in @($rows | Sort-Object -Property @{ Expression = 'Score'; Descending = $true })) {
            [pscustomobject][ordered]@{ 'Niveau' = $(if ($f.Level -eq 'Crit') { 'Suspect' } else { 'À examiner' }); 'Type' = $f.Kind; 'Nom' = $f.Name; 'Raisons' = $f.Reasons; 'Chemin' = $f.Path }
        }
        Add-DiagTable $s $title @($t) @('Niveau', 'Type', 'Nom', 'Raisons', 'Chemin')
    }
    if ($Audit) {
        Add-DiagSection $r 'Audit système' -Layout Tiles -Body {
            param($s)
            foreach ($a in @($Audit)) { Add-DiagItem $s $a.Label $a.Value $a.Status $a.Detail }
        }
    }
    if ($null -ne $Persistence) {
        Add-DiagSection $r 'Persistance suspecte' -Body {
            param($s)
            $all = @($Persistence); $bad = @($all | Where-Object { $_.Level -ne 'OK' })
            Add-DiagItem $s 'Éléments de démarrage analysés' ("{0}" -f $all.Count) 'Info' 'Clés Run, dossiers Démarrage, tâches planifiées hors Microsoft, dossiers Temp / AppData / Public.'
            Add-DiagItem $s 'Éléments à examiner' ("{0}" -f $bad.Count) $(if ($bad.Count) { & $worst $bad } else { 'OK' })
            if ($bad.Count) { & $flagTable $s $bad 'Éléments à examiner' }
            Add-DiagNote $s 'Ce sont des indices, pas des verdicts : un programme non signé ou lancé depuis AppData peut être légitime.'
        }
    }
    if ($FileScan) {
        Add-DiagSection $r 'Scan de fichiers' -Body {
            param($s)
            $sum = $FileScan.Summary; $bad = @($FileScan.Findings)
            Add-DiagItem $s 'Cible analysée' ([string]$sum.Path) 'Info'
            Add-DiagItem $s 'Fichiers analysés' ("{0} (empreintes calculées : {1})" -f $sum.Scanned, $sum.Hashed) 'Info' $(if ($sum.Truncated) { 'Limite de fichiers atteinte : analyse partielle.' } elseif ($sum.Cancelled) { 'Analyse interrompue.' })
            Add-DiagItem $s 'Éléments à examiner' ("{0}" -f $bad.Count) $(if ($bad.Count) { & $worst $bad } else { 'OK' })
            if ($bad.Count) { & $flagTable $s $bad 'Éléments à examiner' }
        }
    }
    $q = @(Get-QuarantineItems)
    Add-DiagSection $r 'Quarantaine' -Body {
        param($s)
        Add-DiagItem $s 'Éléments isolés' ("{0}" -f $q.Count) $(if ($q.Count) { 'Info' } else { 'OK' }) 'Dossier Data\Quarantine : rien n''est supprimé, tout est restaurable.'
        if ($q.Count) {
            $t = foreach ($i in $q) { [pscustomobject][ordered]@{ 'Type' = $i.Kind; 'Nom' = $i.Name; 'Date' = $i.Date; 'Origine' = $i.OriginalPath } }
            Add-DiagTable $s 'Éléments isolés' @($t) @('Type', 'Nom', 'Date', 'Origine')
        }
    }
    $r
}

#endregion

Export-ModuleMember -Function Get-FileSignatureState, Get-SuspicionReasons, Get-ThreatLevel, Test-MaliciousScriptContent, Get-KnownBadHashes,
    Invoke-SecurityAudit, Get-StartupThreatFindings, Invoke-StartupThreatScan, Invoke-FileHeuristicScan,
    Get-QuarantineDir, Read-QuarantineIndex, Get-QuarantineItems, Test-QuarantineForbidden, Move-FileToQuarantine, Disable-SuspiciousTask,
    Disable-SuspiciousStartup, Restore-FromQuarantine, Get-SecuritySnapshotValues, New-SecurityFinding, New-SecurityResult
