#requires -Version 5.1
<#
    PC Toolkit — logiciel personnel de maintenance et de diagnostic
    =================================================================
    Point d'entrée : charge l'interface WPF (UI\MainWindow.xaml) et les modules (Modules\*.psm1).

    Architecture
      PCToolkit.ps1        interface : navigation, exécution en arrière-plan, rendu, export, historique
      Modules\Core.psm1    modèle de résultat, progression, historique JSON, export HTML, journal
      Modules\*.psm1       un module par diagnostic, chacun expose Invoke-<Nom>Diagnostic -Ctx
      UI\MainWindow.xaml   mise en page et thème (sombre, accent rouge néon)
      Data\History         historique des diagnostics (JSON)      Data\Logs   journaux
      Reports              rapports HTML exportés

    Les diagnostics tournent dans un runspace séparé : l'interface ne se fige jamais.
    Paramètre de développement : -Snapshot <fichier.png> exécute le tableau de bord, enregistre
    une capture de la fenêtre puis quitte.
#>
param([string]$Snapshot, [string]$SnapshotPage = 'Dashboard')

$ErrorActionPreference = 'Stop'
$AppRoot = $PSScriptRoot
$script:ScriptPath = $PSCommandPath
$ModDir = Join-Path $AppRoot 'Modules'

# Garde-fou : lancé depuis un zip non extrait, les dossiers Modules et UI sont absents
if (-not (Test-Path -LiteralPath (Join-Path $ModDir 'Core.psm1')) -or -not (Test-Path -LiteralPath (Join-Path $AppRoot 'UI\MainWindow.xaml'))) {
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show("Des fichiers de PC Toolkit sont introuvables (dossiers Modules et UI).`n`nSi vous l'ouvrez depuis un fichier .zip : clic droit sur le zip > « Extraire tout… », puis relancez.", 'PC Toolkit', 'OK', 'Warning')
    return
}

# WPF exige un thread STA : relance automatique si nécessaire
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$PSCommandPath`"")
    if ($Snapshot) { $a += @('-Snapshot', "`"$Snapshot`"", '-SnapshotPage', $SnapshotPage) }
    Start-Process powershell.exe -ArgumentList $a -WindowStyle Hidden
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
# Tous les modules sont chargés dans l'interface (Maintenance, historique, export en ont besoin)
# et de nouveau dans chaque runspace de diagnostic.
Get-ChildItem -LiteralPath $ModDir -Filter '*.psm1' | ForEach-Object { Import-Module $_.FullName -Global -Force -DisableNameChecking }

# Barre de titre sombre (API Windows 11, sans effet sur les versions qui ne la gèrent pas)
if (-not ('PCToolkit.Dwm' -as [type])) {
    Add-Type -Namespace PCToolkit -Name Dwm -MemberDefinition @'
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
'@
}

#region Chargement de l'interface --------------------------------------------------------

[xml]$xaml = Get-Content -LiteralPath (Join-Path $AppRoot 'UI\MainWindow.xaml') -Raw -Encoding UTF8
$Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$UI = @{}
foreach ($n in $xaml.SelectNodes('//*[@*[local-name()="Name"]]')) {
    $name = $n.Attributes | Where-Object LocalName -eq 'Name' | Select-Object -ExpandProperty Value
    $UI[$name] = $Window.FindName($name)
}

# Version (fichier VERSION) affichée dans la barre latérale et le titre
$AppVersion = Get-AppVersion
$UI.TxtVersion.Text = "v$AppVersion · lecture seule par défaut"
$Window.Title = "PC Toolkit $AppVersion — Maintenance & Diagnostic"

# Icône (éclair néon) pour la fenêtre et la barre des tâches
try { $Window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri](Join-Path $AppRoot 'app.ico')) } catch { }

$script:BrushConv = New-Object Windows.Media.BrushConverter
function Get-Brush([string]$Hex) { $script:BrushConv.ConvertFromString($Hex) }
$script:StatusColor = @{ OK = '#3DDC84'; Warn = '#FFB020'; Crit = '#FF2A3D'; Info = '#6EA8FE'; NA = '#6B5B5F' }
$script:StatusText = @{ OK = 'OK'; Warn = 'À surveiller'; Crit = 'Problème'; Info = 'Info'; NA = 'N/D' }

#endregion

#region Pages ---------------------------------------------------------------------------

$script:Pages = [ordered]@{
    Dashboard   = @{ Nav = 'NavDashboard';   Title = 'Tableau de bord'; Fn = 'Invoke-DashboardDiagnostic'; Desc = 'Vue rapide de l''état du PC et des points d''attention. Environ 10 secondes, lecture seule.' }
    Hardware    = @{ Nav = 'NavHardware';    Title = 'Matériel';        Fn = 'Invoke-HardwareDiagnostic';  Desc = 'Processeur, mémoire, carte graphique, BIOS et températures (uniquement celles réellement exposées par le matériel).' }
    Network     = @{ Nav = 'NavNetwork';     Title = 'Réseau';          Fn = 'Invoke-NetworkDiagnostic';   Desc = 'Connexion, DNS et DoH, latence, gigue et pertes vers la box et Internet, rapidité DNS.'; Opt = 'OptNetwork' }
    Windows     = @{ Nav = 'NavWindows';     Title = 'Windows';         Fn = 'Invoke-WindowsDiagnostic';   Desc = 'Version et support, stabilité, journaux d''erreurs, services, programmes au démarrage et sécurité.'; Opt = 'OptWindows' }
    Storage     = @{ Nav = 'NavStorage';     Title = 'Stockage';        Fn = 'Invoke-StorageDiagnostic';   Desc = 'Espace libre, santé des disques, dossiers volumineux et recherche de gros fichiers. Rien n''est supprimé.'; Opt = 'OptStorage' }
    Audio       = @{ Nav = 'NavAudio';       Title = 'Audio';           Fn = 'Invoke-AudioDiagnostic';     Desc = 'Votre sortie et votre micro par défaut (carte son, USB, Bluetooth, HDMI…) : connexion, pilote, fréquences d''échantillonnage, ASIO, latence indicative.' }
    Maintenance = @{ Nav = 'NavMaintenance'; Title = 'Maintenance';     Custom = $true;                    Desc = 'Vérifications et nettoyage contrôlé. Chaque action qui modifie le système demande votre confirmation.' }
    Startup     = @{ Nav = 'NavStartup';     Title = 'Démarrage';       Custom = $true;                    Desc = 'Programmes lancés avec Windows. Désactiver n''en supprime aucun : vous pouvez les réactiver à tout moment.' }
    Perf        = @{ Nav = 'NavPerf';        Title = 'Mode Performance'; Custom = $true;                   Desc = 'Plan d''alimentation haute performance et arrêt temporaire de services secondaires pour jouer ou faire de la MAO. Tout se remet en un clic.' }
    Bilan       = @{ Nav = 'NavBilan';       Title = 'Bilan avant/après'; Custom = $true;                  Desc = 'Chaque nettoyage lancé depuis Maintenance, et chaque activation du Mode Performance, est mesuré automatiquement : espace libéré, RAM, services actifs, fichiers temporaires et périphériques audio fantômes.' }
    History     = @{ Nav = 'NavHistory';    Title = 'Historique';      Custom = $true;                    Desc = 'Diagnostics précédents : réouverture, comparaison et export HTML.' }
}
$script:CurrentPage = 'Dashboard'
$script:Results = @{}          # dernier résultat affiché par page
$script:ViewedHistory = $null  # résultat d'historique en cours de consultation
$script:Job = $null

#endregion

#region Exécution en arrière-plan ---------------------------------------------------------

$script:Timer = New-Object Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(150)

function Start-BackgroundJob {
    <#
        Exécute une fonction des modules dans un runspace séparé.
        Le contexte $ctx (hashtable synchronisée) transporte progression, statut et demande d'annulation.
        $OnComplete reçoit (sortie, erreurs) sur le thread de l'interface.
    #>
    param([string]$Function, [hashtable]$Params = @{}, [scriptblock]$OnComplete, [string]$StartText = 'Démarrage…', [switch]$Baseline)
    if ($script:Job) { return }
    $ctx = [hashtable]::Synchronized(@{ Progress = 0; Status = $StartText; Cancel = $false })
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($ModDir, $Fn, $Ctx, $P, $Base)
        Get-ChildItem -LiteralPath $ModDir -Filter '*.psm1' | ForEach-Object { Import-Module $_.FullName -Global -Force -DisableNameChecking }
        # Photo de départ du bilan « avant / après » : silencieuse, avant que le diagnostic ne commence
        if ($Base) { try { Get-SystemSnapshot -Ctx $null } catch { } }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $out = & $Fn -Ctx $Ctx @P
        foreach ($o in @($out)) { if ($o -and $o.PSObject.Properties['DurationSec']) { $o.DurationSec = [math]::Round($sw.Elapsed.TotalSeconds, 1) } }
        $out
    }).AddArgument($ModDir).AddArgument($Function).AddArgument($ctx).AddArgument($Params).AddArgument([bool]$Baseline)
    $script:Job = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke(); Ctx = $ctx; OnComplete = $OnComplete; Function = $Function; Label = $StartText.TrimEnd('…', '.', ' ') }
    Set-Busy $true $StartText
    $script:Timer.Start()
}

$script:Timer.Add_Tick({
    $j = $script:Job
    if (-not $j) { $script:Timer.Stop(); return }
    $UI.Progress.Value = $j.Ctx.Progress
    $UI.TxtStatus.Text = if ($j.Ctx.Cancel) { 'Annulation… (les résultats partiels seront affichés)' } else { '{0} · {1}' -f $j.Label, $j.Ctx.Status }
    if (-not $j.Handle.IsCompleted) { return }

    $script:Timer.Stop()
    $out = $null; $errs = @()
    try { $out = $j.PS.EndInvoke($j.Handle) } catch { $errs += $_.Exception.InnerException.Message; if (-not $errs[-1]) { $errs[-1] = $_.Exception.Message } }
    $errs += @($j.PS.Streams.Error | ForEach-Object { $_.Exception.Message })
    foreach ($e in $errs) { Write-AppLog "[$($j.Function)] $e" 'ERROR' }
    $j.PS.Dispose(); $j.RS.Dispose()
    # Libère tout de suite la mémoire du runspace terminé (sinon .NET la garde jusqu'au prochain passage du ramasse-miettes)
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    $script:Job = $null
    Set-Busy $false
    try { & $j.OnComplete $out $errs }
    catch { Show-Message "Erreur d'affichage : $($_.Exception.Message)" 'Erreur' 'Error' }
})

function Set-Busy([bool]$Busy, [string]$Text = '') {
    $UI.ProgressRow.Visibility = if ($Busy) { 'Visible' } else { 'Collapsed' }
    $UI.BtnCancel.Visibility = if ($Busy) { 'Visible' } else { 'Collapsed' }
    $UI.BtnRun.IsEnabled = -not $Busy
    $UI.BtnExport.IsEnabled = (-not $Busy) -and [bool](Get-CurrentResult)
    $UI.Progress.Value = 0
    $UI.TxtStatus.Text = $Text
    # La navigation reste libre pendant un diagnostic : seul le lancement d'une 2e tâche est bloqué
    foreach ($b in $script:BusyDisable) { $b.IsEnabled = -not $Busy }
}
$script:BusyDisable = New-Object System.Collections.ArrayList   # boutons dynamiques (maintenance)

function Show-Message([string]$Text, [string]$Title = 'PC Toolkit', [string]$Icon = 'Information', [string]$Buttons = 'OK') {
    [Windows.MessageBox]::Show($Window, $Text, $Title, $Buttons, $Icon)
}

#endregion

#region Rendu des résultats ---------------------------------------------------------------

function New-Text([string]$Text, [double]$Size = 13, [string]$Color = '#F2E6E8', [string]$Weight = 'Normal', [switch]$Wrap) {
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $Text; $t.FontSize = $Size; $t.Foreground = Get-Brush $Color; $t.FontWeight = $Weight
    if ($Wrap) { $t.TextWrapping = 'Wrap' }
    $t
}

function New-Card([double]$Bottom = 14) {
    $b = New-Object Windows.Controls.Border
    $b.Background = Get-Brush '#150A0D'; $b.BorderBrush = Get-Brush '#2E1016'; $b.BorderThickness = 1
    $b.CornerRadius = 10; $b.Padding = '18,14,18,16'; $b.Margin = "0,0,0,$Bottom"
    $b
}

function New-Badge([string]$Status) {
    $b = New-Object Windows.Controls.Border
    $b.CornerRadius = 9; $b.Padding = '8,1,8,2'; $b.BorderThickness = 1; $b.HorizontalAlignment = 'Left'; $b.VerticalAlignment = 'Top'
    $c = $script:StatusColor[$Status]
    $b.BorderBrush = Get-Brush $c
    if ($Status -eq 'Crit') { $b.Background = Get-Brush $c; $fg = '#FFFFFF' } else { $b.Background = Get-Brush ($c -replace '#', '#22'); $fg = $c }
    $b.Child = New-Text $script:StatusText[$Status] 10.5 $fg 'SemiBold'
    $b
}

function ConvertTo-DataView($Table) {
    <# Tableau du modèle -> DataView. Les noms de colonnes sont nettoyés (. / [ ] ( ) cassent les liaisons WPF). #>
    $dt = New-Object System.Data.DataTable
    $map = [ordered]@{}
    foreach ($c in @($Table.Columns)) {
        $safe = ([string]$c) -replace '[\.\/\[\]\(\)]', ' '
        while ($dt.Columns.Contains($safe)) { $safe += ' ' }
        [void]$dt.Columns.Add($safe); $map[[string]$c] = $safe
    }
    foreach ($r in @($Table.Rows)) {
        $row = $dt.NewRow()
        foreach ($c in $map.Keys) { $row[$map[$c]] = [string]$r.$c }
        [void]$dt.Rows.Add($row)
    }
    , $dt.DefaultView
}

function Add-ResultHeader($Result) {
    $st = Get-DiagStats $Result
    $wrap = New-Object Windows.Controls.WrapPanel
    $wrap.Margin = '0,0,0,14'
    $info = '{0}  ·  {1} s  ·  mode {2}{3}' -f $Result.Date, $Result.DurationSec, $(if ($Result.IsAdmin) { 'administrateur' } else { 'standard' }), $(if ($Result.Cancelled) { '  ·  interrompu' } else { '' })
    $t = New-Text $info 12 '#9C8A8E'; $t.Margin = '0,2,16,0'; $t.VerticalAlignment = 'Center'
    [void]$wrap.Children.Add($t)
    foreach ($k in 'Crit', 'Warn', 'OK') {
        $b = New-Badge $(if ($st[$k] -eq 0 -and $k -ne 'OK') { 'NA' } else { $k })   # « 0 problème » en gris, pas en rouge
        $b.Child.Text = '{0} {1}' -f $st[$k], $(switch ($k) { 'Crit' { 'problème(s)' } 'Warn' { 'à surveiller' } 'OK' { 'OK' } })
        $b.Margin = '0,0,8,0'
        [void]$wrap.Children.Add($b)
    }
    [void]$UI.ResultsPanel.Children.Add($wrap)
}

function Add-SectionCard($Section) {
    $card = New-Card
    $sp = New-Object Windows.Controls.StackPanel
    $card.Child = $sp
    $h = New-Text ($Section.Title.ToUpper()) 13 '#FF8A95' 'SemiBold'
    $h.FontFamily = 'Bahnschrift SemiBold, Segoe UI Semibold'; $h.Margin = '0,0,0,10'
    [void]$sp.Children.Add($h)

    if ($Section.Layout -eq 'Tiles') {
        # --- Tuiles (tableau de bord) ---
        $wp = New-Object Windows.Controls.WrapPanel
        foreach ($i in @($Section.Items)) {
            $tile = New-Object Windows.Controls.Border
            $tile.Width = 214; $tile.MinHeight = 88; $tile.Margin = '0,0,10,10'; $tile.CornerRadius = 8; $tile.Padding = '14,10'
            $tile.Background = Get-Brush '#1A0C10'; $tile.BorderBrush = Get-Brush $script:StatusColor[[string]$i.Status]; $tile.BorderThickness = '3,0,0,0'
            $tsp = New-Object Windows.Controls.StackPanel
            [void]$tsp.Children.Add((New-Text $i.Label 11.5 '#9C8A8E'))
            $v = New-Text $i.Value 19 '#FFFFFF' 'SemiBold' -Wrap; $v.FontFamily = 'Bahnschrift SemiBold, Segoe UI Semibold'; $v.Margin = '0,3,0,0'
            [void]$tsp.Children.Add($v)
            if ($i.Detail) { $d = New-Text $i.Detail 11 '#7E6C71' -Wrap; $d.Margin = '0,2,0,0'; [void]$tsp.Children.Add($d) }
            $tile.Child = $tsp
            $tile.ToolTip = '{0} : {1}' -f $script:StatusText[[string]$i.Status], $i.Value
            [void]$wp.Children.Add($tile)
        }
        [void]$sp.Children.Add($wp)
    } else {
        # --- Liste : badge | libellé | valeur (+ détail) ---
        foreach ($i in @($Section.Items)) {
            $g = New-Object Windows.Controls.Grid
            $g.Margin = '0,5,0,5'
            foreach ($w in 104, 270, -1) {
                $cd = New-Object Windows.Controls.ColumnDefinition
                $cd.Width = if ($w -lt 0) { New-Object Windows.GridLength(1, 'Star') } else { New-Object Windows.GridLength($w) }
                $g.ColumnDefinitions.Add($cd)
            }
            $badge = New-Badge ([string]$i.Status)
            [Windows.Controls.Grid]::SetColumn($badge, 0); [void]$g.Children.Add($badge)
            $lbl = New-Text $i.Label 13 '#B8A6AB' -Wrap; $lbl.Margin = '0,0,14,0'
            [Windows.Controls.Grid]::SetColumn($lbl, 1); [void]$g.Children.Add($lbl)
            $vsp = New-Object Windows.Controls.StackPanel
            [void]$vsp.Children.Add((New-Text $i.Value 13 '#F2E6E8' -Wrap))
            if ($i.Detail) { $d = New-Text $i.Detail 11.5 '#7E6C71' -Wrap; $d.Margin = '0,2,0,0'; [void]$vsp.Children.Add($d) }
            [Windows.Controls.Grid]::SetColumn($vsp, 2); [void]$g.Children.Add($vsp)
            [void]$sp.Children.Add($g)
        }
    }

    foreach ($t in @($Section.Tables)) {
        if ($t.Title) { $tt = New-Text $t.Title 12 '#9C8A8E' 'SemiBold'; $tt.Margin = '0,14,0,6'; [void]$sp.Children.Add($tt) }
        if (@($t.Rows).Count -eq 0) { $e = New-Text 'Aucune entrée' 12 '#6B5B5F'; [void]$sp.Children.Add($e); continue }
        $dg = New-Object Windows.Controls.DataGrid
        $dg.AutoGenerateColumns = $true
        $dg.ItemsSource = ConvertTo-DataView $t
        $dg.MaxHeight = 340
        $dg.HorizontalScrollBarVisibility = 'Auto'
        # Laisse la molette faire défiler la page quand le tableau est en butée
        $dg.Add_PreviewMouseWheel({ param($s, $e) if (-not $e.Handled) { $sv = $UI.Scroller; if ($s.ActualHeight -lt $s.MaxHeight) { $e.Handled = $true; $sv.ScrollToVerticalOffset($sv.VerticalOffset - $e.Delta / 3) } } })
        [void]$sp.Children.Add($dg)
    }
    foreach ($n in @($Section.Notes)) {
        $nt = New-Text ([char]0x2139 + '  ' + $n) 12 '#8A787D' -Wrap; $nt.FontStyle = 'Italic'; $nt.Margin = '0,10,0,0'
        [void]$sp.Children.Add($nt)
    }
    [void]$UI.ResultsPanel.Children.Add($card)
}

function Show-DiagResult($Result) {
    $UI.ResultsPanel.Children.Clear()
    Add-ResultHeader $Result
    foreach ($s in @($Result.Sections)) { Add-SectionCard $s }
    $UI.Scroller.ScrollToTop()
}

function Show-Placeholder([string]$Text) {
    $UI.ResultsPanel.Children.Clear()
    $c = New-Card
    $sp = New-Object Windows.Controls.StackPanel
    $ic = New-Text ([string][char]0xE9D9) 30 '#FF2A3D'; $ic.FontFamily = 'Segoe Fluent Icons, Segoe MDL2 Assets'; $ic.Margin = '0,4,0,10'
    [void]$sp.Children.Add($ic)
    [void]$sp.Children.Add((New-Text $Text 14 '#C9B8BC' -Wrap))
    [void]$sp.Children.Add((New-Text 'Toutes les analyses sont en lecture seule : rien n''est modifié sur le PC.' 12 '#7E6C71'))
    $c.Child = $sp; $c.Padding = '24,20'
    [void]$UI.ResultsPanel.Children.Add($c)
}

function Get-CurrentResult {
    if ($script:ViewedHistory) { return $script:ViewedHistory }
    $script:Results[$script:CurrentPage]
}

#endregion

#region Navigation -----------------------------------------------------------------------

function Set-Page([string]$Page) {
    $script:CurrentPage = $Page
    $script:ViewedHistory = $null
    $p = $script:Pages[$Page]
    $UI.TxtTitle.Text = $p.Title
    $UI.TxtDesc.Text = $p.Desc
    $UI.BtnBack.Visibility = 'Collapsed'
    foreach ($o in 'OptNetwork', 'OptWindows', 'OptStorage') { $UI[$o].Visibility = if ($p.Opt -eq $o) { 'Visible' } else { 'Collapsed' } }
    $UI.BtnRun.Visibility = if ($p.Custom) { 'Collapsed' } else { 'Visible' }
    $UI.BtnExport.Visibility = if ($Page -in 'Maintenance', 'Startup', 'Perf') { 'Collapsed' } else { 'Visible' }

    switch ($Page) {
        'Maintenance' { Show-MaintenancePage }
        'Startup' { Show-StartupPage }
        'Perf' { Show-PerfPage }
        'Bilan' { Show-BilanPage }
        'History' { Show-HistoryPage }
        default {
            if ($script:Results[$Page]) { Show-DiagResult $script:Results[$Page]; $UI.TxtRun.Text = 'Relancer' }
            else { Show-Placeholder "Aucun diagnostic « $($p.Title) » pour cette session. Cliquez sur « Lancer le diagnostic »."; $UI.TxtRun.Text = 'Lancer le diagnostic' }
        }
    }
    $UI.BtnExport.IsEnabled = [bool](Get-CurrentResult) -or ($Page -eq 'History')
    $UI.BtnRun.IsEnabled = -not $script:Job
}

function Get-PageParams([string]$Page) {
    switch ($Page) {
        'Network' { @{ DurationSec = $(if ($UI.Dur15.IsChecked) { 15 } elseif ($UI.Dur60.IsChecked) { 60 } elseif ($UI.Dur180.IsChecked) { 180 } else { 30 }) } }
        'Windows' { @{ Days = $(if ($UI.Days1.IsChecked) { 1 } elseif ($UI.Days30.IsChecked) { 30 } else { 7 }) } }
        'Storage' { @{ ScanPath = $UI.TxtScanPath.Text; BigFileMB = $(if ($UI.Big100.IsChecked) { 100 } elseif ($UI.Big2000.IsChecked) { 2000 } else { 500 }) } }
        default { @{} }
    }
}

function Invoke-PageDiagnostic {
    $page = $script:CurrentPage
    $p = $script:Pages[$page]
    if ($p.Custom) { return }
    if ($page -eq 'Storage' -and -not (Test-Path -LiteralPath $UI.TxtScanPath.Text)) { Show-Message 'Le dossier à analyser est introuvable.' 'Stockage' 'Warning'; return }
    Start-BackgroundJob -Function $p.Fn -Params (Get-PageParams $page) -StartText "Diagnostic $($p.Title.ToLower()) en cours…" -Baseline -OnComplete {
        param($out, $errs)
        $base = @($out) | Where-Object { $_ -and $_.PSObject.Properties['DiskFreeBytes'] } | Select-Object -First 1
        if ($base) { Set-BilanBaseline $base }
        $res = @($out) | Where-Object { $_ -and $_.PSObject.Properties['Sections'] } | Select-Object -Last 1
        if (-not $res) {
            Show-Message ("Le diagnostic n'a pas pu aboutir.`n`n" + (($errs | Select-Object -First 3) -join "`n")) 'Erreur' 'Error'
            return
        }
        $script:Results[$res.Module] = $res
        try { [void](Save-DiagHistory $res) } catch { Write-AppLog "Historique : $($_.Exception.Message)" 'ERROR' }
        if ($script:CurrentPage -eq $res.Module -and -not $script:ViewedHistory) { Show-DiagResult $res; $UI.TxtRun.Text = 'Relancer' }
        $UI.BtnExport.IsEnabled = $true
        if ($errs) { $UI.TxtStatus.Text = "$(@($errs).Count) avertissement(s) technique(s) : voir Data\Logs" }
    }
}

#endregion

#region Page Maintenance ---------------------------------------------------------------

function Confirm-Action([string]$Text, [string]$Title = 'Confirmation') {
    (Show-Message $Text $Title 'Warning' 'YesNo') -eq 'Yes'
}

function Invoke-MaintenanceTool([string]$Id) {
    try {
        switch ($Id) {
            'temp' {
                Start-BackgroundJob -Function 'Get-TempCleanupPreview' -StartText 'Analyse des fichiers temporaires…' -OnComplete {
                    param($out, $errs)
                    $pv = @($out) | Where-Object { $_ -and $_.PSObject.Properties['Files'] } | Select-Object -Last 1
                    if (-not $pv) { Show-Message 'Analyse impossible.' 'Fichiers temporaires' 'Error'; return }
                    if ($pv.Count -eq 0) { Show-Message 'Aucun fichier temporaire ancien à supprimer.' 'Fichiers temporaires'; return }
                    $msg = "{0:N0} fichier(s) temporaire(s) de plus de 2 jours, soit {1}.`n`nDossiers : {2}`n`nIls seront supprimés définitivement (pas de passage par la corbeille). Les fichiers en cours d'utilisation seront ignorés.`n`nSupprimer ces fichiers ?" -f $pv.Count, (Format-Bytes $pv.Bytes), (@($pv.Roots) -join ', ')
                    if (-not (Confirm-Action $msg 'Nettoyer les fichiers temporaires')) { return }
                    Start-BilanCapture 'fichiers temporaires'
                    Start-BackgroundJob -Function 'Invoke-TempCleanup' -Params @{ Files = [string[]]@($pv.Files); Roots = [string[]]@($pv.Roots); Confirmed = $true } -StartText 'Suppression des fichiers temporaires…' -OnComplete {
                        param($o2, $e2)
                        $res = @($o2) | Where-Object { $_ -and $_.PSObject.Properties['Deleted'] } | Select-Object -Last 1
                        if ($res) { Show-Message ("{0:N0} fichier(s) supprimé(s), {1} libéré(s).`n{2:N0} fichier(s) ignoré(s) (en cours d'utilisation ou protégés)." -f $res.Deleted, (Format-Bytes $res.Freed), $res.Skipped) 'Nettoyage terminé'; Complete-Bilan }
                        else { Show-Message ("Le nettoyage a échoué.`n" + ($e2 -join "`n")) 'Erreur' 'Error' }
                    }
                }
            }
            'recycle' {
                $rb = Get-RecycleBinSize
                if ($rb.Count -eq 0) { Show-Message 'La corbeille est déjà vide.' 'Corbeille'; return }
                if (Confirm-Action ("La corbeille contient {0} élément(s) pour {1}.`n`nLa vider définitivement ? Cette action est irréversible." -f $rb.Count, (Format-Bytes $rb.Bytes)) 'Vider la corbeille') {
                    Start-BilanCapture 'corbeille'
                    [void](Clear-RecycleBinConfirmed -Confirmed)
                    Show-Message ('Corbeille vidée : {0} libérés.' -f (Format-Bytes $rb.Bytes)) 'Corbeille'
                    Complete-Bilan
                }
            }
            'dns' {
                if (Confirm-Action "Vider le cache DNS de Windows ?`n`nSans risque : les adresses seront simplement redemandées au serveur DNS." 'Cache DNS') {
                    Clear-DnsCacheConfirmed -Confirmed
                    Show-Message 'Cache DNS vidé.' 'Cache DNS'
                }
            }
            'dismcheck' {
                if (Confirm-Action "Une console administrateur va s'ouvrir (Windows demandera l'autorisation) et lancer :`n`nDISM /Online /Cleanup-Image /ScanHealth`n`nAnalyse seule, aucune réparation. Durée : 5 à 15 min. Continuer ?" 'DISM — vérification') {
                    Start-ElevatedConsole -Title 'DISM ScanHealth' -Command 'DISM /Online /Cleanup-Image /ScanHealth' -Confirmed
                }
            }
            'sfc' {
                if (Confirm-Action "Une console administrateur va s'ouvrir et lancer :`n`nsfc /scannow`n`nSFC vérifie les fichiers système de Windows et REMPLACE automatiquement ceux qui sont corrompus par des copies d'origine. Aucune donnée personnelle n'est touchée. Durée : 10 à 20 min.`n`nContinuer ?" 'SFC — réparation') {
                    Start-ElevatedConsole -Title 'SFC' -Command 'sfc /scannow' -Confirmed
                }
            }
            'dismrepair' {
                if (Confirm-Action "Une console administrateur va s'ouvrir et lancer :`n`nDISM /Online /Cleanup-Image /RestoreHealth`n`nRépare le magasin de composants Windows en téléchargeant les fichiers sains depuis Windows Update. Durée : 10 à 30 min, connexion internet requise.`n`nContinuer ?" 'DISM — réparation') {
                    Start-ElevatedConsole -Title 'DISM RestoreHealth' -Command 'DISM /Online /Cleanup-Image /RestoreHealth' -Confirmed
                }
            }
            'chkdsk' {
                if (Confirm-Action "Une console administrateur va s'ouvrir et lancer :`n`nchkdsk C: /scan`n`nAnalyse en ligne, sans réparation ni redémarrage. Continuer ?" 'CHKDSK') {
                    Start-ElevatedConsole -Title 'CHKDSK scan' -Command 'chkdsk C: /scan' -Confirmed
                }
            }
            'restore' {
                if (Confirm-Action "Créer un point de restauration système nommé « PC Toolkit » ?`n`nUne console administrateur va s'ouvrir. La protection système doit être activée sur C:. Windows limite à un point par 24 h par défaut." 'Point de restauration') {
                    Start-ElevatedConsole -PowerShell -Title 'Point de restauration' -Command "Checkpoint-Computer -Description 'PC Toolkit' -RestorePointType MODIFY_SETTINGS; Get-ComputerRestorePoint | Select-Object -Last 3 | Format-Table -AutoSize" -Confirmed
                }
            }
            'recent' {
                $script:Pending = @{
                    Title = 'Fichiers récents'; Empty = 'Aucun élément récent à effacer.'
                    Message = { param($pv) "{0} élément(s) récent(s) et {1} liste(s) de raccourcis (Jump Lists).`n`nDossier : {2}`n`nCela vide « Fichiers récents » dans l'Explorateur et les listes du clic droit sur les icônes de la barre des tâches, y compris les éléments que vous y aviez épinglés.`nVos fichiers eux-mêmes ne sont PAS supprimés.`n`nContinuer ?" -f $pv.RecentCount, $pv.JumpCount, $pv.Root }
                }
                Invoke-PreviewThenDelete 'Get-RecentItemsPreview'
            }
            'partialdl' {
                $script:Pending = @{
                    Title = 'Téléchargements inachevés'; Empty = 'Aucun téléchargement inachevé trouvé.'
                    Message = { param($pv) "{0} téléchargement(s) inachevé(s), soit {1}, dans :`n{2}`n`nSi un téléchargement est encore en cours dans votre navigateur, il sera interrompu : terminez-les ou annulez-les avant.`n`nSupprimer définitivement ces fichiers ?" -f $pv.Count, (Format-Bytes $pv.Bytes), $pv.Root }
                }
                Invoke-PreviewThenDelete 'Get-PartialDownloadsPreview'
            }
            'srum' {
                $msg = "Remettre à zéro les compteurs d'utilisation de Windows (base SRUM) ?`n`nCe qui sera réinitialisé :`n • la consommation de données réseau par application (toutes les cartes réseau) ;`n • l'« Historique des applications » du Gestionnaire des tâches ;`n • l'historique d'utilisation de la batterie (PC portables).`n`nComment : une console administrateur s'ouvre (autorisation Windows), arrête quelques secondes le service « Stratégie de diagnostic », déplace la base dans un dossier de sauvegarde (C:\Windows\System32\sru.sauvegarde-…) puis redémarre le service. Rien n'est supprimé définitivement.`n`nVos réglages réseau (DNS, IP) ne sont pas touchés.`n`nContinuer ?"
                if (Confirm-Action $msg 'Compteurs de données réseau') {
                    Start-ElevatedConsole -PowerShell -Title 'Compteurs de données (SRUM)' -Command (Get-SrumResetCommand) -Confirmed
                }
            }
            'datausage' { Start-Process 'ms-settings:datausage' }
            'cleanmgr' { Start-Process cleanmgr.exe }
            'reliab'   { Start-Process perfmon.exe -ArgumentList '/rel' }
            'devmgmt'  { Start-Process devmgmt.msc }
            'eventvwr' { Start-Process eventvwr.msc }
            'wu'       { Start-Process 'ms-settings:windowsupdate' }
            'logs'     { Start-Process explorer.exe -ArgumentList "`"$(Get-AppPath Logs)`"" }
        }
    } catch {
        $m = $_.Exception.Message
        if ($m -match 'annul|cancel') { $m = 'Action annulée (autorisation administrateur refusée).' }
        Write-AppLog "Maintenance [$Id] : $m" 'ERROR'
        Show-Message $m 'Maintenance' 'Warning'
    }
}

function Invoke-PreviewThenDelete([string]$PreviewFn) {
    <#
        Modèle commun « analyser → confirmer → supprimer » (fichiers récents, téléchargements inachevés).
        Le contexte ($script:Pending : titre, message, texte si vide) est lu à la fin de l'analyse.
    #>
    Start-BackgroundJob -Function $PreviewFn -StartText "Analyse : $($script:Pending.Title)…" -OnComplete {
        param($out, $errs)
        $ctx = $script:Pending
        $pv = @($out) | Where-Object { $_ -and $_.PSObject.Properties['Files'] } | Select-Object -Last 1
        if (-not $pv) { Show-Message ("Analyse impossible.`n" + ($errs -join "`n")) $ctx.Title 'Error'; return }
        if (@($pv.Files).Count -eq 0) { Show-Message $ctx.Empty $ctx.Title; return }
        if (-not (Confirm-Action (& $ctx.Message $pv) $ctx.Title)) { return }
        Start-BilanCapture $ctx.Title.ToLower()
        Start-BackgroundJob -Function 'Remove-FilesUnder' -Params @{ Files = [string[]]@($pv.Files); Root = [string]$pv.Root; Label = $ctx.Title; Confirmed = $true } -StartText "Nettoyage : $($ctx.Title)…" -OnComplete {
            param($o2, $e2)
            $res = @($o2) | Where-Object { $_ -and $_.PSObject.Properties['Deleted'] } | Select-Object -Last 1
            if ($res) { Show-Message ("{0:N0} élément(s) supprimé(s) ({1}).`n{2:N0} ignoré(s) (en cours d'utilisation ou protégés)." -f $res.Deleted, (Format-Bytes $res.Freed), $res.Skipped) "$($script:Pending.Title) — terminé"; Complete-Bilan }
            else { Show-Message ("Le nettoyage a échoué.`n" + ($e2 -join "`n")) 'Erreur' 'Error' }
        }
    }
}

function Show-MaintenancePage {
    $UI.ResultsPanel.Children.Clear()
    $script:BusyDisable.Clear()
    $groups = [ordered]@{ Verif = 'Vérifications (lecture seule)'; Clean = 'Nettoyage et réparation (confirmation demandée)'; Privacy = 'Historique et confidentialité (confirmation demandée)'; Open = 'Outils Windows' }
    foreach ($g in $groups.Keys) {
        $h = New-Text ($groups[$g].ToUpper()) 12 '#FF8A95' 'SemiBold'; $h.Margin = '2,4,0,10'; $h.FontFamily = 'Bahnschrift SemiBold, Segoe UI Semibold'
        [void]$UI.ResultsPanel.Children.Add($h)
        $wp = New-Object Windows.Controls.WrapPanel
        $wp.Margin = '0,0,0,10'
        foreach ($t in Get-MaintenanceTools | Where-Object Group -eq $g) {
            $card = New-Card 10
            $card.Width = 330; $card.Margin = '0,0,12,12'
            $sp = New-Object Windows.Controls.StackPanel
            [void]$sp.Children.Add((New-Text $t.Title 14.5 '#FFFFFF' 'SemiBold'))
            $tags = New-Object Windows.Controls.WrapPanel; $tags.Margin = '0,6,0,8'
            $tagList = New-Object System.Collections.ArrayList
            switch ($t.Kind) {
                'ReadOnly' { [void]$tagList.Add(@('Lecture seule', 'OK')) }
                'Modify'   { [void]$tagList.Add(@('Modifie le système', 'Crit')) }
                'Open'     { [void]$tagList.Add(@('Ouvre un outil Windows', 'Info')) }
            }
            if ($t.Admin) { [void]$tagList.Add(@('Admin requis', 'Warn')) }
            foreach ($tg in $tagList) { $b = New-Badge $tg[1]; $b.Child.Text = $tg[0]; $b.Margin = '0,0,6,0'; [void]$tags.Children.Add($b) }
            [void]$sp.Children.Add($tags)
            $d = New-Text $t.Desc 12 '#A8969B' -Wrap; $d.MinHeight = 52
            [void]$sp.Children.Add($d)
            $btn = New-Object Windows.Controls.Button
            $btn.Style = if ($t.Kind -eq 'Modify') { $Window.FindResource('AccentButton') } else { $Window.FindResource('GhostButton') }
            $btn.Content = switch ($t.Id) { { $_ -in 'temp', 'recent', 'partialdl' } { 'Analyser…' } { $_ -in 'recycle', 'dns' } { 'Vider…' } { $t.Kind -eq 'Open' } { 'Ouvrir' } default { 'Lancer…' } }
            $btn.HorizontalAlignment = 'Left'; $btn.Margin = '0,10,0,0'; $btn.Tag = $t.Id
            $btn.IsEnabled = -not $script:Job
            [Windows.Automation.AutomationProperties]::SetAutomationId($btn, "Tool_$($t.Id)")   # accessibilité / tests automatisés
            $btn.Add_Click({ param($s, $e) Invoke-MaintenanceTool ([string]$s.Tag) })
            [void]$script:BusyDisable.Add($btn)
            [void]$sp.Children.Add($btn)
            $card.Child = $sp
            [void]$wp.Children.Add($card)
        }
        [void]$UI.ResultsPanel.Children.Add($wp)
    }
}

#endregion

#region Pages Démarrage et Mode Performance ---------------------------------------------------

$script:StartupMap = @{}   # index de ligne -> entrée de démarrage

function New-ActionButton([string]$Text, [string]$Style, [string]$AutoId, [scriptblock]$OnClick, [bool]$Enabled = $true, [switch]$NoBusyLock) {
    $btn = New-Object Windows.Controls.Button
    $btn.Style = $Window.FindResource($Style)
    $btn.Content = $Text; $btn.Margin = '0,0,10,6'
    $btn.IsEnabled = $Enabled -and -not $script:Job
    [Windows.Automation.AutomationProperties]::SetAutomationId($btn, $AutoId)
    $btn.Add_Click($OnClick)
    if (-not $NoBusyLock -and $Enabled) { [void]$script:BusyDisable.Add($btn) }
    $btn
}

function Switch-StartupEntry($Entry) {
    $enable = -not $Entry.Enabled
    $msg = if ($enable) { "Réactiver « $($Entry.Name) » au démarrage de Windows ?`n`nSource : $($Entry.Source)`n$($Entry.Command)" }
           else { "Désactiver « $($Entry.Name) » au démarrage de Windows ?`n`nSource : $($Entry.Source)`n$($Entry.Command)`n`nRien n'est supprimé : le programme ne se lancera simplement plus tout seul, et vous pourrez le réactiver ici ou dans le Gestionnaire des tâches." }
    if (-not (Confirm-Action $msg $(if ($enable) { 'Réactiver' } else { 'Désactiver' }))) { return }
    try { [void](Set-StartupEntryState -Entry $Entry -Enabled $enable -Confirmed) }
    catch { Show-Message $_.Exception.Message 'Démarrage' 'Warning'; return }
    Show-StartupPage
}

function Invoke-StartupOptimize {
    $plan = Get-StartupCleanupPlan
    if (@($plan.Targets).Count -eq 0) { Show-Message 'Aucun programme superflu actif à désactiver.' 'Démarrage'; return }
    $list = (@($plan.Targets) | ForEach-Object { " • $($_.Name)  ($($_.Category))" }) -join "`n"
    $msg = "Désactiver automatiquement $(@($plan.Targets).Count) programme(s) au démarrage ?`n`n$list`n`nRien n'est supprimé : seul le lancement automatique est coupé. L'état initial est sauvegardé (Data\StartupBackup.json) et « Restaurer la sauvegarde » remet tout.`nPilotes graphiques/audio, sécurité et utilitaires système ne sont jamais touchés."
    if (@($plan.NeedAdmin).Count -gt 0) { $msg += "`n`n$(@($plan.NeedAdmin).Count) autre(s) programme(s) système sont ignorés (administrateur requis)." }
    if (-not (Confirm-Action $msg 'Optimiser le démarrage')) { return }
    Start-BilanCapture 'nettoyage du démarrage' -Force
    $old = $Window.Cursor
    try {
        $Window.Cursor = [Windows.Input.Cursors]::Wait
        $r = Invoke-StartupAutoClean -Confirmed
    } catch {
        Write-AppLog "Démarrage (auto) : $($_.Exception.Message)" 'ERROR'
        Show-Message $_.Exception.Message 'Démarrage' 'Warning'
        return
    } finally { $Window.Cursor = $old }
    $lines = @("{0} programme(s) désactivé(s) : {1}" -f $r.Disabled.Count, $(if ($r.Disabled.Count) { ($r.Disabled | ForEach-Object Name) -join ', ' } else { 'aucun' }))
    if ($r.Skipped.Count) { $lines += "Ignorés (administrateur requis) : " + (($r.Skipped | ForEach-Object Name) -join ', ') }
    if ($r.Failed.Count) { $lines += "Échecs : " + (($r.Failed | ForEach-Object { "$($_.Name) ($($_.Reason))" }) -join '; ') }
    Show-Message (($lines -join "`n") + "`n`nLe bilan avant/après va s'afficher.") 'Démarrage optimisé'
    Complete-Bilan
    if ($script:CurrentPage -eq 'Startup') { Show-StartupPage }
}

function Invoke-StartupRestore {
    $b = Read-StartupBackup
    if (-not $b -or @($b.Items).Count -eq 0) { Show-Message 'Aucune sauvegarde de démarrage à restaurer.' 'Démarrage'; return }
    $list = (@($b.Items) | ForEach-Object { " • $($_.Name)" }) -join "`n"
    if (-not (Confirm-Action "Remettre $(@($b.Items).Count) programme(s) dans leur état initial ?`n`n$list" 'Restaurer le démarrage')) { return }
    try { $r = Restore-StartupBackup -Confirmed }
    catch { Write-AppLog "Démarrage (restauration) : $($_.Exception.Message)" 'ERROR'; Show-Message $_.Exception.Message 'Démarrage' 'Warning'; return }
    $lines = @("{0} programme(s) rétabli(s)." -f $r.Restored.Count)
    if ($r.Remaining.Count) { $lines += "En attente (administrateur requis ou échec) : " + ($r.Remaining -join ', ') }
    Show-Message ($lines -join "`n") 'Démarrage restauré'
    Show-StartupPage
}

function Show-StartupPage {
    $UI.ResultsPanel.Children.Clear()
    $script:BusyDisable.Clear()
    $script:StartupMap = @{}
    $isAdmin = [bool](Test-IsAdmin)
    $entries = @()
    try { $entries = @(Get-StartupItems) } catch { Write-AppLog "Démarrage : $($_.Exception.Message)" 'ERROR' }

    $card = New-Card 12
    $sp = New-Object Windows.Controls.StackPanel
    $on = @($entries | Where-Object Enabled).Count
    $h = New-Text 'PROGRAMMES AU DÉMARRAGE' 12 '#FF8A95' 'SemiBold'; $h.FontFamily = 'Bahnschrift SemiBold, Segoe UI Semibold'
    [void]$sp.Children.Add($h)
    $t = New-Text ("{0} programme(s) : {1} activé(s), {2} désactivé(s). Sources : clés Run (utilisateur et système) et dossiers Démarrage." -f $entries.Count, $on, ($entries.Count - $on)) 12.5 '#C9B8BC' -Wrap
    $t.Margin = '0,6,0,6'; [void]$sp.Children.Add($t)
    if (-not $isAdmin) {
        $w = New-Text 'Les programmes « système » (tous les utilisateurs) ne peuvent être modifiés qu''en administrateur : leur bouton est grisé.' 12 '#FFB020' -Wrap
        $w.Margin = '0,0,0,6'; [void]$sp.Children.Add($w)
    }
    [void]$sp.Children.Add((New-ActionButton 'Actualiser' 'GhostButton' 'Startup_refresh' { param($s, $e) Show-StartupPage }))
    $card.Child = $sp
    [void]$UI.ResultsPanel.Children.Add($card)

    # --- Optimisation automatique ---
    $plan = $null; try { $plan = Get-StartupCleanupPlan -Entries $entries } catch { Write-AppLog "Démarrage (plan) : $($_.Exception.Message)" 'ERROR' }
    $backup = Read-StartupBackup
    $bItems = if ($backup) { @($backup.Items) } else { @() }
    $card = New-Card 12
    $sp = New-Object Windows.Controls.StackPanel
    $h = New-Text 'OPTIMISATION AUTOMATIQUE' 12 '#FF8A95' 'SemiBold'; $h.FontFamily = 'Bahnschrift SemiBold, Segoe UI Semibold'
    [void]$sp.Children.Add($h)
    $nT = if ($plan) { @($plan.Targets).Count } else { 0 }
    $txt = if ($nT -gt 0) { "$nT programme(s) superflu(s) détecté(s) : " + ((@($plan.Targets) | ForEach-Object { $_.Name }) -join ', ') + '.' } else { 'Aucun programme superflu actif détecté.' }
    if ($plan -and @($plan.NeedAdmin).Count -gt 0) { $txt += " $(@($plan.NeedAdmin).Count) autre(s) demande(nt) le mode administrateur." }
    $t = New-Text $txt 12.5 '#C9B8BC' -Wrap; $t.Margin = '0,6,0,4'; [void]$sp.Children.Add($t)
    $nP = if ($plan) { @($plan.Protected).Count } else { 0 }
    $t = New-Text "Jamais touchés : pilotes graphiques et audio, sécurité (Defender, antivirus, anti-triche), utilitaires système ($nP élément(s) protégé(s) ici). Rien n'est supprimé ; l'état initial est sauvegardé pour une restauration en un clic." 11.5 '#9C8A8E' -Wrap
    $t.Margin = '0,0,0,8'; [void]$sp.Children.Add($t)
    $wp = New-Object Windows.Controls.WrapPanel
    [void]$wp.Children.Add((New-ActionButton 'Optimiser automatiquement le démarrage…' 'AccentButton' 'Startup_auto' { param($s, $e) Invoke-StartupOptimize } ($nT -gt 0)))
    [void]$wp.Children.Add((New-ActionButton ("Restaurer la sauvegarde ({0})…" -f $bItems.Count) 'GhostButton' 'Startup_restore' { param($s, $e) Invoke-StartupRestore } ($bItems.Count -gt 0)))
    [void]$sp.Children.Add($wp)
    if ($bItems.Count -gt 0) {
        $h2 = New-Text 'DÉSACTIVÉS AUTOMATIQUEMENT' 11 '#FF8A95' 'SemiBold'; $h2.Margin = '0,8,0,6'; [void]$sp.Children.Add($h2)
        foreach ($bi in $bItems) {
            $line = New-Object Windows.Controls.WrapPanel; $line.Margin = '0,0,0,4'
            $nm = New-Text $bi.Name 12.5 '#FFFFFF' 'SemiBold'; $nm.Margin = '0,0,10,0'; [void]$line.Children.Add($nm)
            $b = New-Badge 'OK'; $b.Child.Text = 'Désactivé automatiquement'; $b.Margin = '0,1,6,0'; [void]$line.Children.Add($b)
            $b = New-Badge 'Info'; $b.Child.Text = [string]$bi.Category; $b.Margin = '0,1,0,0'; [void]$line.Children.Add($b)
            [void]$sp.Children.Add($line)
        }
    }
    $card.Child = $sp
    [void]$UI.ResultsPanel.Children.Add($card)

    $i = 0
    foreach ($en in $entries) {
        $script:StartupMap[$i] = $en
        $row = New-Card 8
        $row.Padding = '14,10,14,10'
        $dock = New-Object Windows.Controls.DockPanel
        $canEdit = ($en.Scope -eq 'User') -or $isAdmin
        $btn = New-ActionButton $(if ($en.Enabled) { 'Désactiver' } else { 'Réactiver' }) $(if ($en.Enabled) { 'AccentButton' } else { 'GhostButton' }) "Startup_$i" {
            param($s, $e) Switch-StartupEntry $script:StartupMap[[int]$s.Tag]
        } $canEdit -NoBusyLock:(-not $canEdit)
        $btn.Tag = $i; $btn.Margin = '12,0,0,0'; $btn.VerticalAlignment = 'Center'
        [Windows.Controls.DockPanel]::SetDock($btn, 'Right')
        [void]$dock.Children.Add($btn)
        $left = New-Object Windows.Controls.StackPanel
        $line = New-Object Windows.Controls.WrapPanel
        $nm = New-Text $en.Name 14 '#FFFFFF' 'SemiBold'; $nm.Margin = '0,0,10,0'
        [void]$line.Children.Add($nm)
        $b = New-Badge $(if ($en.Enabled) { 'OK' } else { 'NA' }); $b.Child.Text = $(if ($en.Enabled) { 'Activé' } else { 'Désactivé' }); $b.Margin = '0,1,6,0'; [void]$line.Children.Add($b)
        $b = New-Badge 'Info'; $b.Child.Text = $en.Source; $b.Margin = '0,1,6,0'; [void]$line.Children.Add($b)
        if ($en.Missing) { $b = New-Badge 'Warn'; $b.Child.Text = 'Fichier introuvable'; $b.Margin = '0,1,6,0'; [void]$line.Children.Add($b) }
        if ($en.Scope -eq 'Machine' -and -not $isAdmin) { $b = New-Badge 'Warn'; $b.Child.Text = 'Admin requis'; $b.Margin = '0,1,6,0'; [void]$line.Children.Add($b) }
        [void]$left.Children.Add($line)
        $p = New-Text $(if ($en.Path) { $en.Path } else { $en.Command }) 11.5 '#A8969B' -Wrap; $p.Margin = '0,4,0,0'
        [void]$left.Children.Add($p)
        [void]$dock.Children.Add($left)
        $row.Child = $dock
        [void]$UI.ResultsPanel.Children.Add($row)
        $i++
    }
    if ($entries.Count -eq 0) { [void]$UI.ResultsPanel.Children.Add((New-Text 'Aucun programme de démarrage trouvé dans ces emplacements.' 13 '#A8969B')) }
}

function Invoke-PerfEnable {
    $st = Get-GameModeStatus
    if ($st.ModeActive) { Show-Message 'Le Mode Performance est déjà actif. Utilisez « Restaurer l''état initial ».' 'Mode Performance'; return }
    if (-not $st.IsAdmin) { Show-Message "Le Mode Performance arrête des services Windows : il demande les droits administrateur.`n`nRelancez PC Toolkit avec le bouton « Relancer en administrateur » en bas de la barre latérale." 'Mode Performance' 'Warning'; return }
    $run = @($st.Services | Where-Object Running)
    $list = if ($run.Count) { ($run | ForEach-Object { " • $($_.Name) : $($_.Why)" }) -join "`n" } else { ' (aucun : ils sont déjà arrêtés)' }
    $msg = "Activer le Mode Performance ?`n`n1. Plan d'alimentation actuel (« $($st.ActivePlan) ») sauvegardé, puis passage en Performances ultimes / élevées.`n2. Arrêt temporaire de $($run.Count) service(s) :`n$list`n`nRien n'est supprimé ni désactivé définitivement : « Restaurer l'état initial » remet le plan et relance les services (l'état est gardé dans Data\GameMode.json, même si vous fermez l'application).`n`nContinuer ?"
    if (-not (Confirm-Action $msg 'Mode Performance')) { return }
    $flush = (Show-Message "Vider aussi le cache de la mémoire RAM ?`n`nLes pages mémoire inactives des programmes ouverts sont libérées (aucun programme n'est fermé). L'effet est temporaire : Windows les recharge au besoin." 'Mode Performance — RAM' 'Question' 'YesNo') -eq 'Yes'
    Start-BilanCapture 'mode performance' -Force
    $old = $Window.Cursor
    try {
        $Window.Cursor = [Windows.Input.Cursors]::Wait
        $r = Enable-GameMode -Confirmed -FlushRam:$flush
    } catch {
        Write-AppLog "Mode Performance : $($_.Exception.Message)" 'ERROR'
        Show-Message $_.Exception.Message 'Mode Performance' 'Warning'
        if ($script:CurrentPage -eq 'Perf') { Show-PerfPage }
        return
    } finally { $Window.Cursor = $old }
    $lines = @("Plan : {0} → {1}" -f $r.PlanBefore, $(if ($r.PlanAfter) { $r.PlanAfter } else { 'inchangé' }))
    if ($r.PlanNote) { $lines += $r.PlanNote }
    $lines += "Services arrêtés ({0}) : {1}" -f $r.Stopped.Count, $(if ($r.Stopped.Count) { $r.Stopped -join ', ' } else { 'aucun' })
    if ($r.Failed.Count) { $lines += "Non arrêtés : " + ($r.Failed -join ', ') }
    if ($r.Ram) { $lines += "RAM : {0} processus allégés ({1} Mo gagnés)" -f $r.Ram.Processes, $(if ($null -ne $r.Ram.FreedMB) { $r.Ram.FreedMB } else { 'mesure indisponible' }) }
    Show-Message (($lines -join "`n") + "`n`nLe bilan avant/après va s'afficher.") 'Mode Performance activé'
    Complete-Bilan
    if ($script:CurrentPage -eq 'Perf') { Show-PerfPage }
}

function Invoke-PerfRestore {
    $st = Get-GameModeStatus
    if (-not $st.ModeActive) { Show-Message 'Le Mode Performance n''est pas actif : rien à restaurer.' 'Mode Performance'; return }
    $n = @($st.State.ServicesStopped).Count
    if (-not (Confirm-Action "Restaurer l'état initial ?`n`n • plan d'alimentation : « $($st.State.PreviousPlanName) »`n • $n service(s) à relancer : $(@($st.State.ServicesStopped) -join ', ')" 'Restaurer')) { return }
    $old = $Window.Cursor
    try {
        $Window.Cursor = [Windows.Input.Cursors]::Wait
        $r = Restore-GameMode -Confirmed
    } catch {
        Write-AppLog "Mode Performance (restauration) : $($_.Exception.Message)" 'ERROR'
        Show-Message $_.Exception.Message 'Mode Performance' 'Warning'
        return
    } finally { $Window.Cursor = $old }
    $lines = @("Plan : {0}" -f $(if ($r.PlanRestored) { "« $($r.PlanRestored) » rétabli" } else { 'inchangé' }))
    if ($r.PlanNote) { $lines += $r.PlanNote }
    $lines += "Services relancés ({0}) : {1}" -f $r.Started.Count, $(if ($r.Started.Count) { $r.Started -join ', ' } else { 'aucun' })
    if ($r.Failed.Count) { $lines += "Non relancés (réessayez) : " + ($r.Failed -join ', ') }
    Show-Message ($lines -join "`n") 'État initial restauré'
    Show-PerfPage
}

function Show-PerfPage {
    $UI.ResultsPanel.Children.Clear()
    $script:BusyDisable.Clear()
    $st = $null
    try { $st = Get-GameModeStatus } catch { Write-AppLog "Mode Performance : $($_.Exception.Message)" 'ERROR' }
    if (-not $st) { [void]$UI.ResultsPanel.Children.Add((New-Text 'État du Mode Performance indisponible.' 13 '#A8969B')); return }

    $card = New-Card 12
    $sp = New-Object Windows.Controls.StackPanel
    $h = New-Text 'ÉTAT' 12 '#FF8A95' 'SemiBold'; $h.FontFamily = 'Bahnschrift SemiBold, Segoe UI Semibold'
    [void]$sp.Children.Add($h)
    $mode = if ($st.ModeActive) { "Mode Performance ACTIF depuis le $($st.State.Date)." } else { 'Mode Performance inactif.' }
    $t = New-Text $mode 14 $(if ($st.ModeActive) { '#3DDC84' } else { '#FFFFFF' }) 'SemiBold'; $t.Margin = '0,6,0,4'; [void]$sp.Children.Add($t)
    $t = New-Text ("Plan d'alimentation actuel : {0}" -f $(if ($st.ActivePlan) { $st.ActivePlan } else { 'Non disponible' })) 12.5 '#C9B8BC'; [void]$sp.Children.Add($t)
    if (-not $st.IsAdmin) {
        $w = New-Text 'Droits administrateur requis pour activer ou restaurer (arrêt et relance de services). Utilisez « Relancer en administrateur » dans la barre latérale.' 12 '#FFB020' -Wrap
        $w.Margin = '0,6,0,0'; [void]$sp.Children.Add($w)
    }
    $wp = New-Object Windows.Controls.WrapPanel; $wp.Margin = '0,10,0,0'
    [void]$wp.Children.Add((New-ActionButton 'Activer le Mode Performance…' 'AccentButton' 'Perf_enable' { param($s, $e) Invoke-PerfEnable } (-not $st.ModeActive)))
    [void]$wp.Children.Add((New-ActionButton 'Restaurer l''état initial…' 'GhostButton' 'Perf_restore' { param($s, $e) Invoke-PerfRestore } $st.ModeActive))
    [void]$sp.Children.Add($wp)
    $card.Child = $sp
    [void]$UI.ResultsPanel.Children.Add($card)

    $card = New-Card 12
    $sp = New-Object Windows.Controls.StackPanel
    $h = New-Text 'SERVICES ARRÊTÉS PAR LE MODE' 12 '#FF8A95' 'SemiBold'; $h.FontFamily = 'Bahnschrift SemiBold, Segoe UI Semibold'; $h.Margin = '0,0,0,8'
    [void]$sp.Children.Add($h)
    foreach ($s in $st.Services) {
        $line = New-Object Windows.Controls.WrapPanel; $line.Margin = '0,0,0,6'
        $n = New-Text $s.Name 13 '#FFFFFF' 'SemiBold'; $n.Width = 130; [void]$line.Children.Add($n)
        $b = New-Badge $(if ($s.Running) { 'Warn' } else { 'NA' }); $b.Child.Text = $(if ($s.Running) { 'En cours' } elseif ($s.Exists) { 'Arrêté' } else { 'Absent' }); $b.Width = 70; $b.Margin = '0,0,10,0'
        [void]$line.Children.Add($b)
        [void]$line.Children.Add((New-Text $s.Why 12 '#A8969B'))
        [void]$sp.Children.Add($line)
    }
    $n = New-Text 'Seuls les services « En cours » sont arrêtés ; le type de démarrage n''est jamais modifié. Au prochain redémarrage de Windows, tout redevient normal de toute façon.' 11.5 '#9C8A8E' -Wrap
    $n.Margin = '0,6,0,0'; [void]$sp.Children.Add($n)
    $card.Child = $sp
    [void]$UI.ResultsPanel.Children.Add($card)
}

#endregion

#region Page Bilan avant/après ----------------------------------------------------------------

# Photos gardées uniquement en mémoire (aucun fichier). La photo « avant » est prise automatiquement
# quand un nettoyage vient d'être confirmé ; la photo « après » et le tableau suivent à la fin.
$script:BilanAvant = $null
$script:BilanOps = New-Object System.Collections.ArrayList   # actions réalisées depuis la mesure de départ

function Get-SnapshotNow {
    $old = $Window.Cursor
    try { $Window.Cursor = [Windows.Input.Cursors]::Wait; Get-SystemSnapshot -Ctx $null }
    catch { Write-AppLog "Bilan : $($_.Exception.Message)" 'ERROR'; $null }
    finally { $Window.Cursor = $old }
}

function Set-BilanBaseline($Snapshot) {
    # Nouvelle mesure de départ (début d'un diagnostic) : le bilan précédent n'a plus de sens
    $script:BilanAvant = $Snapshot
    $script:BilanOps.Clear()
    [void]$script:Results.Remove('Bilan')
}

function Start-BilanCapture([string]$Operation = '', [switch]$Force) {
    <#
        Garantit une mesure de départ. Celle prise au début du diagnostic est conservée (le bilan couvre alors
        toute la procédure) ; sans diagnostic récent (plus de 2 h), on mesure à l'instant du nettoyage.
    #>
    $age = $null
    if ($script:BilanAvant) { try { $age = (Get-Date) - [datetime]::ParseExact($script:BilanAvant.Date, 'yyyy-MM-dd HH:mm:ss', $null) } catch { } }
    if ($Force -or -not $script:BilanAvant -or -not $age -or $age.TotalMinutes -gt 120) {
        $snap = Get-SnapshotNow
        if ($snap) { Set-BilanBaseline $snap }
    }
    if ($Operation -and $script:BilanOps -notcontains $Operation) { [void]$script:BilanOps.Add($Operation) }
}

function Complete-Bilan {
    if (-not $script:BilanAvant) { return }
    $apres = Get-SnapshotNow
    if (-not $apres) { return }
    try {
        $script:Results['Bilan'] = New-BilanResult -Before $script:BilanAvant -After $apres -Operation ($script:BilanOps -join ', ')
        if ($script:CurrentPage -eq 'Bilan') { Show-BilanPage; $UI.BtnExport.IsEnabled = $true }
        else { $UI.NavBilan.IsChecked = $true }
    } catch {
        Write-AppLog "Bilan : $($_.Exception.Message)" 'ERROR'
        Show-Message "Bilan impossible : $($_.Exception.Message)" 'Bilan' 'Error'
    }
}

function Show-BilanPage {
    $UI.ResultsPanel.Children.Clear()
    $script:BusyDisable.Clear()
    $card = New-Card 10
    $sp = New-Object Windows.Controls.StackPanel
    $h = New-Text 'BILAN AUTOMATIQUE' 12 '#FF8A95' 'SemiBold'; $h.FontFamily = 'Bahnschrift SemiBold, Segoe UI Semibold'
    [void]$sp.Children.Add($h)
    $txt = 'Au début de chaque diagnostic, l''état du PC est mesuré en silence (en mémoire, rien n''est enregistré). Quand vous terminez un nettoyage depuis « Maintenance » (fichiers temporaires, corbeille, fichiers récents, téléchargements inachevés), l''état final est mesuré et le tableau « Avant / Après » s''affiche ici ; il est aussi ajouté à la fin des exports HTML et TXT. Pour mesurer autre chose (script de confidentialité, nettoyage audio…), utilisez les deux boutons ci-dessous.'
    $d = New-Text $txt 12.5 '#C9B8BC' -Wrap; $d.Margin = '0,6,0,10'
    [void]$sp.Children.Add($d)
    if ($script:BilanAvant) {
        $st = New-Text ("Mesure de départ prise à {0}. Après vos nettoyages, le bilan s'affiche tout seul (ou cliquez sur « Comparer maintenant »)." -f $script:BilanAvant.Date.Substring(11)) 12.5 '#3DDC84' -Wrap
        $st.Margin = '0,0,0,10'; [void]$sp.Children.Add($st)
    }
    $wp = New-Object Windows.Controls.WrapPanel
    foreach ($b in @(
            @{ Id = 'avant'; Text = 'Prendre la photo avant'; Style = $(if ($script:BilanAvant) { 'GhostButton' } else { 'AccentButton' }) }
            @{ Id = 'apres'; Text = 'Comparer maintenant'; Style = $(if ($script:BilanAvant) { 'AccentButton' } else { 'GhostButton' }) })) {
        $btn = New-Object Windows.Controls.Button
        $btn.Style = $Window.FindResource($b.Style)
        $btn.Content = $b.Text; $btn.Margin = '0,0,10,6'; $btn.Tag = $b.Id
        $btn.IsEnabled = -not $script:Job
        [Windows.Automation.AutomationProperties]::SetAutomationId($btn, "Bilan_$($b.Id)")
        $btn.Add_Click({
            param($s, $e)
            if ([string]$s.Tag -eq 'avant') { Start-BilanCapture 'mesure manuelle' -Force; Show-BilanPage }
            elseif (-not $script:BilanAvant) { Show-Message 'Prenez d''abord la photo « avant ».' 'Bilan' }
            else { Complete-Bilan }
        })
        [void]$script:BusyDisable.Add($btn)
        [void]$wp.Children.Add($btn)
    }
    [void]$sp.Children.Add($wp)
    $card.Child = $sp
    [void]$UI.ResultsPanel.Children.Add($card)

    $res = $script:Results['Bilan']
    if ($res) {
        Add-ResultHeader $res
        foreach ($s in @($res.Sections)) { Add-SectionCard $s }
    }
    $UI.Scroller.ScrollToTop()
}

#endregion

#region Page Historique ------------------------------------------------------------------

function Show-HistoryPage {
    $UI.ResultsPanel.Children.Clear()
    $items = @(Get-DiagHistory)
    $card = New-Card
    $sp = New-Object Windows.Controls.StackPanel
    $card.Child = $sp
    $h = New-Text ('{0} DIAGNOSTIC(S) ENREGISTRÉ(S)' -f $items.Count) 13 '#FF8A95' 'SemiBold'; $h.Margin = '0,0,0,10'; $h.FontFamily = 'Bahnschrift SemiBold, Segoe UI Semibold'
    [void]$sp.Children.Add($h)
    if (-not $items.Count) {
        [void]$sp.Children.Add((New-Text 'Aucun diagnostic enregistré pour le moment. Chaque diagnostic lancé est ajouté ici automatiquement.' 13 '#A8969B' -Wrap))
        [void]$UI.ResultsPanel.Children.Add($card); return
    }
    $dg = New-Object Windows.Controls.DataGrid
    $dg.AutoGenerateColumns = $true
    $dg.SelectionMode = 'Extended'
    $dt = New-Object System.Data.DataTable
    foreach ($c in 'Date', 'Module', 'Problèmes', 'Alertes', 'OK', 'Durée', 'Admin') { [void]$dt.Columns.Add($c) }
    [void]$dt.Columns.Add('Path')
    foreach ($i in $items) { $row = $dt.NewRow(); foreach ($c in 'Date', 'Module', 'Problèmes', 'Alertes', 'OK', 'Durée', 'Admin', 'Path') { $row[$c] = [string]$i.$c }; [void]$dt.Rows.Add($row) }
    $dg.ItemsSource = $dt.DefaultView
    $dg.Add_AutoGeneratingColumn({ param($s, $e) if ($e.PropertyName -eq 'Path') { $e.Cancel = $true } })
    $dg.MaxHeight = 460
    $dg.Add_MouseDoubleClick({ Open-HistoryEntry })
    $script:HistoryGrid = $dg
    [void]$sp.Children.Add($dg)

    $bar = New-Object Windows.Controls.WrapPanel; $bar.Margin = '0,14,0,0'
    $mk = {
        param($text, $style, $action)
        $b = New-Object Windows.Controls.Button
        $b.Content = $text; $b.Style = $Window.FindResource($style); $b.Margin = '0,0,8,0'
        $b.Add_Click($action)
        [void]$bar.Children.Add($b)
    }
    & $mk 'Ouvrir' 'AccentButton' { Open-HistoryEntry }
    & $mk 'Exporter en HTML' 'GhostButton' { Export-SelectedHistory 'Html' }
    & $mk 'Exporter en TXT' 'GhostButton' { Export-SelectedHistory 'Txt' }
    & $mk 'Supprimer la sélection…' 'GhostButton' { Remove-SelectedHistory }
    & $mk 'Ouvrir le dossier des rapports' 'GhostButton' { Start-Process explorer.exe -ArgumentList "`"$(Get-AppPath Reports)`"" }
    [void]$sp.Children.Add($bar)
    [void]$sp.Children.Add((New-Text 'Astuce : double-cliquez sur une ligne pour l''ouvrir. Ctrl+clic pour sélectionner plusieurs diagnostics et les exporter dans un même rapport.' 11.5 '#7E6C71' -Wrap))
    [void]$UI.ResultsPanel.Children.Add($card)
}

function Get-SelectedHistoryPaths {
    if (-not $script:HistoryGrid) { return @() }
    @($script:HistoryGrid.SelectedItems | ForEach-Object { [string]$_.Row['Path'] })
}

function Open-HistoryEntry {
    $p = Get-SelectedHistoryPaths | Select-Object -First 1
    if (-not $p) { Show-Message 'Sélectionnez un diagnostic dans la liste.'; return }
    try {
        $res = Import-DiagHistory $p
        $script:ViewedHistory = $res
        $UI.TxtTitle.Text = "Historique · $($res.Title)"
        $UI.TxtDesc.Text = "Diagnostic enregistré le $($res.Date). Consultation seule."
        $UI.BtnBack.Visibility = 'Visible'
        $UI.BtnExport.IsEnabled = $true
        Show-DiagResult $res
    } catch { Show-Message "Impossible d'ouvrir ce diagnostic : $($_.Exception.Message)" 'Historique' 'Error' }
}

function Export-Report {
    <#
        Exporte en HTML (ouvert dans le navigateur) ou en TXT.
        TXT : ouvert dans le Bloc-notes si la case est cochée, sinon sélectionné dans l'Explorateur.
    #>
    param([ValidateSet('Html', 'Txt')][string]$Format, [object[]]$Results, $Bilan)
    if ($Format -eq 'Html') {
        $file = Export-DiagHtml -Results $Results -Bilan $Bilan
        Start-Process $file
    } else {
        $file = Export-DiagText -Results $Results -Bilan $Bilan
        if ($UI.ChkNotepad.IsChecked) { Start-Process notepad.exe -ArgumentList "`"$file`"" }
        else { Start-Process explorer.exe -ArgumentList "/select,`"$file`"" }
    }
    Write-AppLog "Rapport exporté : $file"
    $file
}

function Export-SelectedHistory([string]$Format = 'Html') {
    $paths = Get-SelectedHistoryPaths
    if (-not $paths) { Show-Message 'Sélectionnez au moins un diagnostic.'; return }
    try {
        $res = @($paths | ForEach-Object { Import-DiagHistory $_ })
        [void](Export-Report $Format $res)
    } catch { Show-Message "Export impossible : $($_.Exception.Message)" 'Export' 'Error' }
}

function Export-CurrentPage([string]$Format) {
    try {
        if ($script:CurrentPage -eq 'History' -and -not $script:ViewedHistory) { Export-SelectedHistory $Format; return }
        $res = Get-CurrentResult
        if (-not $res) { Show-Message 'Lancez d''abord un diagnostic.'; return }
        # Le bilan « avant / après » de la session est ajouté à la fin du rapport (sauf pour un ancien diagnostic de l'historique)
        $bilan = if (-not $script:ViewedHistory) { $script:Results['Bilan'] }
        [void](Export-Report $Format @($res) $bilan)
    } catch { Show-Message "Export impossible : $($_.Exception.Message)" 'Export' 'Error' }
}

function Remove-SelectedHistory {
    $paths = Get-SelectedHistoryPaths
    if (-not $paths) { Show-Message 'Sélectionnez au moins un diagnostic.'; return }
    if (-not (Confirm-Action ("Supprimer définitivement {0} diagnostic(s) de l'historique ?`n(Les rapports HTML déjà exportés ne sont pas touchés.)" -f $paths.Count) 'Historique')) { return }
    foreach ($p in $paths) {
        # Garde-fou : uniquement des fichiers du dossier d'historique
        if ((Split-Path $p -Parent) -eq (Get-AppPath History)) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    }
    Write-AppLog ("Historique : {0} entrée(s) supprimée(s)" -f $paths.Count) 'ACTION'
    Show-HistoryPage
}

#endregion

#region Événements ------------------------------------------------------------------------

foreach ($k in $script:Pages.Keys) {
    $UI[$script:Pages[$k].Nav].Add_Checked({
        param($s, $e)
        $pg = ($script:Pages.GetEnumerator() | Where-Object { $_.Value.Nav -eq $s.Name } | Select-Object -First 1).Key
        if ($pg) {
            try { Set-Page $pg }
            catch { Write-AppLog "Navigation [$pg] : $($_.Exception.Message)" 'ERROR'; Show-Message "Impossible d'afficher la page : $($_.Exception.Message)" 'Erreur' 'Error' }
        }
    })
}

$UI.BtnRun.Add_Click({ Invoke-PageDiagnostic })
$UI.BtnCancel.Add_Click({ if ($script:Job) { $script:Job.Ctx.Cancel = $true; $UI.TxtStatus.Text = 'Annulation… (les résultats partiels seront affichés)' } })
$UI.BtnBack.Add_Click({ Set-Page 'History' })
$UI.BtnExport.Add_Click({ Export-CurrentPage 'Html' })
$UI.BtnExportTxt.Add_Click({ Export-CurrentPage 'Txt' })
$UI.BtnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Dossier dans lequel chercher les gros fichiers'
    $dlg.SelectedPath = $UI.TxtScanPath.Text
    if ($dlg.ShowDialog() -eq 'OK') { $UI.TxtScanPath.Text = $dlg.SelectedPath }
})
$UI.BtnElevate.Add_Click({
    if (-not (Confirm-Action "Relancer PC Toolkit avec les droits administrateur ?`n`nWindows va demander l'autorisation. Les diagnostics restent en lecture seule ; les droits servent uniquement à lire davantage d'informations (SMART, températures disque, Temp Windows)." 'Mode administrateur')) { return }
    try {
        Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$script:ScriptPath`""
        $Window.Close()
    } catch { Show-Message 'Relance annulée.' 'Mode administrateur' }
})

$Window.Add_SourceInitialized({
    try {
        $hwnd = (New-Object Windows.Interop.WindowInteropHelper $Window).Handle
        $on = 1; [void][PCToolkit.Dwm]::DwmSetWindowAttribute($hwnd, 20, [ref]$on, 4)         # mode sombre
        $cap = 0x00090B0F; [void][PCToolkit.Dwm]::DwmSetWindowAttribute($hwnd, 35, [ref]$cap, 4) # couleur de la barre (0x00BBGGRR)
        $brd = 0x003D2AFF; [void][PCToolkit.Dwm]::DwmSetWindowAttribute($hwnd, 34, [ref]$brd, 4) # bordure rouge néon
    } catch { }
})
$Window.Add_Closing({ if ($script:Job) { $script:Job.Ctx.Cancel = $true; try { $script:Job.PS.Stop() } catch { } } })

# Erreurs non gérées de l'interface : journalisées et affichées, sans fermer l'application
$Window.Dispatcher.Add_UnhandledException({
    param($s, $e)
    Write-AppLog "Interface : $($e.Exception.Message)" 'ERROR'
    Show-Message "Une erreur inattendue s'est produite :`n$($e.Exception.Message)`n`nElle a été enregistrée dans Data\Logs." 'Erreur' 'Error'
    $e.Handled = $true
})

#endregion

#region Démarrage ------------------------------------------------------------------------

$isAdmin = Test-IsAdmin
$UI.TxtAdmin.Text = if ($isAdmin) { 'Mode administrateur' } else { 'Mode standard' }
$UI.AdminIcon.Foreground = Get-Brush $(if ($isAdmin) { '#FFB020' } else { '#3DDC84' })
if ($isAdmin) { $UI.BtnElevate.Visibility = 'Collapsed' }
$UI.TxtScanPath.Text = $env:USERPROFILE
try {
    $cpuName = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name -replace '\s*\d+th Gen\s*|\(R\)|\(TM\)|CPU|Intel', '' -replace '\s+', ' '
    $gpuName = (Get-CimInstance Win32_VideoController | Where-Object Name -notmatch 'Parsec|Virtual|Basic' | Select-Object -First 1).Name -replace 'AMD |Radeon ', '' -replace '\s+', ' '
    $UI.TxtMachine.Text = "$env:COMPUTERNAME`n$($cpuName.Trim()) · $($gpuName.Trim())"
} catch { $UI.TxtMachine.Text = $env:COMPUTERNAME }

Write-AppLog "Démarrage (admin=$isAdmin)"
Set-Page 'Dashboard'

if ($Snapshot) {
    # Mode capture (vérification sans interaction) : exécute un module de manière synchrone puis enregistre une image de la fenêtre
    $Window.Add_ContentRendered({
        $UI[$script:Pages[$SnapshotPage].Nav].IsChecked = $true
        if (-not $script:Pages[$SnapshotPage].Custom) {
            $res = & $script:Pages[$SnapshotPage].Fn -Ctx $null
            $script:Results[$SnapshotPage] = $res; Show-DiagResult $res
        }
        $Window.UpdateLayout()
        $Window.Dispatcher.Invoke([action] {}, 'ApplicationIdle')
        $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap([int]$Window.ActualWidth, [int]$Window.ActualHeight, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
        $bmp.Render($Window)
        $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
        $fs = [IO.File]::Create($Snapshot); $enc.Save($fs); $fs.Close()
        $Window.Close()
    })
} else {
    # Tableau de bord automatique au lancement (lecture seule, ~10 s)
    $Window.Add_ContentRendered({ Invoke-PageDiagnostic })
}

[void]$Window.ShowDialog()

#endregion
