#requires -Version 5.1
<#
    Core.psm1 — Noyau de PC Toolkit
    ---------------------------------
    - Modèle de résultat commun à tous les modules (Résultat > Sections > Éléments / Tableaux / Notes)
    - Progression et annulation (contexte partagé avec l'interface)
    - Historique (JSON) et journal des actions
    - Export HTML (thème sombre, accent rouge néon)
    Aucune fonction de ce module ne modifie le système.
#>

$script:AppRoot = Split-Path $PSScriptRoot -Parent

#region Chemins et utilitaires ----------------------------------------------------------

function Get-AppPath {
    <# Renvoie un dossier de l'application (créé s'il n'existe pas). #>
    param([ValidateSet('Root', 'History', 'Reports', 'Logs', 'Snapshots')][string]$Kind = 'Root')
    $p = switch ($Kind) {
        'Snapshots' { Join-Path $script:AppRoot 'Data\Snapshots' }
        'Root'    { $script:AppRoot }
        'History' { Join-Path $script:AppRoot 'Data\History' }
        'Reports' { Join-Path $script:AppRoot 'Reports' }
        'Logs'    { Join-Path $script:AppRoot 'Data\Logs' }
    }
    if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    $p
}

function Get-AppVersion {
    <# Version unique de l'application, lue dans le fichier VERSION à la racine. #>
    $f = Join-Path $script:AppRoot 'VERSION'
    $v = if (Test-Path -LiteralPath $f) { (Get-Content -LiteralPath $f -TotalCount 1 -ErrorAction SilentlyContinue) } else { $null }
    if ($v) { $v.Trim() } else { '0.0.0' }
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-AppLog {
    <# Journal technique (erreurs, actions). Ne lève jamais d'exception. #>
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR', 'ACTION')][string]$Level = 'INFO')
    try {
        $file = Join-Path (Get-AppPath Logs) ('toolkit_{0:yyyyMMdd}.log' -f (Get-Date))
        Add-Content -LiteralPath $file -Value ('{0:HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message) -Encoding UTF8
    } catch { }
}

function Format-Bytes {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return '{0:N2} To' -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return '{0:N1} Go' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N0} Mo' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} Ko' -f ($Bytes / 1KB) }
    return '{0:N0} o' -f $Bytes
}

function Format-Span {
    param([TimeSpan]$Span)
    if ($Span.TotalDays -ge 1) { return '{0} j {1} h {2:00} min' -f [int][math]::Floor($Span.TotalDays), $Span.Hours, $Span.Minutes }
    if ($Span.TotalHours -ge 1) { return '{0} h {1:00} min' -f $Span.Hours, $Span.Minutes }
    return '{0} min' -f [int]$Span.TotalMinutes
}

function Get-Percentile {
    <# Percentile simple (méthode du rang le plus proche) sur un tableau déjà trié. #>
    param([double[]]$Sorted, [double]$P)
    if (-not $Sorted -or $Sorted.Count -eq 0) { return $null }
    $i = [int][math]::Ceiling($P / 100 * $Sorted.Count) - 1
    $Sorted[[math]::Max(0, [math]::Min($Sorted.Count - 1, $i))]
}

function Get-SafeCim {
    <# Get-CimInstance qui renvoie $null au lieu d'échouer (classe absente, accès refusé...). #>
    param([string]$ClassName, [string]$Namespace = 'root/cimv2', [string]$Filter)
    try {
        $a = @{ ClassName = $ClassName; Namespace = $Namespace; ErrorAction = 'Stop' }
        if ($Filter) { $a.Filter = $Filter }
        Get-CimInstance @a
    } catch { $null }
}

#endregion

#region Progression / annulation --------------------------------------------------------

function Update-DiagProgress {
    <# Met à jour le contexte partagé (hashtable synchronisée lue par l'interface). #>
    param($Ctx, [int]$Percent, [string]$Status)
    if ($Ctx) {
        $Ctx.Progress = [math]::Max(0, [math]::Min(100, $Percent))
        if ($Status) { $Ctx.Status = $Status }
    }
}

function Test-DiagCancel {
    param($Ctx)
    return [bool]($Ctx -and $Ctx.Cancel)
}

#endregion

#region Modèle de résultat --------------------------------------------------------------

function New-DiagResult {
    <# -Ctx : contexte partagé avec l'interface ; permet d'arrêter l'analyse entre deux sections. #>
    param([string]$Module, [string]$Title, $Ctx)
    $script:DiagCtx = $Ctx
    [pscustomobject]@{
        Module      = $Module
        Title       = $Title
        Date        = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Computer    = $env:COMPUTERNAME
        IsAdmin     = [bool](Test-IsAdmin)
        DurationSec = 0
        Cancelled   = $false
        Sections    = New-Object System.Collections.ArrayList
    }
}

function Add-DiagSection {
    <#
        Ajoute une section. Le corps reçoit la section en paramètre : { param($s) ... }.
        Toute exception est capturée et affichée dans la section : un module qui échoue
        n'empêche jamais les autres de s'afficher.
    #>
    param($Result, [string]$Title, [ValidateSet('List', 'Tiles')][string]$Layout = 'List', [scriptblock]$Body)
    # Annulation demandée : on n'exécute plus de nouvelle section, le résultat partiel est conservé
    if (Test-DiagCancel $script:DiagCtx) { $Result.Cancelled = $true; return }
    $s = [pscustomobject]@{
        Title  = $Title
        Layout = $Layout
        Items  = New-Object System.Collections.ArrayList
        Tables = New-Object System.Collections.ArrayList
        Notes  = New-Object System.Collections.ArrayList
    }
    try { & $Body $s }
    catch {
        Add-DiagItem $s 'Erreur pendant l''analyse' $_.Exception.Message 'Crit'
        Write-AppLog ("[{0}] {1}" -f $Title, $_.Exception.Message) 'ERROR'
    }
    [void]$Result.Sections.Add($s)
}

function Add-DiagItem {
    <#
        Statuts : OK, Warn (à surveiller), Crit (problème), Info, NA (non disponible).
        Une valeur vide devient « Non disponible » : on n'invente jamais de mesure.
    #>
    param(
        $Section,
        [string]$Label,
        $Value,
        [ValidateSet('OK', 'Warn', 'Crit', 'Info', 'NA')][string]$Status = 'Info',
        [string]$Detail = ''
    )
    if ($null -eq $Value -or "$Value" -eq '') {
        $Value = 'Non disponible'
        if ($Status -eq 'Info') { $Status = 'NA' }
    }
    [void]$Section.Items.Add([pscustomobject]@{ Label = $Label; Value = "$Value"; Status = $Status; Detail = $Detail })
}

function Add-DiagTable {
    <# Ajoute un tableau. Les valeurs sont converties en texte pour l'affichage, le JSON et le HTML. #>
    param($Section, [string]$Title, $Rows, [string[]]$Columns)
    $list = @($Rows | Where-Object { $null -ne $_ })
    if (-not $Columns -and $list.Count) { $Columns = @($list[0].PSObject.Properties.Name) }
    $clean = foreach ($r in $list) {
        $o = [ordered]@{}
        foreach ($c in $Columns) { $v = $r.$c; $o[$c] = if ($null -eq $v) { '' } else { "$v" } }
        [pscustomobject]$o
    }
    [void]$Section.Tables.Add([pscustomobject]@{ Title = $Title; Columns = @($Columns); Rows = @($clean) })
}

function Add-DiagNote {
    param($Section, [string]$Text)
    [void]$Section.Notes.Add($Text)
}

function Get-DiagStats {
    <# Compte les statuts d'un résultat (pour l'historique et les résumés). #>
    param($Result)
    $st = @{ OK = 0; Warn = 0; Crit = 0; Info = 0; NA = 0 }
    foreach ($s in @($Result.Sections)) { foreach ($i in @($s.Items)) { if ($st.ContainsKey([string]$i.Status)) { $st[[string]$i.Status]++ } } }
    $st
}

#endregion

#region Historique ----------------------------------------------------------------------

$script:ModuleTitles = @{ Dashboard = 'Tableau de bord'; Hardware = 'Diagnostic matériel'; Network = 'Diagnostic réseau'; Windows = 'Analyse Windows'; Storage = 'Analyse du stockage'; Audio = 'Diagnostic audio'; Bilan = 'Bilan avant / après' }

function Save-DiagHistory {
    <#
        Le résumé est inscrit dans le nom du fichier (problèmes, alertes, OK, durée, admin) :
        la page Historique s'affiche ainsi sans ouvrir chaque fichier, même avec des milliers d'entrées.
        Exemple : 20261108-231051_Dashboard_c2-w5-o9-d10.6-a0.json
    #>
    param($Result)
    $st = Get-DiagStats $Result
    $name = '{0:yyyyMMdd-HHmmss}_{1}_c{2}-w{3}-o{4}-d{5}-a{6}.json' -f (Get-Date), $Result.Module, $st.Crit, $st.Warn, $st.OK,
        ([string]$Result.DurationSec).Replace(',', '.'), [int][bool]$Result.IsAdmin
    $path = Join-Path (Get-AppPath History) $name
    $Result | ConvertTo-Json -Depth 10 -Compress | Set-Content -LiteralPath $path -Encoding UTF8
    $path
}

function Get-DiagHistory {
    <# Liste l'historique, du plus récent au plus ancien. Les fichiers illisibles sont ignorés. #>
    $rx = '^(\d{8})-(\d{6})_(\w+)_c(\d+)-w(\d+)-o(\d+)-d([\d\.]+)-a([01])\.json$'
    Get-ChildItem -LiteralPath (Get-AppPath History) -Filter '*.json' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object {
            # Voie rapide : résumé lu dans le nom du fichier
            if ($_.Name -match $rx) {
                $d = $Matches[1]; $h = $Matches[2]
                $title = if ($script:ModuleTitles.ContainsKey($Matches[3])) { $script:ModuleTitles[$Matches[3]] } else { $Matches[3] }
                return [pscustomobject]@{
                    Date      = '{0}-{1}-{2} {3}:{4}:{5}' -f $d.Substring(0, 4), $d.Substring(4, 2), $d.Substring(6, 2), $h.Substring(0, 2), $h.Substring(2, 2), $h.Substring(4, 2)
                    Module    = $title
                    Problèmes = [int]$Matches[4]
                    Alertes   = [int]$Matches[5]
                    OK        = [int]$Matches[6]
                    Durée     = '{0} s' -f $Matches[7]
                    Admin     = if ($Matches[8] -eq '1') { 'Oui' } else { 'Non' }
                    Path      = $_.FullName
                }
            }
            # Anciens fichiers (sans résumé dans le nom) : lecture du contenu
            try {
                $j = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                $st = Get-DiagStats $j
                [pscustomobject]@{
                    Date      = $j.Date
                    Module    = $j.Title
                    Problèmes = $st.Crit
                    Alertes   = $st.Warn
                    OK        = $st.OK
                    Durée     = '{0} s' -f $j.DurationSec
                    Admin     = if ($j.IsAdmin) { 'Oui' } else { 'Non' }
                    Path      = $_.FullName
                }
            } catch { Write-AppLog "Historique illisible : $($_.FullName)" 'WARN' }
        }
}

function Import-DiagHistory {
    param([string]$Path)
    Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

#endregion

#region Export HTML ---------------------------------------------------------------------

function ConvertTo-HtmlSafe { param($Text) [System.Net.WebUtility]::HtmlEncode([string]$Text) }

function Export-DiagHtml {
    <# Exporte un ou plusieurs résultats dans un rapport HTML autonome (aucune ressource externe). #>
    param([object[]]$Results, [string]$Path)
    if (-not $Path) {
        $mod = if ($Results.Count -eq 1) { $Results[0].Module } else { 'Complet' }
        $Path = Join-Path (Get-AppPath Reports) ('Rapport_{0}_{1:yyyyMMdd-HHmmss}.html' -f $mod, (Get-Date))
    }
    $label = @{ OK = 'OK'; Warn = 'À surveiller'; Crit = 'Problème'; Info = 'Info'; NA = 'N/D' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append(@'
<!DOCTYPE html><html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Rapport PC Toolkit</title><style>
:root{--bg:#0b0709;--card:#150a0d;--line:#2e1016;--text:#f2e6e8;--muted:#9c8a8e;--accent:#ff2a3d;--ok:#3ddc84;--warn:#ffb020;--info:#6ea8fe;--na:#6b5b5f}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.5 "Segoe UI",system-ui,sans-serif;padding:32px 16px}
main{max-width:1100px;margin:0 auto}h1{font-family:Bahnschrift,"Segoe UI",sans-serif;font-weight:600;color:var(--accent);text-shadow:0 0 14px rgba(255,42,61,.55);margin:0 0 4px;font-size:30px;letter-spacing:.5px}
.sub{color:var(--muted);margin-bottom:28px}h2{font-family:Bahnschrift,"Segoe UI",sans-serif;font-weight:600;font-size:22px;margin:36px 0 6px;border-bottom:1px solid var(--line);padding-bottom:8px}
.meta{color:var(--muted);font-size:12px;margin-bottom:14px}.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px 18px;margin:12px 0}
h3{margin:0 0 10px;color:#ff8a95;font-size:15px;text-transform:uppercase;letter-spacing:1px}h4{margin:14px 0 6px;color:var(--muted);font-size:13px}
.item{display:grid;grid-template-columns:110px 260px 1fr;gap:12px;padding:6px 0;border-top:1px solid #1f0d12}.item:first-of-type{border-top:0}
.lbl{color:var(--muted)}.val{word-break:break-word}.det{color:var(--muted);font-size:12px}
.b{display:inline-block;font-size:11px;font-weight:600;border-radius:999px;padding:2px 9px;border:1px solid}
.b-OK{color:var(--ok);border-color:var(--ok)}.b-Warn{color:var(--warn);border-color:var(--warn)}.b-Crit{color:#fff;background:var(--accent);border-color:var(--accent)}.b-Info{color:var(--info);border-color:var(--info)}.b-NA{color:var(--na);border-color:var(--na)}
table{width:100%;border-collapse:collapse;font-size:12.5px}th{text-align:left;color:#ff8a95;background:#1d0c11;padding:6px 8px;font-weight:600}td{padding:5px 8px;border-top:1px solid #1f0d12;word-break:break-word}
.tw{overflow-x:auto}.note{color:var(--muted);font-style:italic;font-size:12.5px;margin-top:8px}
.sum{display:flex;gap:10px;flex-wrap:wrap;margin-bottom:6px}.foot{color:var(--na);font-size:12px;margin-top:40px;text-align:center}
@media(max-width:700px){.item{grid-template-columns:1fr}}
</style></head><body><main>
'@)
    [void]$sb.AppendFormat('<h1>&#x26A1;&#xFE0E; PC//TOOLKIT</h1><div class="sub">Rapport généré le {0:dd/MM/yyyy à HH:mm} sur {1} · PC Toolkit {2}</div>', (Get-Date), (ConvertTo-HtmlSafe $env:COMPUTERNAME), (Get-AppVersion))

    foreach ($r in $Results) {
        $st = Get-DiagStats $r
        [void]$sb.AppendFormat('<h2>{0}</h2><div class="meta">Exécuté le {1} · durée {2} s · mode {3}{4}</div>',
            (ConvertTo-HtmlSafe $r.Title), (ConvertTo-HtmlSafe $r.Date), $r.DurationSec,
            $(if ($r.IsAdmin) { 'administrateur' } else { 'standard (certaines mesures nécessitent les droits administrateur)' }),
            $(if ($r.Cancelled) { ' · <b>analyse interrompue</b>' } else { '' }))
        [void]$sb.AppendFormat('<div class="sum"><span class="b b-Crit">{0} problème(s)</span><span class="b b-Warn">{1} à surveiller</span><span class="b b-OK">{2} OK</span></div>', $st.Crit, $st.Warn, $st.OK)

        foreach ($s in @($r.Sections)) {
            [void]$sb.AppendFormat('<div class="card"><h3>{0}</h3>', (ConvertTo-HtmlSafe $s.Title))
            foreach ($i in @($s.Items)) {
                $stt = [string]$i.Status
                [void]$sb.AppendFormat('<div class="item"><div><span class="b b-{0}">{1}</span></div><div class="lbl">{2}</div><div class="val">{3}{4}</div></div>',
                    $stt, $label[$stt], (ConvertTo-HtmlSafe $i.Label), (ConvertTo-HtmlSafe $i.Value),
                    $(if ($i.Detail) { '<div class="det">' + (ConvertTo-HtmlSafe $i.Detail) + '</div>' } else { '' }))
            }
            foreach ($t in @($s.Tables)) {
                if ($t.Title) { [void]$sb.AppendFormat('<h4>{0}</h4>', (ConvertTo-HtmlSafe $t.Title)) }
                $cols = @($t.Columns)
                [void]$sb.Append('<div class="tw"><table><tr>')
                foreach ($c in $cols) { [void]$sb.AppendFormat('<th>{0}</th>', (ConvertTo-HtmlSafe $c)) }
                [void]$sb.Append('</tr>')
                foreach ($row in @($t.Rows)) {
                    [void]$sb.Append('<tr>')
                    foreach ($c in $cols) { [void]$sb.AppendFormat('<td>{0}</td>', (ConvertTo-HtmlSafe $row.$c)) }
                    [void]$sb.Append('</tr>')
                }
                if (@($t.Rows).Count -eq 0) { [void]$sb.AppendFormat('<tr><td colspan="{0}" class="det">Aucune entrée</td></tr>', [math]::Max(1, $cols.Count)) }
                [void]$sb.Append('</table></div>')
            }
            foreach ($n in @($s.Notes)) { [void]$sb.AppendFormat('<div class="note">{0}</div>', (ConvertTo-HtmlSafe $n)) }
            [void]$sb.Append('</div>')
        }
    }
    [void]$sb.Append('<div class="foot">PC Toolkit — diagnostics en lecture seule. Les valeurs « Non disponible » ne sont pas exposées par le matériel ou Windows : elles ne sont jamais estimées.</div></main></body></html>')
    [IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
    $Path
}

#endregion

#region Export texte (.txt, lisible dans le Bloc-notes) ---------------------------------

function Format-TextTable {
    <# Tableau en colonnes alignées (police à chasse fixe du Bloc-notes). Valeurs longues tronquées à 60 caractères. #>
    param($Table)
    $cols = @($Table.Columns); $rows = @($Table.Rows)
    $max = 60
    $cut = { param($v) $v = ([string]$v) -replace '\s+', ' '; if ($v.Length -gt $max) { $v.Substring(0, $max - 1) + '…' } else { $v } }
    $w = @{}
    foreach ($c in $cols) {
        $len = ($rows | ForEach-Object { (& $cut $_.$c).Length } | Measure-Object -Maximum).Maximum
        $w[$c] = [math]::Max(([string]$c).Length, [int]$len)
    }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('    ' + (($cols | ForEach-Object { ([string]$_).PadRight($w[$_]) }) -join '  '))
    $lines.Add('    ' + (($cols | ForEach-Object { '-' * $w[$_] }) -join '  '))
    foreach ($r in $rows) { $lines.Add('    ' + (($cols | ForEach-Object { (& $cut $r.$_).PadRight($w[$_]) }) -join '  ')) }
    if (-not $rows.Count) { $lines.Add('    (aucune entrée)') }
    $lines
}

function Export-DiagText {
    <# Exporte un ou plusieurs résultats en texte brut (UTF-8 avec BOM : accents corrects dans le Bloc-notes). #>
    param([object[]]$Results, [string]$Path)
    if (-not $Path) {
        $mod = if ($Results.Count -eq 1) { $Results[0].Module } else { 'Complet' }
        $Path = Join-Path (Get-AppPath Reports) ('Rapport_{0}_{1:yyyyMMdd-HHmmss}.txt' -f $mod, (Get-Date))
    }
    $tag = @{ OK = '[  OK  ]'; Warn = '[ATTENT]'; Crit = '[ PROB ]'; Info = '[ INFO ]'; NA = '[ N/D  ]' }
    $out = New-Object System.Collections.Generic.List[string]
    $line = '=' * 78
    $out.Add($line)
    $out.Add(('  {0} PC//TOOLKIT — rapport du {1:dd/MM/yyyy à HH:mm} — {2} — v{3}' -f [char]0x26A1, (Get-Date), $env:COMPUTERNAME, (Get-AppVersion)))
    $out.Add($line)
    $out.Add('  Légende : [ PROB ] problème · [ATTENT] à surveiller · [  OK  ] · [ INFO ] · [ N/D  ] non disponible')
    foreach ($r in $Results) {
        $st = Get-DiagStats $r
        $out.Add(''); $out.Add('')
        $out.Add('#' * 78)
        $out.Add(('  {0}' -f ([string]$r.Title).ToUpper()))
        $out.Add(('  Exécuté le {0} · {1} s · mode {2}{3}' -f $r.Date, $r.DurationSec, $(if ($r.IsAdmin) { 'administrateur' } else { 'standard' }), $(if ($r.Cancelled) { ' · INTERROMPU' } else { '' })))
        $out.Add(('  Bilan : {0} problème(s), {1} à surveiller, {2} OK' -f $st.Crit, $st.Warn, $st.OK))
        $out.Add('#' * 78)
        foreach ($s in @($r.Sections)) {
            $out.Add('')
            $out.Add(('--- {0} ' -f ([string]$s.Title).ToUpper()).PadRight(78, '-'))
            foreach ($i in @($s.Items)) {
                $out.Add(('  {0} {1} : {2}' -f $tag[[string]$i.Status], ([string]$i.Label).Trim(), $i.Value))
                if ($i.Detail) { $out.Add(('             → {0}' -f $i.Detail)) }
            }
            foreach ($t in @($s.Tables)) {
                $out.Add('')
                if ($t.Title) { $out.Add("  $($t.Title) :") }
                foreach ($l in (Format-TextTable $t)) { $out.Add($l) }
            }
            foreach ($n in @($s.Notes)) { $out.Add(''); $out.Add("  i  $n") }
        }
    }
    $out.Add(''); $out.Add($line)
    $out.Add('  Diagnostics en lecture seule. « Non disponible » = valeur non exposée par Windows, jamais estimée.')
    $out.Add($line)
    [IO.File]::WriteAllLines($Path, $out, (New-Object System.Text.UTF8Encoding($true)))
    $Path
}

#endregion

Export-ModuleMember -Function *
