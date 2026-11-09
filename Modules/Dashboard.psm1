#requires -Version 5.1
<#
    Dashboard.psm1 — Tableau de bord (lecture seule, ~10 s)
    Vue rapide de l'état général + liste des points d'attention.
    S'appuie sur les fonctions exportées par les autres modules.
#>

function Invoke-DashboardDiagnostic {
    param($Ctx)
    $r = New-DiagResult -Module 'Dashboard' -Title (Get-Text 'Db.002') -Ctx $Ctx
    $alerts = New-Object System.Collections.ArrayList
    function Add-Alert([string]$Status, [string]$Label, [string]$Text) { [void]$alerts.Add([pscustomobject]@{ Status = $Status; Label = $Label; Text = $Text }) }

    $os = Get-SafeCim Win32_OperatingSystem
    $cpu = Get-SafeCim Win32_Processor | Select-Object -First 1

    Add-DiagSection $r (Get-Text 'Db.003') -Layout Tiles -Body {
        param($s)
        Update-DiagProgress $Ctx 5 (Get-Text 'Db.004')
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        Add-DiagItem $s (Get-Text 'Db.005') ((Get-Text 'Db.006') -f $cv.DisplayVersion, $cv.CurrentBuild, $cv.UBR) 'Info'
        $up = (Get-Date) - $os.LastBootUpTime
        Add-DiagItem $s (Get-Text 'Db.007') (Format-Span $up) $(if ($up.TotalDays -gt 7) { 'Warn' } else { 'OK' })
        if ($up.TotalDays -gt 7) { Add-Alert 'Warn' (Get-Text 'Db.008') (Get-Text 'Db.009') }

        Update-DiagProgress $Ctx 15 (Get-Text 'Db.010')
        $load = Get-CpuLoadSample 2
        Add-DiagItem $s (Get-Text 'Db.011') $(if ($null -ne $load) { (Get-Text 'Db.012' $load) }) $(if ($load -ge 90) { 'Crit' } elseif ($load -ge 70) { 'Warn' } else { 'OK' }) ($cpu.Name.Trim())
        if ($load -ge 70) { Add-Alert 'Warn' (Get-Text 'Db.013') (Get-Text 'Db.014' $load) }

        $ramPct = [math]::Round((1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize) * 100, 0)
        Add-DiagItem $s (Get-Text 'Db.015') (Get-Text 'Db.016' $ramPct) $(if ($ramPct -ge 90) { 'Crit' } elseif ($ramPct -ge 80) { 'Warn' } else { 'OK' }) ((Get-Text 'Db.017') -f (Format-Bytes ($os.TotalVisibleMemorySize * 1KB)))
        if ($ramPct -ge 80) { Add-Alert 'Warn' (Get-Text 'Db.018') (Get-Text 'Db.019' $ramPct) }

        Update-DiagProgress $Ctx 25 (Get-Text 'Db.020')
        $c = Get-Volume -DriveLetter ($env:SystemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue
        if ($c) {
            $pct = [math]::Round($c.SizeRemaining / $c.Size * 100, 0)
            $st = if ($pct -lt 8) { 'Crit' } elseif ($pct -lt 15) { 'Warn' } else { 'OK' }
            Add-DiagItem $s (Get-Text 'Db.021') ('{0} ({1} %)' -f (Format-Bytes $c.SizeRemaining), $pct) $st
            if ($st -ne 'OK') { Add-Alert $st (Get-Text 'Db.022') (Get-Text 'Db.023' $pct) }
        }
        $bad = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { "$($_.HealthStatus)" -ne 'Healthy' })
        Add-DiagItem $s (Get-Text 'Db.025') $(if ($bad.Count) { (Get-Text 'Db.026' ($bad.Count)) } else { (Get-Text 'Db.027') }) $(if ($bad.Count) { 'Crit' } else { 'OK' })
        if ($bad.Count) { Add-Alert 'Crit' (Get-Text 'Db.028') ((Get-Text 'Db.029') + (($bad.FriendlyName) -join ', ')) }

        Update-DiagProgress $Ctx 35 (Get-Text 'Db.030')
        $gpu = Get-SafeCim Win32_VideoController | Where-Object Name -notmatch 'Parsec|Virtual|Basic' | Select-Object -First 1
        if ($gpu) {
            $age = if ($gpu.DriverDate) { [int]((Get-Date) - $gpu.DriverDate).TotalDays } else { 0 }
            Add-DiagItem $s (Get-Text 'Db.031') ('{0:dd/MM/yyyy}' -f $gpu.DriverDate) $(if ($age -gt 365) { 'Warn' } else { 'OK' }) $gpu.Name
            if ($age -gt 365) { Add-Alert 'Warn' (Get-Text 'Db.032') (Get-Text 'Db.033' $age) }
        }

        Update-DiagProgress $Ctx 45 (Get-Text 'Db.034')
        $gw = Get-DefaultGateway
        $t = [ordered]@{}; if ($gw) { $t['Box'] = $gw }; $t['Internet'] = '1.1.1.1'
        $series = Measure-PingSeries -Targets $t -DurationSec 5 -Ctx $Ctx -ProgressFrom 45 -ProgressTo 75
        $inet = Get-PingStats ([int[]]$series['Internet'].ToArray())
        if ($inet.NoReply) {
            Add-DiagItem $s (Get-Text 'Db.037') (Get-Text 'Db.038') 'Crit'
            Add-Alert 'Crit' (Get-Text 'Db.039') (Get-Text 'Db.040')
        } else {
            $st = if ($inet.LossPct -ge 5) { 'Crit' } elseif ($inet.LossPct -gt 0 -or $inet.Jitter -gt 5) { 'Warn' } else { 'OK' }
            Add-DiagItem $s (Get-Text 'Db.041') ((Get-Text 'Db.042') -f $inet.Avg) $st ((Get-Text 'Db.043') -f $inet.Jitter, $inet.LossPct)
            if ($st -ne 'OK') { Add-Alert $st (Get-Text 'Db.044') (Get-Text 'Db.045' ($inet.LossPct) ($inet.Jitter)) }
        }

        Update-DiagProgress $Ctx 78 (Get-Text 'Db.046')
        $def = Get-DefaultAudioEndpoint 'Render'
        if ($def) {
            $info = Get-AudioDeviceInfo $def.EndpointId
            Add-DiagItem $s (Get-Text 'Db.048') $def.Device $(if ($info -and $info.Status -ne 'OK') { 'Crit' } else { 'OK' }) ((Get-Text 'Db.049' ($def.Name) (Get-AudioTypeLabel $info.Type))).Trim(' ·')
        } else { Add-DiagItem $s (Get-Text 'Db.050') (Get-Text 'Db.051') 'Warn' (Get-Text 'Db.052') }

        Update-DiagProgress $Ctx 85 (Get-Text 'Db.053')
        $crit = @(Get-EventsSafe @{ LogName = 'System'; Level = 1; StartTime = (Get-Date).AddDays(-1) })
        $whea = @(Get-EventsSafe @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = (Get-Date).AddDays(-7) })
        Add-DiagItem $s (Get-Text 'Db.056') $crit.Count $(if ($crit.Count) { 'Crit' } else { 'OK' })
        if ($crit.Count) { Add-Alert 'Crit' (Get-Text 'Db.057') (Get-Text 'Db.058' ($crit.Count)) }
        if ($whea.Count) { Add-Alert 'Crit' (Get-Text 'Db.059') (Get-Text 'Db.060' ($whea.Count)) }
        if (Test-PendingReboot) { Add-Alert 'Warn' (Get-Text 'Db.061') (Get-Text 'Db.062') }

        $ver = $cv.DisplayVersion
        $eos = Get-WindowsSupportEnd $ver   # liste unique, tenue dans WindowsAnalysis.psm1
        if ($eos -and (Get-Date) -gt $eos) { Add-Alert 'Crit' (Get-Text 'Db.063') (Get-Text 'Db.064' $ver) }

        Add-DiagItem $s (Get-Text 'Db.065') $(if (Test-IsAdmin) { (Get-Text 'Db.066') } else { (Get-Text 'Db.067') }) 'Info' (Get-Text 'Db.068')
    }

    Update-DiagProgress $Ctx 95 (Get-Text 'Db.069')
    Add-DiagSection $r (Get-Text 'Db.070') -Body {
        param($s)
        if ($alerts.Count -eq 0) { Add-DiagItem $s (Get-Text 'Db.071') (Get-Text 'Db.072') 'OK' }
        foreach ($a in $alerts | Sort-Object { if ($_.Status -eq 'Crit') { 0 } else { 1 } }) { Add-DiagItem $s $a.Label $a.Text $a.Status }
        Add-DiagNote $s (Get-Text 'Db.073')
    }

    Update-DiagProgress $Ctx 100 (Get-Text 'Db.074')
    $r
}

Export-ModuleMember -Function Invoke-DashboardDiagnostic
