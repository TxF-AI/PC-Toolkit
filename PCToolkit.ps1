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
    [void][System.Windows.Forms.MessageBox]::Show("Des fichiers de PC Toolkit sont introuvables (dossiers Modules et UI).`n`nSi vous l'ouvrez depuis un fichier .zip : clic droit sur le zip > « Extraire tout… », puis relancez.`n`n(Some PC Toolkit files cannot be found. If you opened it from a .zip: right-click > Extract all, then launch again.)", 'PC Toolkit', 'OK', 'Warning')
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

# Version (fichier VERSION) affichée dans la barre latérale et le titre (textes posés par Update-UiLanguage)
$AppVersion = Get-AppVersion

# Icône (éclair néon) pour la fenêtre et la barre des tâches
try { $Window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri](Join-Path $AppRoot 'app.ico')) } catch { }

$script:BrushConv = New-Object Windows.Media.BrushConverter
function Get-Brush([string]$Hex) { $script:BrushConv.ConvertFromString($Hex) }
$script:StatusColor = @{ OK = '#3DDC84'; Warn = '#FFB020'; Crit = '#FF2A3D'; Info = '#6EA8FE'; NA = '#6B5B5F' }
$script:StatusText = @{}   # rempli par Update-UiLanguage

#endregion

#region Pages ---------------------------------------------------------------------------

$script:Pages = [ordered]@{
    Dashboard   = @{ Nav = 'NavDashboard';   Fn = 'Invoke-DashboardDiagnostic' }
    Hardware    = @{ Nav = 'NavHardware';    Fn = 'Invoke-HardwareDiagnostic' }
    Network     = @{ Nav = 'NavNetwork';     Fn = 'Invoke-NetworkDiagnostic';  Opt = 'OptNetwork' }
    Windows     = @{ Nav = 'NavWindows';     Fn = 'Invoke-WindowsDiagnostic';  Opt = 'OptWindows' }
    Storage     = @{ Nav = 'NavStorage';     Fn = 'Invoke-StorageDiagnostic';  Opt = 'OptStorage' }
    Audio       = @{ Nav = 'NavAudio';       Fn = 'Invoke-AudioDiagnostic' }
    Maintenance = @{ Nav = 'NavMaintenance'; Custom = $true }
    Startup     = @{ Nav = 'NavStartup';     Custom = $true }
    Perf        = @{ Nav = 'NavPerf';        Custom = $true }
    Security    = @{ Nav = 'NavSecurity';    Custom = $true }
    Bilan       = @{ Nav = 'NavBilan';       Custom = $true }
    History     = @{ Nav = 'NavHistory';     Custom = $true }
}
# Titre (clé Nav.<Page>) et description (clé Page.<Page>.Desc) : posés par Update-UiLanguage dans la langue courante
function Update-PageTexts {
    foreach ($k in @($script:Pages.Keys)) {
        $script:Pages[$k].Title = Get-Text "Nav.$k"
        $script:Pages[$k].Desc = Get-Text "Page.$k.Desc"
    }
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
    param([string]$Function, [hashtable]$Params = @{}, [scriptblock]$OnComplete, [string]$StartText = '', [switch]$Baseline)
    if (-not $StartText) { $StartText = Get-Text 'Msg.Starting' }
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
    $script:Job = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke(); Ctx = $ctx; OnComplete = $OnComplete; Function = $Function; Label = $StartText.TrimEnd('…', '.', ' '); Started = Get-Date }
    Write-AppLog ((Get-Text 'Ui.032') -f $script:Job.Label)
    Set-Busy $true $StartText
    $script:Timer.Start()
}

$script:Timer.Add_Tick({
    $j = $script:Job
    if (-not $j) { $script:Timer.Stop(); return }
    if ($j.Ctx.Progress -ne $script:LastProgress) { $script:LastProgress = $j.Ctx.Progress; Set-SmoothValue $UI.Progress $j.Ctx.Progress 320 }
    $UI.TxtStatus.Text = if ($j.Ctx.Cancel) { Get-Text 'Msg.Cancelling' } else { '{0} · {1}' -f $j.Label, $j.Ctx.Status }
    if (-not $j.Handle.IsCompleted) { return }

    $script:Timer.Stop()
    $out = $null; $errs = @()
    try { $out = $j.PS.EndInvoke($j.Handle) } catch { $errs += $_.Exception.InnerException.Message; if (-not $errs[-1]) { $errs[-1] = $_.Exception.Message } }
    $errs += @($j.PS.Streams.Error | ForEach-Object { $_.Exception.Message })
    foreach ($e in $errs) { Write-AppLog "[$($j.Function)] $e" 'ERROR' }
    Write-AppLog ((Get-Text 'Ui.035') -f $j.Label, ((Get-Date) - $j.Started).TotalSeconds)
    $j.PS.Dispose(); $j.RS.Dispose()
    # Libère tout de suite la mémoire du runspace terminé (sinon .NET la garde jusqu'au prochain passage du ramasse-miettes)
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    $script:Job = $null
    Set-Busy $false
    try { & $j.OnComplete $out $errs }
    catch { Show-Message (Get-Text 'Msg.DisplayError' $_.Exception.Message) (Get-Text 'Ui.Error') 'Error' }
})

function Set-Busy([bool]$Busy, [string]$Text = '') {
    $UI.ProgressRow.Visibility = if ($Busy) { 'Visible' } else { 'Collapsed' }
    $UI.BtnCancel.Visibility = if ($Busy) { 'Visible' } else { 'Collapsed' }
    $UI.BtnRun.IsEnabled = -not $Busy
    $UI.BtnExport.IsEnabled = (-not $Busy) -and [bool](Get-CurrentResult)
    $script:LastProgress = -1
    $UI.Progress.BeginAnimation([Windows.Controls.Primitives.RangeBase]::ValueProperty, $null)   # libère l'animation avant de remettre à zéro
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
        [void]$dt.Columns.Add($safe); $dt.Columns[$safe].Caption = [string]$c; $map[[string]$c] = $safe
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
    $info = (Get-Text 'Ui.047') -f $Result.Date, $Result.DurationSec, $(if ($Result.IsAdmin) { (Get-Text 'Ui.048') } else { (Get-Text 'Ui.049') }), $(if ($Result.Cancelled) { (Get-Text 'Ui.050') } else { '' })
    $t = New-Text $info 12 '#9C8A8E'; $t.Margin = '0,2,16,0'; $t.VerticalAlignment = 'Center'
    [void]$wrap.Children.Add($t)
    foreach ($k in 'Crit', 'Warn', 'OK') {
        $b = New-Badge $(if ($st[$k] -eq 0 -and $k -ne 'OK') { 'NA' } else { $k })   # « 0 problème » en gris, pas en rouge
        $b.Child.Text = '{0} {1}' -f $st[$k], $(switch ($k) { 'Crit' { (Get-Text 'Ui.052') } 'Warn' { (Get-Text 'Ui.053') } 'OK' { 'OK' } })
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
        if (@($t.Rows).Count -eq 0) { $e = New-Text (Get-Text 'Ui.064') 12 '#6B5B5F'; [void]$sp.Children.Add($e); continue }
        $dg = New-Object Windows.Controls.DataGrid
        $dg.AutoGenerateColumns = $true
        $dg.Add_AutoGeneratingColumn({ param($s, $e) try { $e.Column.Header = Get-ColumnLabel $s.ItemsSource.Table.Columns[$e.PropertyName].Caption } catch { } })
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
    [void]$sp.Children.Add((New-Text (Get-Text 'Msg.ReadOnlyNote') 12 '#7E6C71'))
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
    $UI.LiveGauges.Visibility = if ($Page -eq 'Dashboard') { 'Visible' } else { 'Collapsed' }
    if ($Page -eq 'Dashboard') { Update-LiveGauges }

    switch ($Page) {
        'Maintenance' { Show-MaintenancePage }
        'Startup' { Show-StartupPage }
        'Perf' { Show-PerfPage }
        'Security' { Show-SecurityPage }
        'Bilan' { Show-BilanPage }
        'History' { Show-HistoryPage }
        default {
            if ($script:Results[$Page]) { Show-DiagResult $script:Results[$Page]; $UI.TxtRun.Text = Get-Text 'Ui.Rerun' }
            else { Show-Placeholder (Get-Text 'Msg.NoDiag' $p.Title); $UI.TxtRun.Text = Get-Text 'Ui.Run' }
        }
    }
    $UI.BtnExport.IsEnabled = [bool](Get-CurrentResult) -or ($Page -eq 'History')
    $UI.BtnRun.IsEnabled = -not $script:Job
    if (-not $Snapshot) { Start-PageTransition }
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
    if ($page -eq 'Storage' -and -not (Test-Path -LiteralPath $UI.TxtScanPath.Text)) { Show-Message (Get-Text 'Msg.FolderMissing') $p.Title 'Warning'; return }
    Start-BackgroundJob -Function $p.Fn -Params (Get-PageParams $page) -StartText (Get-Text 'Msg.DiagRunning' $p.Title.ToLower()) -Baseline -OnComplete {
        param($out, $errs)
        $base = @($out) | Where-Object { $_ -and $_.PSObject.Properties['DiskFreeBytes'] } | Select-Object -First 1
        if ($base) { Set-BilanBaseline $base }
        $res = @($out) | Where-Object { $_ -and $_.PSObject.Properties['Sections'] } | Select-Object -Last 1
        if (-not $res) {
            Show-Message ((Get-Text 'Msg.DiagFailed') + "`n`n" + (($errs | Select-Object -First 3) -join "`n")) (Get-Text 'Ui.Error') 'Error'
            return
        }
        $script:Results[$res.Module] = $res
        try { [void](Save-DiagHistory $res) } catch { Write-AppLog (Get-Text 'Ui.093' $($_.Exception.Message)) 'ERROR' }
        if ($script:CurrentPage -eq $res.Module -and -not $script:ViewedHistory) { Show-DiagResult $res; $UI.TxtRun.Text = Get-Text 'Ui.Rerun' }
        $UI.BtnExport.IsEnabled = $true
        if ($errs) { $UI.TxtStatus.Text = Get-Text 'Msg.TechWarnings' (@($errs).Count) }
    }
}

#endregion

#region Page Maintenance ---------------------------------------------------------------

function Confirm-Action([string]$Text, [string]$Title = '') {
    if (-not $Title) { $Title = Get-Text 'Ui.Confirmation' }
    (Show-Message $Text $Title 'Warning' 'YesNo') -eq 'Yes'
}

function Invoke-MaintenanceTool([string]$Id) {
    try {
        switch ($Id) {
            'temp' {
                Start-BackgroundJob -Function 'Get-TempCleanupPreview' -StartText (Get-Text 'Ui.097') -OnComplete {
                    param($out, $errs)
                    $pv = @($out) | Where-Object { $_ -and $_.PSObject.Properties['Files'] } | Select-Object -Last 1
                    if (-not $pv) { Show-Message (Get-Text 'Ui.099') (Get-Text 'Ui.100') 'Error'; return }
                    if ($pv.Count -eq 0) { Show-Message (Get-Text 'Ui.102') (Get-Text 'Ui.103'); return }
                    $msg = (Get-Text 'Ui.104') -f $pv.Count, (Format-Bytes $pv.Bytes), (@($pv.Roots) -join ', ')
                    if (-not (Confirm-Action $msg (Get-Text 'Ui.105'))) { return }
                    Start-BilanCapture (Get-Text 'Ui.106')
                    Start-BackgroundJob -Function 'Invoke-TempCleanup' -Params @{ Files = [string[]]@($pv.Files); Roots = [string[]]@($pv.Roots); Confirmed = $true } -StartText (Get-Text 'Ui.107') -OnComplete {
                        param($o2, $e2)
                        $res = @($o2) | Where-Object { $_ -and $_.PSObject.Properties['Deleted'] } | Select-Object -Last 1
                        if ($res) { Show-Message ((Get-Text 'Ui.109') -f $res.Deleted, (Format-Bytes $res.Freed), $res.Skipped) (Get-Text 'Ui.110'); Complete-Bilan }
                        else { Show-Message ((Get-Text 'Ui.111') + ($e2 -join "`n")) (Get-Text 'Ui.112') 'Error' }
                    }
                }
            }
            'recycle' {
                $rb = Get-RecycleBinSize
                if ($rb.Count -eq 0) { Show-Message (Get-Text 'Ui.114') (Get-Text 'Ui.115'); return }
                if (Confirm-Action ((Get-Text 'Ui.116') -f $rb.Count, (Format-Bytes $rb.Bytes)) (Get-Text 'Ui.117')) {
                    Start-BilanCapture (Get-Text 'Ui.118')
                    [void](Clear-RecycleBinConfirmed -Confirmed)
                    Show-Message ((Get-Text 'Ui.119') -f (Format-Bytes $rb.Bytes)) (Get-Text 'Ui.120')
                    Complete-Bilan
                }
            }
            'dns' {
                if (Confirm-Action (Get-Text 'Ui.121') (Get-Text 'Ui.122')) {
                    Clear-DnsCacheConfirmed -Confirmed
                    Show-Message (Get-Text 'Ui.123') (Get-Text 'Ui.124')
                }
            }
            'dismcheck' {
                if (Confirm-Action (Get-Text 'Ui.125') (Get-Text 'Ui.126')) {
                    Start-ElevatedConsole -Title 'DISM ScanHealth' -Command 'DISM /Online /Cleanup-Image /ScanHealth' -Confirmed
                }
            }
            'sfc' {
                if (Confirm-Action (Get-Text 'Ui.129') (Get-Text 'Ui.130')) {
                    Start-ElevatedConsole -Title 'SFC' -Command 'sfc /scannow' -Confirmed
                }
            }
            'dismrepair' {
                if (Confirm-Action (Get-Text 'Ui.132') (Get-Text 'Ui.133')) {
                    Start-ElevatedConsole -Title 'DISM RestoreHealth' -Command 'DISM /Online /Cleanup-Image /RestoreHealth' -Confirmed
                }
            }
            'chkdsk' {
                if (Confirm-Action (Get-Text 'Ui.136') (Get-Text 'Ui.137')) {
                    Start-ElevatedConsole -Title 'CHKDSK scan' -Command 'chkdsk C: /scan' -Confirmed
                }
            }
            'restore' {
                if (Confirm-Action (Get-Text 'Ui.140') (Get-Text 'Ui.141')) {
                    Start-ElevatedConsole -PowerShell -Title (Get-Text 'Ui.142') -Command "Checkpoint-Computer -Description 'PC Toolkit' -RestorePointType MODIFY_SETTINGS; Get-ComputerRestorePoint | Select-Object -Last 3 | Format-Table -AutoSize" -Confirmed
                }
            }
            'recent' {
                $script:Pending = @{
                    Title = (Get-Text 'Ui.144'); Empty = (Get-Text 'Ui.145')
                    Message = { param($pv) (Get-Text 'Ui.146') -f $pv.RecentCount, $pv.JumpCount, $pv.Root }
                }
                Invoke-PreviewThenDelete 'Get-RecentItemsPreview'
            }
            'partialdl' {
                $script:Pending = @{
                    Title = (Get-Text 'Ui.147'); Empty = (Get-Text 'Ui.148')
                    Message = { param($pv) (Get-Text 'Ui.149') -f $pv.Count, (Format-Bytes $pv.Bytes), $pv.Root }
                }
                Invoke-PreviewThenDelete 'Get-PartialDownloadsPreview'
            }
            'srum' {
                $msg = (Get-Text 'Ui.150')
                if (Confirm-Action $msg (Get-Text 'Ui.151')) {
                    Start-ElevatedConsole -PowerShell -Title (Get-Text 'Ui.152') -Command (Get-SrumResetCommand) -Confirmed
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
        if ($m -match 'annul|cancel') { $m = (Get-Text 'Ui.154') }
        Write-AppLog (Get-Text 'Ui.155' $Id $m) 'ERROR'
        Show-Message $m 'Maintenance' 'Warning'
    }
}

function Invoke-PreviewThenDelete([string]$PreviewFn) {
    <#
        Modèle commun « analyser → confirmer → supprimer » (fichiers récents, téléchargements inachevés).
        Le contexte ($script:Pending : titre, message, texte si vide) est lu à la fin de l'analyse.
    #>
    Start-BackgroundJob -Function $PreviewFn -StartText (Get-Text 'Ui.159' $($script:Pending.Title)) -OnComplete {
        param($out, $errs)
        $ctx = $script:Pending
        $pv = @($out) | Where-Object { $_ -and $_.PSObject.Properties['Files'] } | Select-Object -Last 1
        if (-not $pv) { Show-Message ((Get-Text 'Ui.161') + ($errs -join "`n")) $ctx.Title 'Error'; return }
        if (@($pv.Files).Count -eq 0) { Show-Message $ctx.Empty $ctx.Title; return }
        if (-not (Confirm-Action (& $ctx.Message $pv) $ctx.Title)) { return }
        Start-BilanCapture $ctx.Title.ToLower()
        Start-BackgroundJob -Function 'Remove-FilesUnder' -Params @{ Files = [string[]]@($pv.Files); Root = [string]$pv.Root; Label = $ctx.Title; Confirmed = $true } -StartText (Get-Text 'Ui.163' $($ctx.Title)) -OnComplete {
            param($o2, $e2)
            $res = @($o2) | Where-Object { $_ -and $_.PSObject.Properties['Deleted'] } | Select-Object -Last 1
            if ($res) { Show-Message ((Get-Text 'Ui.165') -f $res.Deleted, (Format-Bytes $res.Freed), $res.Skipped) (Get-Text 'Ui.166' $($script:Pending.Title)); Complete-Bilan }
            else { Show-Message ((Get-Text 'Ui.167') + ($e2 -join "`n")) (Get-Text 'Ui.168') 'Error' }
        }
    }
}

function Show-MaintenancePage {
    $UI.ResultsPanel.Children.Clear()
    $script:BusyDisable.Clear()
    $groups = [ordered]@{ Verif = (Get-Text 'Ui.170'); Clean = (Get-Text 'Ui.171'); Privacy = (Get-Text 'Ui.172'); Open = (Get-Text 'Ui.173') }
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
                'ReadOnly' { [void]$tagList.Add(@((Get-Text 'Ui.179'), 'OK')) }
                'Modify'   { [void]$tagList.Add(@((Get-Text 'Ui.180'), 'Crit')) }
                'Open'     { [void]$tagList.Add(@((Get-Text 'Ui.181'), 'Info')) }
            }
            if ($t.Admin) { [void]$tagList.Add(@((Get-Text 'Ui.182'), 'Warn')) }
            foreach ($tg in $tagList) { $b = New-Badge $tg[1]; $b.Child.Text = $tg[0]; $b.Margin = '0,0,6,0'; [void]$tags.Children.Add($b) }
            [void]$sp.Children.Add($tags)
            $d = New-Text $t.Desc 12 '#A8969B' -Wrap; $d.MinHeight = 52
            [void]$sp.Children.Add($d)
            $btn = New-Object Windows.Controls.Button
            $btn.Style = if ($t.Kind -eq 'Modify') { $Window.FindResource('AccentButton') } else { $Window.FindResource('GhostButton') }
            $btn.Content = switch ($t.Id) { { $_ -in 'temp', 'recent', 'partialdl' } { (Get-Text 'Ui.189') } { $_ -in 'recycle', 'dns' } { (Get-Text 'Ui.191') } { $t.Kind -eq 'Open' } { (Get-Text 'Ui.193') } default { (Get-Text 'Ui.194') } }
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
    $msg = if ($enable) { (Get-Text 'Ui.196' $($Entry.Name) $($Entry.Source) $($Entry.Command)) }
           else { (Get-Text 'Ui.197' $($Entry.Name) $($Entry.Source) $($Entry.Command)) }
    if (-not (Confirm-Action $msg $(if ($enable) { (Get-Text 'Ui.198') } else { (Get-Text 'Ui.199') }))) { return }
    try { [void](Set-StartupEntryState -Entry $Entry -Enabled $enable -Confirmed) }
    catch { Show-Message $_.Exception.Message (Get-Text 'Ui.200') 'Warning'; return }
    Show-StartupPage
}

function Invoke-StartupOptimize {
    $plan = Get-StartupCleanupPlan
    if (@($plan.Targets).Count -eq 0) { Show-Message (Get-Text 'Ui.202') (Get-Text 'Ui.203'); return }
    $list = (@($plan.Targets) | ForEach-Object { (Get-Text 'Ui.204' $($_.Name) $($_.Category)) }) -join "`n"
    $msg = (Get-Text 'Ui.205' $(@($plan.Targets).Count) $list)
    if (@($plan.NeedAdmin).Count -gt 0) { $msg += (Get-Text 'Ui.206' $(@($plan.NeedAdmin).Count)) }
    if (-not (Confirm-Action $msg (Get-Text 'Ui.207'))) { return }
    Start-BilanCapture (Get-Text 'Ui.208') -Force
    $old = $Window.Cursor
    try {
        $Window.Cursor = [Windows.Input.Cursors]::Wait
        $r = Invoke-StartupAutoClean -Confirmed
    } catch {
        Write-AppLog (Get-Text 'Ui.209' $($_.Exception.Message)) 'ERROR'
        Show-Message $_.Exception.Message (Get-Text 'Ui.211') 'Warning'
        return
    } finally { $Window.Cursor = $old }
    $lines = @((Get-Text 'Ui.213') -f $r.Disabled.Count, $(if ($r.Disabled.Count) { ($r.Disabled | ForEach-Object Name) -join ', ' } else { (Get-Text 'Ui.214') }))
    if ($r.Skipped.Count) { $lines += (Get-Text 'Ui.215') + (($r.Skipped | ForEach-Object Name) -join ', ') }
    if ($r.Failed.Count) { $lines += (Get-Text 'Ui.216') + (($r.Failed | ForEach-Object { (Get-Text 'Ui.217' $($_.Name) $($_.Reason)) }) -join '; ') }
    Show-Message (($lines -join "`n") + (Get-Text 'Ui.218')) (Get-Text 'Ui.219')
    Complete-Bilan
    if ($script:CurrentPage -eq 'Startup') { Show-StartupPage }
}

function Invoke-StartupRestore {
    $b = Read-StartupBackup
    if (-not $b -or @($b.Items).Count -eq 0) { Show-Message (Get-Text 'Ui.221') (Get-Text 'Ui.222'); return }
    $list = (@($b.Items) | ForEach-Object { (Get-Text 'Ui.223' $($_.Name)) }) -join "`n"
    if (-not (Confirm-Action (Get-Text 'Ui.224' $(@($b.Items).Count) $list) (Get-Text 'Ui.225'))) { return }
    try { $r = Restore-StartupBackup -Confirmed }
    catch { Write-AppLog (Get-Text 'Ui.226' $($_.Exception.Message)) 'ERROR'; Show-Message $_.Exception.Message (Get-Text 'Ui.228') 'Warning'; return }
    $lines = @((Get-Text 'Ui.230') -f $r.Restored.Count)
    if ($r.Remaining.Count) { $lines += (Get-Text 'Ui.231') + ($r.Remaining -join ', ') }
    Show-Message ($lines -join "`n") (Get-Text 'Ui.232')
    Show-StartupPage
}

function Show-StartupPage {
    $UI.ResultsPanel.Children.Clear()
    $script:BusyDisable.Clear()
    $script:StartupMap = @{}
    $isAdmin = [bool](Test-IsAdmin)
    $entries = @()
    try { $entries = @(Get-StartupItems) } catch { Write-AppLog (Get-Text 'Ui.233' $($_.Exception.Message)) 'ERROR' }

    $card = New-Card 12
    $sp = New-Object Windows.Controls.StackPanel
    $on = @($entries | Where-Object Enabled).Count
    $h = New-Text (Get-Text 'Ui.235') 12 '#FF8A95' 'SemiBold'; $h.FontFamily = 'Bahnschrift SemiBold, Segoe UI Semibold'
    [void]$sp.Children.Add($h)
    $t = New-Text ((Get-Text 'Ui.239') -f $entries.Count, $on, ($entries.Count - $on)) 12.5 '#C9B8BC' -Wrap
    $t.Margin = '0,6,0,6'; [void]$sp.Children.Add($t)
    if (-not $isAdmin) {
        $w = New-Text (Get-Text 'Ui.241') 12 '#FFB020' -Wrap
        $w.Margin = '0,0,0,6'; [void]$sp.Children.Add($w)
    }
    [void]$sp.Children.Add((New-ActionButton (Get-Text 'Ui.243') 'GhostButton' 'Startup_refresh' { param($s, $e) Show-StartupPage }))
    $card.Child = $sp
    [void]$UI.ResultsPanel.Children.Add($card)

    # --- Optimisation automatique ---
    $plan = $null; try { $plan = Get-StartupCleanupPlan -Entries $entries } catch { Write-AppLog (Get-Text 'Ui.245' $($_.Exception.Message)) 'ERROR' }
    $backup = Read-StartupBackup
    $bItems = if ($backup) { @($backup.Items) } else { @() }
    $card = New-Card 12
    $sp = New-Object Windows.Controls.StackPanel
    $h = New-Text (Get-Text 'Ui.247') 12 '#FF8A95' 'SemiBold'; $h.FontFamily = 'Bahnschrift SemiBold, Segoe UI Semibold'
    [void]$sp.Children.Add($h)
    $nT = if ($plan) { @($plan.Targets).Count } else { 0 }
    $txt = if ($nT -gt 0) { (Get-Text 'Ui.251' $nT) + ((@($plan.Targets) | ForEach-Object { $_.Name }) -join ', ') + '.' } else { (Get-Text 'Ui.252') }
    if ($plan -and @($plan.NeedAdmin).Count -gt 0) { $txt += (Get-Text 'Ui.253' $(@($plan.NeedAdmin).Count)) }
    $t = New-Text $txt 12.5 '#C9B8BC' -Wrap; $t.Margin = '0,6,0,4'; [void]$sp.Children.Add($t)
    $nP = if ($plan) { @($plan.Protected).Count } else { 0 }
    $t = New-Text (Get-Text 'Ui.255' $nP) 11.5 '#9C8A8E' -Wrap
    $t.Margin = '0,0,0,8'; [void]$sp.Children.Add($t)
    $wp = New-Object Windows.Controls.WrapPanel
    [void]$wp.Children.Add((New-ActionButton (Get-Text 'Ui.256') 'AccentButton' 'Startup_auto' { param($s, $e) Invoke-StartupOptimize } ($nT -gt 0)))
    [void]$wp.Children.Add((New-ActionButton ((Get-Text 'Ui.258') -f $bItems.Count) 'GhostButton' 'Startup_restore' { param($s, $e) Invoke-StartupRestore } ($bItems.Count -gt 0)))
    [void]$sp.Children.Add($wp)
    if ($bItems.Count -gt 0) {
        $h2 = New-Text (Get-Text 'Ui.260') 11 '#FF8A95' 'SemiBold'; $h2.Margin = '0,8,0,6'; [void]$sp.Children.Add($h2)
        foreach ($bi in $bItems) {
            $line = New-Object Windows.Controls.WrapPanel; $line.Margin = '0,0,0,4'
            $nm = New-Text $bi.Name 12.5 '#FFFFFF' 'SemiBold'; $nm.Margin = '0,0,10,0'; [void]$line.Children.Add($nm)
            $b = New-Badge 'OK'; $b.Child.Text = (Get-Text 'Ui.265'); $b.Margin = '0,1,6,0'; [void]$line.Children.Add($b)
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
        $btn = New-ActionButton $(if ($en.Enabled) { (Get-Text 'Ui.267') } else { (Get-Text 'Ui.268') }) $(if ($en.Enabled) { 'AccentButton' } else { 'GhostButton' }) "Startup_$i" {
            param($s, $e) Switch-StartupEntry $script:StartupMap[[int]$s.Tag]
        } $canEdit -NoBusyLock:(-not $canEdit)
        $btn.Tag = $i; $btn.Margin = '12,0,0,0'; $btn.VerticalAlignment = 'Center'
        [Windows.Controls.DockPanel]::SetDock($btn, 'Right')
        [void]$dock.Children.Add($btn)
        $left = New-Object Windows.Controls.StackPanel
        $line = New-Object Windows.Controls.WrapPanel
        $nm = New-Text $en.Name 14 '#FFFFFF' 'SemiBold'; $nm.Margin = '0,0,10,0'
        [void]$line.Children.Add($nm)
        $b = New-Badge $(if ($en.Enabled) { 'OK' } else { 'NA' }); $b.Child.Text = $(if ($en.Enabled) { (Get-Text 'Ui.275') } else { (Get-Text 'Ui.276') }); $b.Margin = '0,1,6,0'; [void]$line.Children.Add($b)
        $b = New-Badge 'Info'; $b.Child.Text = $en.Source; $b.Margin = '0,1,6,0'; [void]$line.Children.Add($b)
        if ($en.Missing) { $b = New-Badge 'Warn'; $b.Child.Text = (Get-Text 'Ui.277'); $b.Margin = '0,1,6,0'; [void]$line.Children.Add($b) }
        if ($en.Scope -eq 'Machine' -and -not $isAdmin) { $b = New-Badge 'Warn'; $b.Child.Text = (Get-Text 'Ui.279'); $b.Margin = '0,1,6,0'; [void]$line.Children.Add($b) }
        [void]$left.Children.Add($line)
        $p = New-Text $(if ($en.Path) { $en.Path } else { $en.Command }) 11.5 '#A8969B' -Wrap; $p.Margin = '0,4,0,0'
        [void]$left.Children.Add($p)
        [void]$dock.Children.Add($left)
        $row.Child = $dock
        [void]$UI.ResultsPanel.Children.Add($row)
        $i++
    }
    if ($entries.Count -eq 0) { [void]$UI.ResultsPanel.Children.Add((New-Text (Get-Text 'Ui.280') 13 '#A8969B')) }
}

function Invoke-PerfEnable {
    $st = Get-GameModeStatus
    if ($st.ModeActive) { Show-Message (Get-Text 'Ui.281') (Get-Text 'Ui.282'); return }
    if (-not $st.IsAdmin) { Show-Message (Get-Text 'Ui.283') (Get-Text 'Ui.284') 'Warning'; return }
    $run = @($st.Services | Where-Object Running)
    $list = if ($run.Count) { ($run | ForEach-Object { (Get-Text 'Ui.286' $($_.Name) $($_.Why)) }) -join "`n" } else { (Get-Text 'Ui.287') }
    $msg = (Get-Text 'Ui.288' $($st.ActivePlan) $($run.Count) $list)
    if (-not (Confirm-Action $msg (Get-Text 'Ui.289'))) { return }
    $flush = (Show-Message (Get-Text 'Ui.290') (Get-Text 'Ui.291') 'Question' 'YesNo') -eq 'Yes'
    Start-BilanCapture (Get-Text 'Ui.294') -Force
    $old = $Window.Cursor
    try {
        $Window.Cursor = [Windows.Input.Cursors]::Wait
        $r = Enable-GameMode -Confirmed -FlushRam:$flush
    } catch {
        Write-AppLog (Get-Text 'Ui.295' $($_.Exception.Message)) 'ERROR'
        Show-Message $_.Exception.Message (Get-Text 'Ui.297') 'Warning'
        if ($script:CurrentPage -eq 'Perf') { Show-PerfPage }
        return
    } finally { $Window.Cursor = $old }
    $lines = @((Get-Text 'Ui.300') -f $r.PlanBefore, $(if ($r.PlanAfter) { $r.PlanAfter } else { (Get-Text 'Ui.301') }))
    if ($r.PlanNote) { $lines += $r.PlanNote }
    $lines += (Get-Text 'Ui.302') -f $r.Stopped.Count, $(if ($r.Stopped.Count) { $r.Stopped -join ', ' } else { (Get-Text 'Ui.303') })
    if ($r.Failed.Count) { $lines += (Get-Text 'Ui.304') + ($r.Failed -join ', ') }
    if ($r.Ram) { $lines += (Get-Text 'Ui.305') -f $r.Ram.Processes, $(if ($null -ne $r.Ram.FreedMB) { $r.Ram.FreedMB } else { (Get-Text 'Ui.306') }) }
    Show-Message (($lines -join "`n") + (Get-Text 'Ui.307')) (Get-Text 'Ui.308')
    Complete-Bilan
    if ($script:CurrentPage -eq 'Perf') { Show-PerfPage }
}

function Invoke-PerfRestore {
    $st = Get-GameModeStatus
    if (-not $st.ModeActive) { Show-Message (Get-Text 'Ui.310') (Get-Text 'Ui.311'); return }
    $n = @($st.State.ServicesStopped).Count
    $planLine = if ($st.State.PreviousPlanGuid) { (Get-Text 'Ui.312' $($st.State.PreviousPlanName)) } else { '' }
    if (-not (Confirm-Action (Get-Text 'Ui.313' $planLine $n $(@($st.State.ServicesStopped) -join ', ')) (Get-Text 'Ui.314'))) { return }
    $old = $Window.Cursor
    try {
        $Window.Cursor = [Windows.Input.Cursors]::Wait
        $r = Restore-GameMode -Confirmed
    } catch {
        Write-AppLog (Get-Text 'Ui.315' $($_.Exception.Message)) 'ERROR'
        Show-Message $_.Exception.Message (Get-Text 'Ui.317') 'Warning'
        return
    } finally { $Window.Cursor = $old }
    $lines = @((Get-Text 'Ui.319') -f $(if ($r.PlanRestored) { (Get-Text 'Ui.320' $($r.PlanRestored)) } else { (Get-Text 'Ui.321') }))
    if ($r.PlanNote) { $lines += $r.PlanNote }
    $lines += (Get-Text 'Ui.322') -f $r.Started.Count, $(if ($r.Started.Count) { $r.Started -join ', ' } else { (Get-Text 'Ui.323') })
    if ($r.Failed.Count) { $lines += (Get-Text 'Ui.324') + ($r.Failed -join ', ') }
    Show-Message ($lines -join "`n") (Get-Text 'Ui.325')
    Show-PerfPage
}

function Show-PerfPage {
    $UI.ResultsPanel.Children.Clear()
    $script:BusyDisable.Clear()
    $st = $null
    try { $st = Get-GameModeStatus } catch { Write-AppLog (Get-Text 'Ui.326' $($_.Exception.Message)) 'ERROR' }
    if (-not $st) { [void]$UI.ResultsPanel.Children.Add((New-Text (Get-Text 'Ui.328') 13 '#A8969B')); return }

    # --- Presets 1-clic ---
    $card = New-Card 12
    $sp = New-Object Windows.Controls.StackPanel
    $h = New-Text (Get-Text 'Ui.329') 12 '#22E5FF' 'SemiBold'; $h.FontFamily = 'Bahnschrift SemiBold, Segoe UI Semibold'
    [void]$sp.Children.Add($h)
    $t = New-Text (Get-Text 'Ui.333') 12 '#C9B8BC' -Wrap
    $t.Margin = '0,6,0,8'; [void]$sp.Children.Add($t)
    $wp = New-Object Windows.Controls.WrapPanel
    foreach ($pr in @(Get-TuningProfiles)) {
        $b = New-ActionButton ((Get-Text 'Ui.335') -f $pr.Name) 'AccentButton' "Preset_$($pr.Id)" { param($s, $e) Invoke-TuningPreset ([string]$s.Tag) } (-not $st.ModeActive)
        $b.Tag = $pr.Id; $b.ToolTip = $pr.Details
        [void]$wp.Children.Add($b)
    }
    [void]$sp.Children.Add($wp)
    foreach ($pr in @(Get-TuningProfiles)) {
        $l = New-Text ("{0} — {1}" -f $pr.Name, $pr.Summary) 11.5 '#9C8A8E' -Wrap; $l.Margin = '0,2,0,0'
        [void]$sp.Children.Add($l)
    }
    if ($st.ModeActive) {
        $w = New-Text (Get-Text 'Ui.337') 12 '#FFB020' -Wrap
        $w.Margin = '0,8,0,0'; [void]$sp.Children.Add($w)
    }
    $card.Child = $sp
    [void]$UI.ResultsPanel.Children.Add($card)

    $card = New-Card 12
    $sp = New-Object Windows.Controls.StackPanel
    $h = New-Text (Get-Text 'Ui.339') 12 '#FF8A95' 'SemiBold'; $h.FontFamily = 'Bahnschrift SemiBold, Segoe UI Semibold'
    [void]$sp.Children.Add($h)
    $mode = if ($st.ModeActive) { (Get-Text 'Ui.343' $(if ($st.State.Profile) { $st.State.Profile } else { 'Mode Performance' }) $($st.State.Date)) } else { (Get-Text 'Ui.344') }
    $t = New-Text $mode 14 $(if ($st.ModeActive) { '#3DDC84' } else { '#FFFFFF' }) 'SemiBold'; $t.Margin = '0,6,0,4'; [void]$sp.Children.Add($t)
    $t = New-Text ((Get-Text 'Ui.348') -f $(if ($st.ActivePlan) { $st.ActivePlan } else { (Get-Text 'Ui.349') })) 12.5 '#C9B8BC'; [void]$sp.Children.Add($t)
    if (-not $st.IsAdmin) {
        $w = New-Text (Get-Text 'Ui.351') 12 '#FFB020' -Wrap
        $w.Margin = '0,6,0,0'; [void]$sp.Children.Add($w)
    }
    $wp = New-Object Windows.Controls.WrapPanel; $wp.Margin = '0,10,0,0'
    [void]$wp.Children.Add((New-ActionButton (Get-Text 'Ui.353') 'AccentButton' 'Perf_enable' { param($s, $e) Invoke-PerfEnable } (-not $st.ModeActive)))
    [void]$wp.Children.Add((New-ActionButton (Get-Text 'Ui.355') 'GhostButton' 'Perf_restore' { param($s, $e) Invoke-PerfRestore } $st.ModeActive))
    [void]$sp.Children.Add($wp)
    $card.Child = $sp
    [void]$UI.ResultsPanel.Children.Add($card)

    $card = New-Card 12
    $sp = New-Object Windows.Controls.StackPanel
    $h = New-Text (Get-Text 'Ui.357') 12 '#FF8A95' 'SemiBold'; $h.FontFamily = 'Bahnschrift SemiBold, Segoe UI Semibold'; $h.Margin = '0,0,0,8'
    [void]$sp.Children.Add($h)
    foreach ($s in $st.Services) {
        $line = New-Object Windows.Controls.WrapPanel; $line.Margin = '0,0,0,6'
        $n = New-Text $s.Name 13 '#FFFFFF' 'SemiBold'; $n.Width = 130; [void]$line.Children.Add($n)
        $b = New-Badge $(if ($s.Running) { 'Warn' } else { 'NA' }); $b.Child.Text = $(if ($s.Running) { (Get-Text 'Ui.363') } elseif ($s.Exists) { (Get-Text 'Ui.364') } else { (Get-Text 'Ui.365') }); $b.Width = 70; $b.Margin = '0,0,10,0'
        [void]$line.Children.Add($b)
        [void]$line.Children.Add((New-Text $s.Why 12 '#A8969B'))
        [void]$sp.Children.Add($line)
    }
    $n = New-Text (Get-Text 'Ui.366') 11.5 '#9C8A8E' -Wrap
    $n.Margin = '0,6,0,0'; [void]$sp.Children.Add($n)
    $card.Child = $sp
    [void]$UI.ResultsPanel.Children.Add($card)
}

#endregion

#region Presets d'optimisation (Jeu / MAO / Bureautique) -----------------------------------------

function Invoke-TuningPreset([string]$Id) {
    $old = $Window.Cursor
    $plan = $null
    try { $Window.Cursor = [Windows.Input.Cursors]::Wait; $plan = Get-TuningPlan -Id $Id }
    catch { Write-AppLog (Get-Text 'Ui.367' $($_.Exception.Message)) 'ERROR'; Show-Message $_.Exception.Message (Get-Text 'Ui.369') 'Warning'; return }
    finally { $Window.Cursor = $old }
    $p = $plan.Profile
    $l = @((Get-Text 'Ui.371' $($p.Name)), '', $p.Details, '')
    if ($p.Power -or $p.Services.Count) {
        if (-not $plan.IsAdmin) { $l += (Get-Text 'Ui.372') }
        elseif ($plan.ModeActive) { $l += (Get-Text 'Ui.373') }
        else {
            if ($p.Power) { $l += (Get-Text 'Ui.374' $($plan.ActivePlan)) }
            $l += (Get-Text 'Ui.375' $(@($plan.ServicesToStop).Count)) + $(if (@($plan.ServicesToStop).Count) { (@($plan.ServicesToStop) | ForEach-Object Name) -join ', ' } else { (Get-Text 'Ui.376') })
        }
    }
    if ($p.FlushRam) { $l += (Get-Text 'Ui.377') }
    if ($p.CleanTemp) { $l += (Get-Text 'Ui.378' $($plan.TempCount) $(if ($null -ne $plan.TempBytes) { Format-Bytes $plan.TempBytes } else { 'taille inconnue' })) }
    if ($p.CleanStartup) { $l += (Get-Text 'Ui.379' $(@($plan.StartupTargets).Count)) }
    $l += ''; $l += (Get-Text 'Ui.380')
    if (-not (Confirm-Action ($l -join "`n") (Get-Text 'Ui.381' $($p.Name)))) { return }

    Start-BilanCapture (Get-Text 'Ui.382' $($p.Name)) -Force
    Start-BackgroundJob -Function 'Invoke-TuningProfile' -Params @{ Id = $Id; Confirmed = $true } -StartText (Get-Text 'Ui.383' $($p.Name)) -OnComplete {
        param($out, $errs)
        $res = @($out) | Where-Object { $_ -and $_.PSObject.Properties['Steps'] } | Select-Object -Last 1
        if (-not $res) { Show-Message ((Get-Text 'Ui.385') + (($errs | Select-Object -First 3) -join "`n")) (Get-Text 'Ui.386') 'Error'; return }
        $lines = foreach ($s in $res.Steps) { "{0} {1} : {2}" -f $(switch ($s.Status) { 'OK' { '✔' } 'Ignoré' { '–' } default { '✖' } }), $s.Step, $s.Detail }
        Show-Message (($lines -join "`n") + (Get-Text 'Ui.388')) (Get-Text 'Ui.389' $($res.Profile.Name))
        Complete-Bilan
        if ($script:CurrentPage -eq 'Perf') { Show-PerfPage }
    }
}

#endregion

#region Page Security Guard ---------------------------------------------------------------------

$script:Sec = @{ Audit = $null; Persist = $null; FileScan = $null }
$script:SecMap = @{}

function Update-SecurityResult {
    <# Reconstruit le résultat exportable (HTML/TXT) à partir de ce qui est affiché. #>
    try {
        $fs = $null
        if ($script:Sec.FileScan) { $fs = @{ Summary = $script:Sec.FileScan.Summary; Findings = @($script:Sec.FileScan.Findings) } }
        $script:Results['Security'] = New-SecurityResult -Audit $script:Sec.Audit -Persistence $script:Sec.Persist -FileScan $fs
        if ($script:CurrentPage -eq 'Security') { $UI.BtnExport.IsEnabled = $true }
    } catch { Write-AppLog (Get-Text 'Ui.393' $($_.Exception.Message)) 'ERROR' }
}

function Invoke-SecurityFullScan {
    Start-BackgroundJob -Function 'Invoke-SecurityAudit' -StartText (Get-Text 'Ui.395') -Baseline -OnComplete {
        param($out, $errs)
        $base = @($out) | Where-Object { $_ -and $_.PSObject.Properties['DiskFreeBytes'] } | Select-Object -First 1
        if ($base) { Set-BilanBaseline $base }
        $script:Sec.Audit = @(@($out) | Where-Object { $_ -and $_.PSObject.Properties['Label'] })
        Start-BackgroundJob -Function 'Invoke-StartupThreatScan' -StartText (Get-Text 'Ui.398') -OnComplete {
            param($out2, $errs2)
            $script:Sec.Persist = @(@($out2) | Where-Object { $_ -and $_.PSObject.Properties['Level'] -and $_.PSObject.Properties['Kind'] })
            Update-SecurityResult
            if ($script:CurrentPage -eq 'Security') { Show-SecurityPage }
        }
    }
}

function Invoke-SecurityFileScan([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { Show-Message (Get-Text 'Ui.402') (Get-Text 'Ui.403') 'Warning'; return }
    Start-BackgroundJob -Function 'Invoke-FileHeuristicScan' -Params @{ Path = $Path } -StartText (Get-Text 'Ui.405') -Baseline -OnComplete {
        param($out, $errs)
        $base = @($out) | Where-Object { $_ -and $_.PSObject.Properties['DiskFreeBytes'] } | Select-Object -First 1
        if ($base) { Set-BilanBaseline $base }
        $sum = @($out) | Where-Object { $_ -and $_.PSObject.Properties['ScanSummary'] } | Select-Object -Last 1
        if (-not $sum) { Show-Message ((Get-Text 'Ui.408') + (($errs | Select-Object -First 3) -join "`n")) (Get-Text 'Ui.409') 'Error'; return }
        $script:Sec.FileScan = @{ Summary = $sum; Findings = @(@($out) | Where-Object { $_ -and $_.PSObject.Properties['Level'] -and $_.PSObject.Properties['Kind'] }) }
        Update-SecurityResult
        if ($script:CurrentPage -eq 'Security') { Show-SecurityPage }
    }
}

function Remove-SecurityFinding($F) {
    $keep = { param($list) @($list | Where-Object { -not ($_.Kind -eq $F.Kind -and $_.Name -eq $F.Name -and $_.Path -eq $F.Path) }) }
    if ($script:Sec.Persist) { $script:Sec.Persist = & $keep $script:Sec.Persist }
    if ($script:Sec.FileScan) { $script:Sec.FileScan.Findings = & $keep $script:Sec.FileScan.Findings }
}

function Invoke-SecurityNeutralize($F) {
    $what = switch ($F.Kind) {
        'Fichier' { (Get-Text 'Ui.414' $($F.Path)) }
        'Tâche planifiée' { (Get-Text 'Ui.415' $($F.Name) $($F.Command)) }
        default { (Get-Text 'Ui.416' $($F.Name) $($F.Command)) }
    }
    if (-not (Confirm-Action ($what + (Get-Text 'Ui.417' $($F.Reasons))) (Get-Text 'Ui.418'))) { return }
    Start-BilanCapture (Get-Text 'Ui.419')
    try {
        switch ($F.Kind) {
            'Fichier' { [void](Move-FileToQuarantine -Path $F.Path -Reason $F.Reasons -Confirmed) }
            'Tâche planifiée' { [void](Disable-SuspiciousTask -TaskName $F.Target.TaskName -TaskPath $F.Target.TaskPath -Reason $F.Reasons -Confirmed) }
            default { [void](Disable-SuspiciousStartup -Entry $F.Target -Reason $F.Reasons -Confirmed) }
        }
    } catch {
        Write-AppLog (Get-Text 'Ui.420' $($_.Exception.Message)) 'ERROR'
        Show-Message $_.Exception.Message (Get-Text 'Ui.422') 'Warning'
        return
    }
    Remove-SecurityFinding $F
    Complete-Bilan -NoNavigate
    Update-SecurityResult
    Show-SecurityPage
}

function Invoke-SecurityRestore([string]$Id) {
    $it = @(Get-QuarantineItems) | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $it) { return }
    if (-not (Confirm-Action (Get-Text 'Ui.424' $($it.Name) $($it.OriginalPath)) (Get-Text 'Ui.425'))) { return }
    try { [void](Restore-FromQuarantine -Id $Id -Confirmed) }
    catch { Write-AppLog (Get-Text 'Ui.426' $($_.Exception.Message)) 'ERROR'; Show-Message $_.Exception.Message (Get-Text 'Ui.428') 'Warning'; return }
    if ($script:BilanAvant) { Complete-Bilan -NoNavigate }
    Update-SecurityResult
    Show-SecurityPage
}

function New-SecurityFindingRow($F, [string]$Key) {
    $script:SecMap[$Key] = $F
    $row = New-Card 8
    $row.Padding = '14,10,14,10'
    $dock = New-Object Windows.Controls.DockPanel
    $label = switch ($F.Kind) { 'Fichier' { (Get-Text 'Ui.430') } 'Tâche planifiée' { (Get-Text 'Ui.431') } default { (Get-Text 'Ui.432') } }
    $btn = New-ActionButton $label 'AccentButton' "Sec_$Key" { param($s, $e) Invoke-SecurityNeutralize $script:SecMap[[string]$s.Tag] }
    $btn.Tag = $Key; $btn.Margin = '12,0,0,0'; $btn.VerticalAlignment = 'Center'
    [Windows.Controls.DockPanel]::SetDock($btn, 'Right')
    [void]$dock.Children.Add($btn)
    $left = New-Object Windows.Controls.StackPanel
    $line = New-Object Windows.Controls.WrapPanel
    $nm = New-Text $F.Name 14 '#FFFFFF' 'SemiBold'; $nm.Margin = '0,0,10,0'; [void]$line.Children.Add($nm)
    $b = New-Badge $F.Level; $b.Child.Text = $(if ($F.Level -eq 'Crit') { (Get-Text 'Ui.438') } else { (Get-Text 'Ui.439') }); $b.Margin = '0,1,6,0'; [void]$line.Children.Add($b)
    $b = New-Badge 'Info'; $b.Child.Text = (Get-SecurityKindLabel $F.Kind); $b.Margin = '0,1,6,0'; [void]$line.Children.Add($b)
    $b = New-Badge $(switch ($F.Signature) { 'Signed' { 'OK' } 'NotSigned' { 'Warn' } 'Invalid' { 'Crit' } default { 'NA' } })
    $b.Child.Text = $(switch ($F.Signature) { 'Signed' { (Get-Text 'Ui.440') } 'NotSigned' { (Get-Text 'Ui.441') } 'Invalid' { (Get-Text 'Ui.442') } 'NA' { (Get-Text 'Ui.443') } default { (Get-Text 'Ui.444') } })
    $b.Margin = '0,1,6,0'; [void]$line.Children.Add($b)
    [void]$left.Children.Add($line)
    $r = New-Text $F.Reasons 12 '#FFB020' -Wrap; $r.Margin = '0,4,0,0'; [void]$left.Children.Add($r)
    $pt = New-Text $(if ($F.Path) { $F.Path } else { $F.Command }) 11.5 '#A8969B' -Wrap; $pt.Margin = '0,2,0,0'; [void]$left.Children.Add($pt)
    [void]$dock.Children.Add($left)
    $row.Child = $dock
    $row
}

function Add-FindingsCard([string]$Title, $Findings, [string]$KeyPrefix, [string]$Intro) {
    $card = New-Card 12
    $sp = New-Object Windows.Controls.StackPanel
    $h = New-Text $Title 12 '#22E5FF' 'SemiBold'; $h.FontFamily = 'Bahnschrift SemiBold, Segoe UI Semibold'
    [void]$sp.Children.Add($h)
    $bad = @($Findings | Where-Object { $_.Level -ne 'OK' } | Sort-Object -Property @{ Expression = (Get-Text 'Ui.449'); Descending = $true })
    $t = New-Text ((Get-Text 'Ui.450') -f @($Findings).Count, $bad.Count, $Intro) 12.5 $(if ($bad.Count) { '#FFB020' } else { '#3DDC84' }) -Wrap
    $t.Margin = '0,6,0,4'; [void]$sp.Children.Add($t)
    $card.Child = $sp
    [void]$UI.ResultsPanel.Children.Add($card)
    $i = 0
    foreach ($f in ($bad | Select-Object -First 50)) { [void]$UI.ResultsPanel.Children.Add((New-SecurityFindingRow $f "$KeyPrefix$i")); $i++ }
    if ($bad.Count -gt 50) { [void]$UI.ResultsPanel.Children.Add((New-Text (Get-Text 'Ui.453' $($bad.Count - 50)) 12 '#A8969B')) }
}

function Show-SecurityPage {
    $UI.ResultsPanel.Children.Clear()
    $script:BusyDisable.Clear()
    $script:SecMap = @{}

    $card = New-Card 12
    $sp = New-Object Windows.Controls.StackPanel
    $h = New-Text 'SECURITY GUARD' 12 '#22E5FF' 'SemiBold'; $h.FontFamily = 'Bahnschrift SemiBold, Segoe UI Semibold'
    [void]$sp.Children.Add($h)
    $t = New-Text (Get-Text 'Ui.458') 12.5 '#C9B8BC' -Wrap
    $t.Margin = '0,6,0,8'; [void]$sp.Children.Add($t)
    if (-not (Test-IsAdmin)) {
        $w = New-Text (Get-Text 'Ui.460') 12 '#FFB020' -Wrap
        $w.Margin = '0,0,0,8'; [void]$sp.Children.Add($w)
    }
    $wp = New-Object Windows.Controls.WrapPanel
    [void]$wp.Children.Add((New-ActionButton (Get-Text 'Ui.462') 'AccentButton' 'Sec_audit' { param($s, $e) Invoke-SecurityFullScan }))
    [void]$wp.Children.Add((New-ActionButton (Get-Text 'Ui.464') 'GhostButton' 'Sec_folder' {
        param($s, $e)
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = (Get-Text 'Ui.466')
        $dlg.SelectedPath = $env:USERPROFILE
        if ($dlg.ShowDialog() -eq 'OK') { Invoke-SecurityFileScan $dlg.SelectedPath }
    }))
    [void]$wp.Children.Add((New-ActionButton (Get-Text 'Ui.467') 'GhostButton' 'Sec_file' {
        param($s, $e)
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = (Get-Text 'Ui.469')
        if ($dlg.ShowDialog() -eq 'OK') { Invoke-SecurityFileScan $dlg.FileName }
    }))
    if ($script:Results['Bilan']) { [void]$wp.Children.Add((New-ActionButton (Get-Text 'Ui.471') 'GhostButton' 'Sec_bilan' { param($s, $e) $UI.NavBilan.IsChecked = $true } -NoBusyLock)) }
    [void]$sp.Children.Add($wp)
    $card.Child = $sp
    [void]$UI.ResultsPanel.Children.Add($card)

    # Audit : rendu standard du résultat (même présentation que les diagnostics)
    $res = $script:Results['Security']
    if ($res) {
        $aud = @($res.Sections) | Where-Object { $_.Title -eq (Get-Text 'Sec.130') -or $_.Title -eq 'Audit système' } | Select-Object -First 1
        if ($aud) { Add-SectionCard $aud }
    }
    if ($null -ne $script:Sec.Persist) {
        Add-FindingsCard (Get-Text 'Ui.475') $script:Sec.Persist 'p' (Get-Text 'Ui.476')
    }
    if ($script:Sec.FileScan) {
        $sum = $script:Sec.FileScan.Summary
        Add-FindingsCard ((Get-Text 'Ui.477') + $sum.Path) $script:Sec.FileScan.Findings 'f' ((Get-Text 'Ui.478') -f $sum.Scanned, $sum.Hashed, $(if ($sum.Truncated) { (Get-Text 'Ui.479') } elseif ($sum.Cancelled) { (Get-Text 'Ui.480') } else { '' }))
    }

    # Quarantaine
    $q = @(Get-QuarantineItems)
    $card = New-Card 12
    $sp = New-Object Windows.Controls.StackPanel
    $h = New-Text (Get-Text 'Ui.481') 12 '#22E5FF' 'SemiBold'; $h.FontFamily = 'Bahnschrift SemiBold, Segoe UI Semibold'
    [void]$sp.Children.Add($h)
    $t = New-Text $(if ($q.Count) { (Get-Text 'Ui.485' $($q.Count)) } else { (Get-Text 'Ui.486') }) 12.5 '#C9B8BC' -Wrap
    $t.Margin = '0,6,0,6'; [void]$sp.Children.Add($t)
    $i = 0
    foreach ($it in $q) {
        $dock = New-Object Windows.Controls.DockPanel; $dock.Margin = '0,0,0,6'
        $btn = New-ActionButton (Get-Text 'Ui.488') 'GhostButton' "Sec_restore$i" { param($s, $e) Invoke-SecurityRestore ([string]$s.Tag) }
        $btn.Tag = [string]$it.Id; $btn.Margin = '12,0,0,0'
        [Windows.Controls.DockPanel]::SetDock($btn, 'Right')
        [void]$dock.Children.Add($btn)
        $left = New-Object Windows.Controls.StackPanel
        $nm = New-Text ("{0}  ·  {1}  ·  {2}" -f $it.Name, (Get-SecurityKindLabel $it.Kind), $it.Date) 13 '#FFFFFF' 'SemiBold'; [void]$left.Children.Add($nm)
        $pt = New-Text ([string]$it.OriginalPath) 11.5 '#A8969B' -Wrap; [void]$left.Children.Add($pt)
        [void]$dock.Children.Add($left)
        [void]$sp.Children.Add($dock)
        $i++
    }
    $card.Child = $sp
    [void]$UI.ResultsPanel.Children.Add($card)
    $UI.Scroller.ScrollToTop()
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
    catch { Write-AppLog (Get-Text 'Ui.493' $($_.Exception.Message)) 'ERROR'; $null }
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
    # -NoNavigate : met le bilan à jour sans quitter la page en cours (neutralisations de Security Guard)
    param([switch]$NoNavigate)
    if (-not $script:BilanAvant) { return }
    $apres = Get-SnapshotNow
    if (-not $apres) { return }
    try {
        $script:Results['Bilan'] = New-BilanResult -Before $script:BilanAvant -After $apres -Operation ($script:BilanOps -join ', ')
        if ($script:CurrentPage -eq 'Bilan') { Show-BilanPage; $UI.BtnExport.IsEnabled = $true }
        elseif (-not $NoNavigate) { $UI.NavBilan.IsChecked = $true }
    } catch {
        Write-AppLog (Get-Text 'Ui.499' $($_.Exception.Message)) 'ERROR'
        Show-Message (Get-Text 'Ui.501' $($_.Exception.Message)) (Get-Text 'Ui.502') 'Error'
    }
}

function Show-BilanPage {
    $UI.ResultsPanel.Children.Clear()
    $script:BusyDisable.Clear()
    $card = New-Card 10
    $sp = New-Object Windows.Controls.StackPanel
    $h = New-Text (Get-Text 'Ui.504') 12 '#FF8A95' 'SemiBold'; $h.FontFamily = 'Bahnschrift SemiBold, Segoe UI Semibold'
    [void]$sp.Children.Add($h)
    $txt = (Get-Text 'Ui.508')
    $d = New-Text $txt 12.5 '#C9B8BC' -Wrap; $d.Margin = '0,6,0,10'
    [void]$sp.Children.Add($d)
    if ($script:BilanAvant) {
        $st = New-Text ((Get-Text 'Ui.510') -f $script:BilanAvant.Date.Substring(11)) 12.5 '#3DDC84' -Wrap
        $st.Margin = '0,0,0,10'; [void]$sp.Children.Add($st)
    }
    $wp = New-Object Windows.Controls.WrapPanel
    foreach ($b in @(
            @{ Id = 'avant'; Text = (Get-Text 'Ui.513'); Style = $(if ($script:BilanAvant) { 'GhostButton' } else { 'AccentButton' }) }
            @{ Id = 'apres'; Text = (Get-Text 'Ui.517'); Style = $(if ($script:BilanAvant) { 'AccentButton' } else { 'GhostButton' }) })) {
        $btn = New-Object Windows.Controls.Button
        $btn.Style = $Window.FindResource($b.Style)
        $btn.Content = $b.Text; $btn.Margin = '0,0,10,6'; $btn.Tag = $b.Id
        $btn.IsEnabled = -not $script:Job
        [Windows.Automation.AutomationProperties]::SetAutomationId($btn, "Bilan_$($b.Id)")
        $btn.Add_Click({
            param($s, $e)
            if ([string]$s.Tag -eq 'avant') { Start-BilanCapture (Get-Text 'Ui.521') -Force; Show-BilanPage }
            elseif (-not $script:BilanAvant) { Show-Message (Get-Text 'Ui.522') (Get-Text 'Ui.523') }
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
    $h = New-Text ((Get-Text 'Ui.525') -f $items.Count) 13 '#FF8A95' 'SemiBold'; $h.Margin = '0,0,0,10'; $h.FontFamily = 'Bahnschrift SemiBold, Segoe UI Semibold'
    [void]$sp.Children.Add($h)
    if (-not $items.Count) {
        [void]$sp.Children.Add((New-Text (Get-Text 'Ui.529') 13 '#A8969B' -Wrap))
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
    $dg.Add_AutoGeneratingColumn({ param($s, $e) if ($e.PropertyName -eq 'Path') { $e.Cancel = $true } else { $e.Column.Header = Get-ColumnLabel $e.PropertyName } })
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
    & $mk (Get-Text 'Ui.546') 'AccentButton' { Open-HistoryEntry }
    & $mk (Get-Text 'Ui.548') 'GhostButton' { Export-SelectedHistory 'Html' }
    & $mk (Get-Text 'Ui.551') 'GhostButton' { Export-SelectedHistory 'Txt' }
    & $mk (Get-Text 'Ui.553') 'GhostButton' { Remove-SelectedHistory }
    & $mk (Get-Text 'Ui.555') 'GhostButton' { Start-Process explorer.exe -ArgumentList "`"$(Get-AppPath Reports)`"" }
    [void]$sp.Children.Add($bar)
    [void]$sp.Children.Add((New-Text (Get-Text 'Ui.558') 11.5 '#7E6C71' -Wrap))
    [void]$UI.ResultsPanel.Children.Add($card)
}

function Get-SelectedHistoryPaths {
    if (-not $script:HistoryGrid) { return @() }
    @($script:HistoryGrid.SelectedItems | ForEach-Object { [string]$_.Row['Path'] })
}

function Open-HistoryEntry {
    $p = Get-SelectedHistoryPaths | Select-Object -First 1
    if (-not $p) { Show-Message (Get-Text 'Ui.560'); return }
    try {
        $res = Import-DiagHistory $p
        $script:ViewedHistory = $res
        $UI.TxtTitle.Text = (Get-Text 'Ui.561' $($res.Title))
        $UI.TxtDesc.Text = (Get-Text 'Ui.562' $($res.Date))
        $UI.BtnBack.Visibility = 'Visible'
        $UI.BtnExport.IsEnabled = $true
        Show-DiagResult $res
    } catch { Show-Message (Get-Text 'Ui.564' $($_.Exception.Message)) (Get-Text 'Ui.565') 'Error' }
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
    Write-AppLog (Get-Text 'Ui.570' $file)
    $file
}

function Export-SelectedHistory([string]$Format = 'Html') {
    $paths = Get-SelectedHistoryPaths
    if (-not $paths) { Show-Message (Get-Text 'Ui.572'); return }
    try {
        $res = @($paths | ForEach-Object { Import-DiagHistory $_ })
        [void](Export-Report $Format $res)
    } catch { Show-Message (Get-Text 'Ui.573' $($_.Exception.Message)) (Get-Text 'Ui.574') 'Error' }
}

function Export-CurrentPage([string]$Format) {
    try {
        if ($script:CurrentPage -eq 'History' -and -not $script:ViewedHistory) { Export-SelectedHistory $Format; return }
        $res = Get-CurrentResult
        if (-not $res) { Show-Message (Get-Text 'Ui.577'); return }
        # Le bilan « avant / après » de la session est ajouté à la fin du rapport (sauf pour un ancien diagnostic de l'historique)
        $bilan = if (-not $script:ViewedHistory) { $script:Results['Bilan'] }
        [void](Export-Report $Format @($res) $bilan)
    } catch { Show-Message (Get-Text 'Ui.579' $($_.Exception.Message)) (Get-Text 'Ui.580') 'Error' }
}

function Remove-SelectedHistory {
    $paths = Get-SelectedHistoryPaths
    if (-not $paths) { Show-Message (Get-Text 'Ui.582'); return }
    if (-not (Confirm-Action ((Get-Text 'Ui.583') -f $paths.Count) (Get-Text 'Ui.584'))) { return }
    foreach ($p in $paths) {
        # Garde-fou : uniquement des fichiers du dossier d'historique
        if ((Split-Path $p -Parent) -eq (Get-AppPath History)) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    }
    Write-AppLog ((Get-Text 'Ui.585') -f $paths.Count) 'ACTION'
    Show-HistoryPage
}

#endregion

#region Jauges en direct, transitions et console ------------------------------------------------

if (-not ('PCToolkit.Sys' -as [type])) {
    # Lecture directe de la charge CPU / RAM (indépendante de la langue de Windows, sans compteur de performance)
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace PCToolkit {
    public static class Sys {
        [StructLayout(LayoutKind.Sequential)]
        public struct MEMORYSTATUSEX { public uint dwLength; public uint dwMemoryLoad; public ulong ullTotalPhys; public ulong ullAvailPhys; public ulong ullTotalPageFile; public ulong ullAvailPageFile; public ulong ullTotalVirtual; public ulong ullAvailVirtual; public ulong ullAvailExtendedVirtual; }
        [DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX s);
        [DllImport("kernel32.dll")] static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
        public static double[] Memory() { var s = new MEMORYSTATUSEX(); s.dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX)); GlobalMemoryStatusEx(ref s); return new double[] { s.dwMemoryLoad, s.ullTotalPhys, s.ullAvailPhys }; }
        public static long[] Times() { long i, k, u; GetSystemTimes(out i, out k, out u); return new long[] { i, k, u }; }
    }
}
'@
}

function Set-SmoothValue($Bar, [double]$Value, [int]$Ms = 450) {
    <# Anime la valeur d'une barre de progression (fluide, au lieu d'un saut). #>
    $a = New-Object Windows.Media.Animation.DoubleAnimation
    $a.To = $Value
    $a.Duration = [TimeSpan]::FromMilliseconds($Ms)
    $a.EasingFunction = New-Object Windows.Media.Animation.CubicEase
    $Bar.BeginAnimation([Windows.Controls.Primitives.RangeBase]::ValueProperty, $a)
}

function Start-PageTransition {
    <# Fondu + léger glissement vers le haut à chaque changement d'onglet. #>
    try {
        $tt = New-Object Windows.Media.TranslateTransform 0, 14
        $UI.ResultsPanel.RenderTransform = $tt
        $fade = New-Object Windows.Media.Animation.DoubleAnimation 0, 1, ([TimeSpan]::FromMilliseconds(260))
        $slide = New-Object Windows.Media.Animation.DoubleAnimation 14, 0, ([TimeSpan]::FromMilliseconds(260))
        $slide.EasingFunction = New-Object Windows.Media.Animation.CubicEase
        $UI.ResultsPanel.BeginAnimation([Windows.UIElement]::OpacityProperty, $fade)
        $tt.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $slide)
    } catch { }
}

$script:PrevCpuTimes = $null
function Set-Gauge($Bar, $Label, [double]$Pct, [string]$Text) {
    $Label.Text = $Text
    $Bar.Foreground = Get-Brush $(if ($Pct -ge 90) { '#FF2A3D' } elseif ($Pct -ge 70) { '#FFB020' } else { '#22E5FF' })
    Set-SmoothValue $Bar $Pct 700
}

function Update-LiveGauges {
    try {
        $t = [PCToolkit.Sys]::Times()
        if ($script:PrevCpuTimes) {
            $dIdle = $t[0] - $script:PrevCpuTimes[0]; $dTot = ($t[1] - $script:PrevCpuTimes[1]) + ($t[2] - $script:PrevCpuTimes[2])
            if ($dTot -gt 0) { $cpu = [math]::Round(100 * (1 - $dIdle / $dTot)); Set-Gauge $UI.GaugeCpu $UI.TxtGaugeCpu $cpu "$cpu %" }
        }
        $script:PrevCpuTimes = $t
        $m = [PCToolkit.Sys]::Memory()
        Set-Gauge $UI.GaugeRam $UI.TxtGaugeRam $m[0] (Get-Text 'Gauge.RamFmt' $m[0] (($m[1] - $m[2]) / 1GB) ($m[1] / 1GB))
        $d = [IO.DriveInfo]$env:SystemDrive
        $usedPct = [math]::Round(100 * (1 - $d.AvailableFreeSpace / $d.TotalSize))
        $UI.LblGaugeDisk.Text = Get-Text 'Gauge.Disk' $env:SystemDrive
        Set-Gauge $UI.GaugeDisk $UI.TxtGaugeDisk $usedPct (Get-Text 'Gauge.DiskFmt' $usedPct (Format-Bytes $d.AvailableFreeSpace))
    } catch { }
}

# --- Console : relit en continu le journal du jour (actions, erreurs, démarrage/fin des analyses) ---
$script:LogFile = $null; $script:LogPos = -1
function Add-LogLine([string]$Line) {
    $color = switch -Regex ($Line) { '\[ACTION\]' { '#22E5FF' } '\[ERROR\]' { '#FF5A6E' } '\[WARN\]' { '#FFB020' } default { '#9FB8BC' } }
    $p = New-Object Windows.Documents.Paragraph
    $p.Margin = [Windows.Thickness]::new(0)
    $r = New-Object Windows.Documents.Run $Line
    $r.Foreground = Get-Brush $color
    [void]$p.Inlines.Add($r)
    [void]$UI.LogBox.Document.Blocks.Add($p)
    while ($UI.LogBox.Document.Blocks.Count -gt 300) { $UI.LogBox.Document.Blocks.Remove($UI.LogBox.Document.Blocks.FirstBlock) }
}

function Update-LogConsole {
    try {
        $file = Join-Path (Get-AppPath Logs) ('toolkit_{0:yyyyMMdd}.log' -f (Get-Date))
        if (-not (Test-Path -LiteralPath $file)) { return }
        $first = $false
        if ($file -ne $script:LogFile) { $script:LogFile = $file; $script:LogPos = -1 }
        $fs = [IO.File]::Open($file, 'Open', 'Read', 'ReadWrite')
        $text = ''
        try {
            if ($script:LogPos -lt 0 -or $script:LogPos -gt $fs.Length) { $script:LogPos = [math]::Max(0, $fs.Length - 2500); $first = ($script:LogPos -gt 0) }
            if ($fs.Length -gt $script:LogPos) {
                [void]$fs.Seek($script:LogPos, 'Begin')
                $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
                $text = $sr.ReadToEnd()
                $script:LogPos = $fs.Length
            }
        } finally { $fs.Dispose() }
        if (-not $text) { return }
        $lines = @($text -split "`r?`n" | Where-Object { $_.Trim() })
        if ($first -and $lines.Count) { $lines = @($lines | Select-Object -Skip 1) }   # première ligne possiblement coupée
        foreach ($l in $lines) { Add-LogLine ($l.TrimStart([char]0xFEFF)) }
        if ($lines.Count) { $UI.LogBox.ScrollToEnd() }
    } catch { }
}

$script:UiTimer = New-Object Windows.Threading.DispatcherTimer
$script:UiTimer.Interval = [TimeSpan]::FromMilliseconds(1000)
$script:UiTimer.Add_Tick({
    Update-LogConsole
    if ($script:CurrentPage -eq 'Dashboard' -and $Window.WindowState -ne 'Minimized') { Update-LiveGauges }
})

#endregion

#region Événements ------------------------------------------------------------------------

foreach ($k in $script:Pages.Keys) {
    $UI[$script:Pages[$k].Nav].Add_Checked({
        param($s, $e)
        $pg = ($script:Pages.GetEnumerator() | Where-Object { $_.Value.Nav -eq $s.Name } | Select-Object -First 1).Key
        if ($pg) {
            try { Set-Page $pg }
            catch { Write-AppLog (Get-Text 'Ui.601' $pg $($_.Exception.Message)) 'ERROR'; Show-Message (Get-Text 'Msg.PageError' $_.Exception.Message) (Get-Text 'Ui.Error') 'Error' }
        }
    })
}

function Update-UiLanguage {
    <# Applique la langue courante à tous les textes fixes de la fenêtre, puis ré-affiche la page. #>
    param([switch]$NoRefresh)
    $Window.Title = Get-Text 'App.Title' $AppVersion
    $UI.TxtSubtitle.Text = Get-Text 'App.Subtitle'
    $UI.TxtVersion.Text = Get-Text 'App.VersionLine' $AppVersion
    $UI.LblLang.Text = Get-Text 'Ui.Lang'
    $UI.LblDiag.Text = Get-Text 'Nav.Diag'
    $UI.LblTools.Text = Get-Text 'Nav.Tools'
    foreach ($k in @($script:Pages.Keys)) { $UI[$script:Pages[$k].Nav].Content = Get-Text "Nav.$k" }
    $UI.TxtElevate.Text = Get-Text 'Ui.Elevate'
    $UI.BtnElevate.ToolTip = Get-Text 'Ui.ElevateTip'
    $UI.TxtAdmin.Text = if ($isAdmin) { Get-Text 'Ui.AdminOn' } else { Get-Text 'Ui.AdminOff' }
    $UI.TxtBack.Text = Get-Text 'Ui.Back'
    $UI.TxtCancel.Text = Get-Text 'Ui.Cancel'
    $UI.BtnExport.ToolTip = Get-Text 'Ui.ExportHtmlTip'
    $UI.BtnExportTxt.ToolTip = Get-Text 'Ui.ExportTxtTip'
    $UI.ChkNotepad.Content = Get-Text 'Ui.OpenNotepad'
    $UI.LblGaugeCpu.Text = Get-Text 'Gauge.Cpu'
    $UI.LblGaugeRam.Text = Get-Text 'Gauge.Ram'
    $UI.LblGaugeDisk.Text = Get-Text 'Gauge.Disk' $env:SystemDrive
    $UI.LblPing.Text = Get-Text 'Opt.Ping'
    $UI.LblDays.Text = Get-Text 'Opt.Days'
    $UI.Days7.Content = Get-Text 'Opt.Days7'
    $UI.Days30.Content = Get-Text 'Opt.Days30'
    $UI.LblFolder.Text = Get-Text 'Opt.Folder'
    $UI.BtnBrowse.Content = Get-Text 'Opt.Browse'
    $UI.LblBig.Text = Get-Text 'Opt.Big'
    $UI.Big100.Content = Get-Text 'Opt.Big100'
    $UI.Big500.Content = Get-Text 'Opt.Big500'
    $UI.Big2000.Content = Get-Text 'Opt.Big2000'
    $UI.BtnLogClear.Content = Get-Text 'Ui.LogClear'
    $UI.BtnLogToggle.Content = if ($UI.LogBox.Visibility -eq 'Visible') { Get-Text 'Ui.LogCollapse' } else { Get-Text 'Ui.LogExpand' }
    $script:StatusText = @{}
    foreach ($s in 'OK', 'Warn', 'Crit', 'Info', 'NA') { $script:StatusText[$s] = Get-Text "Status.$s" }
    Update-PageTexts
    if (-not $NoRefresh) { Set-Page $script:CurrentPage }
}

$UI.BtnRun.Add_Click({ Invoke-PageDiagnostic })
$UI.BtnCancel.Add_Click({ if ($script:Job) { $script:Job.Ctx.Cancel = $true; $UI.TxtStatus.Text = Get-Text 'Msg.Cancelling' } })
$UI.BtnBack.Add_Click({ Set-Page 'History' })
$UI.BtnExport.Add_Click({ Export-CurrentPage 'Html' })
$UI.BtnExportTxt.Add_Click({ Export-CurrentPage 'Txt' })
$UI.BtnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = Get-Text 'Opt.BrowseDesc'
    $dlg.SelectedPath = $UI.TxtScanPath.Text
    if ($dlg.ShowDialog() -eq 'OK') { $UI.TxtScanPath.Text = $dlg.SelectedPath }
})
$UI.BtnElevate.Add_Click({
    if (-not (Confirm-Action (Get-Text 'Elevate.Confirm') (Get-Text 'Ui.AdminOn'))) { return }
    try {
        Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$script:ScriptPath`""
        $Window.Close()
    } catch { Show-Message (Get-Text 'Elevate.Cancelled') (Get-Text 'Ui.AdminOn') }
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
    Write-AppLog (Get-Text 'Ui.609' $($e.Exception.Message)) 'ERROR'
    Show-Message (Get-Text 'Msg.UnhandledError' $e.Exception.Message) (Get-Text 'Ui.Error') 'Error'
    $e.Handled = $true
})

#endregion

#region Démarrage ------------------------------------------------------------------------

$isAdmin = Test-IsAdmin
$UI.AdminIcon.Foreground = Get-Brush $(if ($isAdmin) { '#FFB020' } else { '#3DDC84' })
if ($isAdmin) { $UI.BtnElevate.Visibility = 'Collapsed' }
$UI.TxtScanPath.Text = $env:USERPROFILE
try {
    $cpuName = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name -replace '\s*\d+th Gen\s*|\(R\)|\(TM\)|CPU|Intel', '' -replace '\s+', ' '
    $gpuName = (Get-CimInstance Win32_VideoController | Where-Object Name -notmatch 'Parsec|Virtual|Basic' | Select-Object -First 1).Name -replace 'AMD |Radeon ', '' -replace '\s+', ' '
    $UI.TxtMachine.Text = "$env:COMPUTERNAME`n$($cpuName.Trim()) · $($gpuName.Trim())"
} catch { $UI.TxtMachine.Text = $env:COMPUTERNAME }

Write-AppLog (Get-Text 'Ui.618' $isAdmin)
$UI.BtnLogClear.Add_Click({ $UI.LogBox.Document.Blocks.Clear() })
$UI.BtnLogToggle.Add_Click({
    $open = $UI.LogBox.Visibility -eq 'Visible'
    $UI.LogBox.Visibility = if ($open) { 'Collapsed' } else { 'Visible' }
    $UI.BtnLogToggle.Content = if ($open) { Get-Text 'Ui.LogExpand' } else { Get-Text 'Ui.LogCollapse' }
})
Update-LogConsole
$script:UiTimer.Start()

# Sélecteur de langue FR / EN : changement à chaud (réglage mémorisé dans Data\language.json)
if ((Get-AppLanguage) -eq 'en') { $UI.LangEn.IsChecked = $true } else { $UI.LangFr.IsChecked = $true }
foreach ($pair in @(@('LangFr', 'fr'), @('LangEn', 'en'))) {
    $code = $pair[1]
    $UI[$pair[0]].Add_Checked({
        param($s, $e)
        $c = if ($s.Name -eq 'LangEn') { 'en' } else { 'fr' }
        if ($c -eq (Get-AppLanguage)) { return }
        [void](Set-AppLanguage $c)
        Write-AppLog "Language: $c"
        try { Update-UiLanguage } catch { Write-AppLog "Langue : $($_.Exception.Message)" 'ERROR' }
    })
}
Update-UiLanguage -NoRefresh
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
