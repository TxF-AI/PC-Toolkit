<#
.SYNOPSIS
  Aide au lancement unifiée : DevEnv Doctor, PortDoctor, PC Toolkit et le pack « Suite ».

.DESCRIPTION
  Menu interactif : projet -> canal (Discord, Reddit, Hacker News, X, LinkedIn).
  Pour chaque choix, le script :
    - copie le texte pré-rédigé du LAUNCH_KIT.md correspondant dans le presse-papier ;
    - ouvre la page de publication dans le navigateur par défaut (titre / texte pré-remplis quand le site l'accepte) ;
    - rappelle (et montre dans l'Explorateur) le fichier média à glisser-déposer.
  Le script NE PUBLIE RIEN : tu relis, tu colles, tu cliques toi-même sur « Publier ».

  Dossiers attendus : ce script est dans « PC Toolkit » ; « devenv-doctor » et « port-doctor » sont ses voisins (même dossier parent).

.PARAMETER Project   1 = DevEnv Doctor, 2 = PortDoctor, 3 = PC Toolkit, 4 = Pack Suite (sinon menu).
.PARAMETER Channel   A = Discord, B = Reddit, C = Hacker News, D = X / Twitter, E = LinkedIn (sinon menu).
.PARAMETER Lang      EN ou FR (Discord, LinkedIn). Par défaut : demandé.
.PARAMETER Subreddit Nom du subreddit sans « r/ » (Reddit). Par défaut : demandé ; « all » = tous, un par un.
.PARAMETER Mode      single ou thread (X). Par défaut : demandé.
.PARAMETER NoOpen    Ne pas ouvrir le navigateur ni l'Explorateur.
.PARAMETER NoClipboard  Ne pas toucher au presse-papier.
.PARAMETER DryRun    = -NoOpen -NoClipboard : affiche seulement ce qui serait fait.
.PARAMETER SkipChecks   Ne pas vérifier l'état Git ni les liens GitHub au démarrage.

.EXAMPLE
  .\launch-all.ps1
.EXAMPLE
  .\launch-all.ps1 -Project 2 -Channel C -DryRun
#>
[CmdletBinding()]
param(
    [ValidateSet('1', '2', '3', '4')][string]$Project,
    [ValidateSet('A', 'B', 'C', 'D', 'E')][string]$Channel,
    [ValidateSet('EN', 'FR')][string]$Lang,
    [string]$Subreddit,
    [ValidateSet('single', 'thread')][string]$Mode,
    [switch]$NoOpen,
    [switch]$NoClipboard,
    [switch]$DryRun,
    [switch]$SkipChecks
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

$Here = $PSScriptRoot
$Parent = Split-Path -Parent $Here
$DoOpen = -not ($NoOpen -or $DryRun)
$DoClip = -not ($NoClipboard -or $DryRun)

# ───────────────────────── Définition des projets ─────────────────────────

$Projects = [ordered]@{
    '1' = @{
        Name = 'DevEnv Doctor (v0.2.0)'; Dir = (Join-Path $Parent 'devenv-doctor'); Kit = 'LAUNCH_KIT.md'
        Repo = 'https://github.com/TxF-AI/devenv-doctor'; Release = 'https://github.com/TxF-AI/devenv-doctor/releases/tag/v0.2.0'
        Media = @('assets\demo.gif', 'assets\ui-preview.png', 'assets\ui-diff.png')
        Subs = @('rust', 'windows', 'programming', 'CoolGithubProjects')
        Discord = @('Discord officiel Tauri (#showcase) : https://discord.gg/tauri', 'DevFR (salon projets)', 'Serveurs Rust FR/EN')
    }
    '2' = @{
        Name = 'PortDoctor (v0.1.0)'; Dir = (Join-Path $Parent 'port-doctor'); Kit = 'LAUNCH_KIT.md'
        Repo = 'https://github.com/TxF-AI/port-doctor'; Release = 'https://github.com/TxF-AI/port-doctor/releases/tag/v0.1.0'
        Media = @('assets\demo.gif', 'assets\ui-preview.png', 'assets\ui-smartkill.png')
        Subs = @('node', 'webdev', 'rust', 'windows', 'programming', 'CoolGithubProjects')
        Discord = @('Discord officiel Tauri (#showcase) : https://discord.gg/tauri', 'DevFR (salon projets)', 'Serveurs Rust FR/EN')
    }
    '3' = @{
        Name = 'PC-Toolkit (v1.6.0)'; Dir = $Here; Kit = 'LAUNCH_KIT.md'
        Repo = 'https://github.com/TxF-AI/PC-Toolkit'; Release = 'https://github.com/TxF-AI/PC-Toolkit/releases/tag/v1.6.0'
        Media = @('dist-launch\demo.gif', 'dist-launch\ui-dashboard.png', 'dist-launch\ui-presets.png')
        Subs = @('PowerShell', 'windows', 'programming', 'CoolGithubProjects')
        Discord = @('Serveurs PowerShell', 'DevFR (salon projets)', 'Communautes Windows / MAO (preset audio)')
    }
    '4' = @{
        Name = 'Pack Global « Suite Doctor & Windows Toolkit »'; Dir = $Here; Kit = 'LAUNCH_KIT_SUITE.md'
        Repo = 'https://github.com/TxF-AI?tab=repositories'; Release = $null
        MediaAbs = @(
            (Join-Path $Parent 'devenv-doctor\assets\demo.gif'),
            (Join-Path $Parent 'port-doctor\assets\demo.gif'),
            (Join-Path $Here 'dist-launch\demo.gif'))
        Subs = @('windows', 'programming', 'CoolGithubProjects', 'rust')
        Discord = @('Discord officiel Tauri (outils Rust) : https://discord.gg/tauri', 'Serveurs PowerShell (PC Toolkit)', 'DevFR (salon projets)')
    }
}

# ───────────────────────── Utilitaires ─────────────────────────

function Write-Title([string]$Text) { Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host "  [OK] $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "  [!]  $Text" -ForegroundColor Yellow }
function Write-Note([string]$Text) { Write-Host "       $Text" -ForegroundColor DarkGray }

function Read-Choice([string]$Prompt, [string[]]$Valid, [string]$Default = '') {
    while ($true) {
        $r = ([string](Read-Host $Prompt)).Trim().ToUpper()
        if (-not $r -and $Default) { return $Default }
        if ($Valid -contains $r) { return $r }
        Write-Warn 'Choix invalide.'
    }
}

function Get-Media($P) {
    if ($P.MediaAbs) { return @($P.MediaAbs) }
    return @($P.Media | ForEach-Object { Join-Path $P.Dir $_ })
}

function Copy-ToClipboard([string]$Text, [string]$What) {
    if (-not $Text) { Write-Warn "Texte introuvable dans le kit : $What"; return $false }
    if ($DoClip) {
        Set-Clipboard -Value $Text
        Write-Ok "Presse-papier : $What ($($Text.Length) caractères). Colle avec Ctrl+V."
    }
    else { Write-Note "[simulation] presse-papier : $What ($($Text.Length) caractères)" }
    return $true
}

function Open-Page([string]$Url, [string]$What) {
    if ($DoOpen) {
        Start-Process $Url
        Write-Ok "Navigateur : $What"
    }
    else { Write-Note "[simulation] navigateur : $What" }
    Write-Note $(if ($Url.Length -gt 140) { $Url.Substring(0, 140) + '...' } else { $Url })
}

function Show-Media($P, [bool]$Open = $true) {
    $files = Get-Media $P
    Write-Host '  Média à glisser-déposer dans la publication :' -ForegroundColor Magenta
    $first = $true
    foreach ($f in $files) {
        if (Test-Path -LiteralPath $f) {
            $kb = [math]::Round((Get-Item -LiteralPath $f).Length / 1KB)
            Write-Host ('    {0}{1}  ({2} Ko)' -f $(if ($first) { '> ' } else { '  ' }), $f, $kb) -ForegroundColor White
        }
        else { Write-Warn "Fichier média absent : $f" }
        $first = $false
    }
    $main = $files | Select-Object -First 1
    if ($DoOpen -and $Open -and $main -and (Test-Path -LiteralPath $main)) {
        Start-Process explorer.exe -ArgumentList "/select,`"$main`""
    }
}

# ───────────────────────── Lecture du LAUNCH_KIT ─────────────────────────

function Get-Section([string]$Text, [int]$N) {
    $m = [regex]::Match($Text, "(?ms)^## $N\. .*?(?=^## \d+\. |\z)")
    if ($m.Success) { return $m.Value }
    return ''
}

function Get-Fenced([string]$Section, [string]$Anchor) {
    $i = $Section.IndexOf($Anchor)
    if ($i -lt 0) { return $null }
    $m = [regex]::Match($Section.Substring($i), '(?s)```[a-z]*\n(.*?)\n```')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return $null
}

function Get-Block([string]$Section, [string]$Anchor) {
    $i = $Section.IndexOf($Anchor)
    if ($i -lt 0) { return $null }
    $rest = $Section.Substring($i)
    $nl = $rest.IndexOf("`n")
    if ($nl -lt 0) { return $null }
    $rest = $rest.Substring($nl + 1)
    return ($rest -replace '(?s)\n---\s*$', '').Trim()
}

function Get-FirstMatch([string]$Text, [string]$Anchor, [string]$Pattern) {
    $i = $Text.IndexOf($Anchor)
    if ($i -lt 0) { return $null }
    $m = [regex]::Match($Text.Substring($i), $Pattern)
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return $null
}

function Read-Kit([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "LAUNCH_KIT introuvable : $Path" }
    $t = ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)) -replace "`r`n", "`n"
    $reddit = Get-Section $t 1; $hn = Get-Section $t 2; $soc = Get-Section $t 3; $dis = Get-Section $t 4
    return @{
        RedditTitle = Get-FirstMatch $reddit '**Titre (au choix)**' '(?m)^- `(.+)`\s*$'
        RedditBody  = Get-Block $reddit '**Corps**'
        HnTitle     = Get-FirstMatch $hn '**Titre**' '(?m)^`(.+)`\s*$'
        HnUrl       = Get-FirstMatch $hn '**URL :**' '\*\*URL :\*\*\s*(\S+)'
        HnComment   = Get-Block $hn '**Premier commentaire'
        XPost       = Get-Fenced $soc '**X ('
        XThread2    = Get-Fenced $soc '**X (thread'
        LiFr        = Get-Fenced $soc '**LinkedIn (FR)**'
        LiEn        = Get-Fenced $soc '**LinkedIn (EN'
        DiscordEn   = Get-Fenced $dis '**Message (EN)**'
        DiscordFr   = Get-Fenced $dis '**Message (FR'
    }
}

# ───────────────────────── Vérifications (Git + liens) ─────────────────────────

function Test-Projects {
    Write-Title 'Vérification des dépôts et des liens'
    foreach ($key in '1', '2', '3') {
        $P = $Projects[$key]
        if (-not (Test-Path -LiteralPath $P.Dir)) { Write-Warn "$($P.Name) : dossier introuvable ($($P.Dir))"; continue }
        $state = 'Git indisponible'
        if (Get-Command git -ErrorAction SilentlyContinue) {
            $dirty = @(git -C $P.Dir status --porcelain 2>$null).Count
            $head = (git -C $P.Dir status -sb 2>$null | Select-Object -First 1)
            $ahead = if ($head -match 'ahead (\d+)') { [int]$Matches[1] } else { 0 }
            $state = if ($dirty) { "$dirty fichier(s) modifié(s)/non suivi(s)" } elseif ($ahead) { "$ahead commit(s) non poussé(s)" } else { 'propre, à jour avec origin' }
            if ($dirty -or $ahead) { Write-Warn ('{0,-22} {1}' -f $P.Name, $state) } else { Write-Ok ('{0,-22} {1}' -f $P.Name, $state) }
        }
        else { Write-Warn "$($P.Name) : $state" }
        foreach ($u in @($P.Repo, $P.Release)) {
            if (-not $u) { continue }
            try {
                $r = Invoke-WebRequest -Uri $u -Method Head -UseBasicParsing -TimeoutSec 8
                Write-Note ('HTTP {0}  {1}' -f $r.StatusCode, $u)
            }
            catch { Write-Warn "Lien injoignable : $u" }
        }
    }
}

# ───────────────────────── Canaux ─────────────────────────

function Invoke-Discord($P, $Kit) {
    Write-Title "Discord (#showcase) — $($P.Name)"
    $l = if ($Lang) { $Lang.ToUpper() } else { Read-Choice '  Langue du message [E]N / [F]R (défaut E)' @('E', 'F', 'EN', 'FR') 'E' }
    $text = if ($l -like 'F*') { $Kit.DiscordFr } else { $Kit.DiscordEn }
    [void](Copy-ToClipboard $text 'message Discord')
    Open-Page 'https://discord.com/channels/@me' 'Discord (web)'
    Write-Host '  Salons suggérés (lis les règles du salon avant de poster) :' -ForegroundColor Magenta
    $P.Discord | ForEach-Object { Write-Note "- $_" }
    Show-Media $P
}

function Invoke-Reddit($P, $Kit) {
    Write-Title "Reddit — $($P.Name)"
    $subs = @($P.Subs)
    $chosen = $null
    if ($Subreddit) { $chosen = if ($Subreddit -eq 'all') { $subs } else { @($Subreddit -replace '^r/', '') } }
    else {
        for ($i = 0; $i -lt $subs.Count; $i++) { Write-Host ('  [{0}] r/{1}' -f ($i + 1), $subs[$i]) }
        Write-Host '  [T] Tous, un par un (déconseillé le même jour)'
        $c = Read-Choice '  Subreddit' (@(1..$subs.Count | ForEach-Object { "$_" }) + 'T')
        $chosen = if ($c -eq 'T') { $subs } else { @($subs[[int]$c - 1]) }
    }
    if ($chosen.Count -gt 1) { Write-Warn 'Beaucoup de subreddits d''un coup = risque de classement spam : étale sur plusieurs jours.' }
    $n = 0
    foreach ($s in $chosen) {
        $n++
        Write-Host ''; Write-Host "  -> r/$s" -ForegroundColor White
        Write-Note "Titre : $($Kit.RedditTitle)"
        [void](Copy-ToClipboard $Kit.RedditBody 'corps du post Reddit')
        $title = [uri]::EscapeDataString([string]$Kit.RedditTitle)
        $url = if ($s -eq 'programming') {
            "https://www.reddit.com/r/$s/submit?type=LINK&url=$([uri]::EscapeDataString($P.Repo))&title=$title"
        }
        else { "https://www.reddit.com/r/$s/submit?type=TEXT&title=$title" }
        Open-Page $url "r/$s (titre pré-rempli)"
        if ($s -eq 'programming') { Write-Note 'r/programming : post de type lien (le corps copié sert de premier commentaire).' }
        else { Write-Note 'Colle le corps dans la zone de texte (Ctrl+V), choisis le flair « Project » / « Show & Tell » si proposé.' }
        if ($n -lt $chosen.Count -and $DoOpen) { [void](Read-Host '  Entrée pour passer au subreddit suivant') }
    }
    Show-Media $P
}

function Invoke-HackerNews($P, $Kit) {
    Write-Title "Hacker News (Show HN) — $($P.Name)"
    Write-Note "Titre : $($Kit.HnTitle)"
    Write-Note "URL   : $($Kit.HnUrl)"
    [void](Copy-ToClipboard $Kit.HnComment 'premier commentaire Show HN (à poster juste après la soumission)')
    $url = 'https://news.ycombinator.com/submitlink?u={0}&t={1}' -f [uri]::EscapeDataString([string]$Kit.HnUrl), [uri]::EscapeDataString([string]$Kit.HnTitle)
    Open-Page $url 'soumission Show HN (titre et URL pré-remplis)'
    Write-Note 'Après avoir soumis : ouvre ta soumission et colle le commentaire (Ctrl+V). HN n''affiche pas les images : mets le lien du GIF dans le commentaire.'
    if ($P.Name -like 'Pack*') { Write-Warn 'HN préfère un seul projet par Show HN : envisage de soumettre le projet principal seul.' }
    Show-Media $P $false
}

function Get-XLength([string]$Text) {
    # X compte chaque lien comme 23 caractères
    $t = [regex]::Replace($Text, 'https?://\S+', ('x' * 23))
    return [regex]::Replace($t, '(?<![/\w.])(?:github\.com|x\.com)/\S+', ('x' * 23)).Length
}

function Invoke-X($P, $Kit) {
    Write-Title "X / Twitter — $($P.Name)"
    $m = if ($Mode) { $Mode } else { if ((Read-Choice '  [1] Post unique  [2] Thread (2 tweets)' @('1', '2') '1') -eq '2') { 'thread' } else { 'single' } }
    $len = Get-XLength $Kit.XPost
    if ($len -gt 280) { Write-Warn "Tweet 1 : environ $len caractères (> 280) : raccourcis-le avant de publier." } else { Write-Note "Tweet 1 : environ $len / 280 caractères." }
    $post = [uri]::EscapeDataString([string]$Kit.XPost)
    if ($m -eq 'thread') {
        $len2 = Get-XLength $Kit.XThread2
        if ($len2 -gt 280) { Write-Warn "Tweet 2 : environ $len2 caractères (> 280)." } else { Write-Note "Tweet 2 : environ $len2 / 280 caractères." }
        [void](Copy-ToClipboard $Kit.XThread2 'tweet 2 du thread (à coller en réponse au tweet 1)')
        Open-Page "https://x.com/intent/post?text=$post" 'composeur X (tweet 1 pré-rempli)'
        Write-Note 'Joins le GIF au tweet 1, publie, puis réponds avec le texte du presse-papier (Ctrl+V).'
    }
    else {
        [void](Copy-ToClipboard $Kit.XPost 'post X')
        Open-Page "https://x.com/intent/post?text=$post" 'composeur X (texte pré-rempli)'
    }
    Show-Media $P
}

function Invoke-LinkedIn($P, $Kit) {
    Write-Title "LinkedIn — $($P.Name)"
    $l = if ($Lang) { $Lang.ToUpper() } else { Read-Choice '  Langue [F]R (complet) / [E]N (court) (défaut F)' @('E', 'F', 'EN', 'FR') 'F' }
    $text = if ($l -like 'E*') { $Kit.LiEn } else { $Kit.LiFr }
    [void](Copy-ToClipboard $text 'post LinkedIn')
    $enc = [uri]::EscapeDataString([string]$text)
    $url = if ($enc.Length -le 6000) { "https://www.linkedin.com/feed/?shareActive=true&text=$enc" } else { 'https://www.linkedin.com/feed/?shareActive=true' }
    Open-Page $url 'LinkedIn (composeur ; texte pré-rempli si accepté, sinon Ctrl+V)'
    Write-Note 'Ajoute le média au post, mets le lien du dépôt en premier commentaire si le lien n''est pas dans le texte.'
    Show-Media $P
}

# ───────────────────────── Menus ─────────────────────────

function Invoke-Channel([string]$Key, [string]$Ch) {
    $P = $Projects[$Key]
    $kitPath = Join-Path $P.Dir $P.Kit
    $kit = Read-Kit $kitPath
    switch ($Ch) {
        'A' { Invoke-Discord $P $kit }
        'B' { Invoke-Reddit $P $kit }
        'C' { Invoke-HackerNews $P $kit }
        'D' { Invoke-X $P $kit }
        'E' { Invoke-LinkedIn $P $kit }
    }
}

function Show-ChannelMenu([string]$Key) {
    $P = $Projects[$Key]
    while ($true) {
        Write-Title $P.Name
        Write-Host '  [A] Discord (Showcase DevFR / Tauri / PowerShell)'
        Write-Host ('  [B] Reddit (' + (($P.Subs | ForEach-Object { "r/$_" }) -join ', ') + ')')
        Write-Host '  [C] Hacker News (Show HN)'
        Write-Host '  [D] X / Twitter (Thread ou Post unique)'
        Write-Host '  [E] LinkedIn'
        Write-Host '  [R] Retour    [Q] Quitter'
        $c = Read-Choice 'Canal' @('A', 'B', 'C', 'D', 'E', 'R', 'Q')
        if ($c -eq 'R') { return $true }
        if ($c -eq 'Q') { return $false }
        try { Invoke-Channel $Key $c } catch { Write-Warn $_.Exception.Message }
    }
}

function Show-MainMenu {
    while ($true) {
        Write-Title 'launch-all : kit de lancement des projets'
        Write-Host '  [1] DevEnv Doctor (v0.2.0)'
        Write-Host '  [2] PortDoctor (v0.1.0)'
        Write-Host '  [3] PC-Toolkit'
        Write-Host '  [4] Pack Global "Suite Doctor & Windows Toolkit" (Lancement groupé)'
        Write-Host '  [Q] Quitter'
        $c = Read-Choice 'Projet' @('1', '2', '3', '4', 'Q')
        if ($c -eq 'Q') { return }
        if (-not (Show-ChannelMenu $c)) { return }
    }
}

# ───────────────────────── Programme principal ─────────────────────────

Write-Host 'launch-all : ce script ne publie rien. Il copie les textes, ouvre les pages et te montre les médias.' -ForegroundColor DarkGray
if ($DryRun) { Write-Host '[DryRun] aucune ouverture de page, aucun presse-papier.' -ForegroundColor Yellow }
if (-not $SkipChecks) { Test-Projects }

if ($Project -and $Channel) {
    Invoke-Channel $Project $Channel.ToUpper()
}
elseif ($Project) {
    [void](Show-ChannelMenu $Project)
}
else {
    Show-MainMenu
}
Write-Host ''
