#requires -Version 5.1
<#
    Network.psm1 — Diagnostic réseau (lecture seule)
    Carte réseau, configuration IP/DNS/DoH, test de ping (latence, gigue, pertes),
    temps de résolution DNS, retransmissions TCP. Aucune modification de configuration.
#>

function Get-DefaultGateway {
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | Select-Object -First 1
    if ($route) { $route.NextHop } else { $null }
}

function Measure-PingSeries {
    <#
        Envoie des pings en parallèle vers plusieurs cibles pendant DurationSec secondes.
        Renvoie une table : cible -> liste des RTT (-1 = pas de réponse).
    #>
    param([System.Collections.Specialized.OrderedDictionary]$Targets, [int]$DurationSec = 30, [int]$IntervalMs = 250, $Ctx, [int]$ProgressFrom = 0, [int]$ProgressTo = 100)
    $buf = New-Object byte[] 32
    $pingers = @{}; $data = @{}
    foreach ($k in $Targets.Keys) { $pingers[$k] = New-Object System.Net.NetworkInformation.Ping; $data[$k] = New-Object System.Collections.Generic.List[int] }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $DurationSec) {
        if (Test-DiagCancel $Ctx) { break }
        $t0 = $sw.ElapsedMilliseconds
        $tasks = @{}
        foreach ($k in $Targets.Keys) { $tasks[$k] = $pingers[$k].SendPingAsync($Targets[$k], 1000, $buf) }
        try { [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($tasks.Values), 1500) } catch { }
        foreach ($k in $Targets.Keys) {
            $t = $tasks[$k]
            $v = -1
            if ($t.IsCompleted -and -not $t.IsFaulted -and $t.Result.Status -eq 'Success') { $v = [int]$t.Result.RoundtripTime }
            $data[$k].Add($v)
        }
        $pct = $ProgressFrom + ($ProgressTo - $ProgressFrom) * [math]::Min(1, $sw.Elapsed.TotalSeconds / $DurationSec)
        Update-DiagProgress $Ctx ([int]$pct) ((Get-Text 'Net.002') -f $sw.Elapsed.TotalSeconds, $DurationSec)
        $wait = $IntervalMs - ($sw.ElapsedMilliseconds - $t0)
        if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
    }
    foreach ($p in $pingers.Values) { $p.Dispose() }
    $data
}

function Get-PingStats {
    <# Statistiques d'une série de pings : pertes, min/moy/médiane/P95/max, gigue, pertes consécutives. #>
    param([int[]]$Values)
    $ok = @($Values | Where-Object { $_ -ge 0 })
    $n = $Values.Count
    $maxRun = 0; $run = 0
    foreach ($v in $Values) { if ($v -lt 0) { $run++; if ($run -gt $maxRun) { $maxRun = $run } } else { $run = 0 } }
    if ($ok.Count -eq 0) { return [pscustomobject]@{ Sent = $n; Received = 0; LossPct = 100; NoReply = $true; MaxConsecutiveLoss = $maxRun } }
    $sorted = [double[]]($ok | Sort-Object)
    $jit = 0; for ($i = 1; $i -lt $ok.Count; $i++) { $jit += [math]::Abs($ok[$i] - $ok[$i - 1]) }
    [pscustomobject]@{
        Sent               = $n
        Received           = $ok.Count
        LossPct            = [math]::Round(($n - $ok.Count) / [math]::Max(1, $n) * 100, 2)
        Min                = $sorted[0]
        Avg                = [math]::Round(($ok | Measure-Object -Average).Average, 1)
        Median             = Get-Percentile $sorted 50
        P95                = Get-Percentile $sorted 95
        Max                = $sorted[-1]
        Jitter             = [math]::Round($jit / [math]::Max(1, $ok.Count - 1), 2)
        MaxConsecutiveLoss = $maxRun
        NoReply            = $false
    }
}

function Measure-DnsResolution {
    <# Temps de résolution (ms) en interrogeant directement un serveur DNS (UDP, sans cache local ni fichier hosts). #>
    param([string]$Server, [string[]]$Names)
    $times = @(); $fail = 0
    foreach ($n in $Names) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $null = Resolve-DnsName -Name $n -Server $Server -DnsOnly -NoHostsFile -QuickTimeout -Type A -ErrorAction Stop
            $times += $sw.Elapsed.TotalMilliseconds
        } catch { $fail++ }
    }
    $sorted = [double[]]($times | Sort-Object)
    [pscustomobject]@{
        Server = $Server
        Median = if ($sorted.Count) { [math]::Round((Get-Percentile $sorted 50), 1) } else { $null }
        Max    = if ($sorted.Count) { [math]::Round($sorted[-1], 1) } else { $null }
        Failed = $fail
        Total  = $Names.Count
    }
}

function Invoke-NetworkDiagnostic {
    param($Ctx, [int]$DurationSec = 30)
    $r = New-DiagResult -Module 'Network' -Title (Get-Text 'Net.004') -Ctx $Ctx
    $gateway = Get-DefaultGateway

    # --- Cartes réseau ----------------------------------------------------------
    Update-DiagProgress $Ctx 3 (Get-Text 'Net.005')
    Add-DiagSection $r (Get-Text 'Net.006') -Body {
        param($s)
        $up = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up')
        foreach ($a in $up | Where-Object { $_.HardwareInterface }) {
            $speedOk = $a.LinkSpeed -match 'Gbps' -or ($a.LinkSpeed -match '(\d+)\s*Mbps' -and [int]$Matches[1] -ge 1000)
            Add-DiagItem $s $a.Name ('{0} · {1}' -f $a.InterfaceDescription, $a.LinkSpeed) $(if ($a.MediaType -match '802.3' -and -not $speedOk) { 'Warn' } else { 'OK' }) $(if ($a.MediaType -match '802.3' -and -not $speedOk) { (Get-Text 'Net.007') } else { '' })
        }
        $virt = $up | Where-Object { -not $_.HardwareInterface -or $_.InterfaceDescription -match 'VPN|TAP|Wintun|WireGuard|VirtualBox|Hyper-V|Proton' }
        foreach ($v in $virt) { Add-DiagItem $s ((Get-Text 'Net.008') -f $v.Name) $v.InterfaceDescription 'Info' (Get-Text 'Net.009') }
        Add-DiagItem $s (Get-Text 'Net.010') $gateway $(if ($gateway) { 'OK' } else { 'Crit' })
        $cfg = Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPv4DefaultGateway } | Select-Object -First 1
        if ($cfg) {
            Add-DiagItem $s (Get-Text 'Net.011') (($cfg.IPv4Address.IPAddress) -join ', ')
            $v6 = @($cfg.IPv6Address.IPAddress | Where-Object { $_ -notmatch '^fe80' })
            Add-DiagItem $s (Get-Text 'Net.012') $(if ($v6.Count) { 'Oui' } else { 'Non' }) 'Info'
        }
    }

    # --- DNS --------------------------------------------------------------------
    Update-DiagProgress $Ctx 8 (Get-Text 'Net.013')
    $script:dnsServers = @()
    Add-DiagSection $r (Get-Text 'Net.014') -Body {
        param($s)
        $ifIdx = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | Select-Object -First 1).InterfaceIndex
        $srv = @(Get-DnsClientServerAddress -InterfaceIndex $ifIdx -ErrorAction SilentlyContinue | ForEach-Object ServerAddresses)
        $script:dnsServers = @($srv | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })
        $known = @{ '76.76.2.2' = (Get-Text 'Net.015'); '76.76.10.2' = 'Control D'; '1.1.1.1' = 'Cloudflare'; '1.0.0.1' = 'Cloudflare'; '8.8.8.8' = 'Google'; '8.8.4.4' = 'Google'; '94.140.14.14' = 'AdGuard'; '9.9.9.9' = 'Quad9' }
        foreach ($d in $srv) {
            $name = if ($known.ContainsKey($d)) { $known[$d] } elseif ($d -eq $gateway) { (Get-Text 'Net.022') } else { '' }
            Add-DiagItem $s (Get-Text 'Net.023') ("$d $(if($name){"· $name"})").Trim() 'Info'
        }
        $doh = @(try { Get-DnsClientDohServerAddress -ErrorAction Stop } catch { })
        $enc = @($srv | Where-Object { $d = $_; $doh | Where-Object ServerAddress -eq $d })
        if ($srv.Count) {
            Add-DiagItem $s (Get-Text 'Net.025') ((Get-Text 'Net.026') -f $enc.Count, $srv.Count) $(if ($enc.Count -eq $srv.Count) { 'OK' } elseif ($enc.Count) { 'Warn' } else { 'Info' }) (Get-Text 'Net.027')
        }
        # Test de filtrage : un domaine publicitaire bloqué renvoie 0.0.0.0
        try {
            $ad = [System.Net.Dns]::GetHostAddresses('doubleclick.net') | Select-Object -First 1
            Add-DiagItem $s (Get-Text 'Net.028') $(if ("$ad" -in '0.0.0.0', '::') { (Get-Text 'Net.029') } else { (Get-Text 'Net.030' $ad) }) 'Info'
        } catch { Add-DiagItem $s (Get-Text 'Net.031') (Get-Text 'Net.032') 'Info' }
    }

    # --- Ping -------------------------------------------------------------------
    $targets = [ordered]@{}
    if ($gateway) { $targets['Box'] = $gateway }
    $targets['Cloudflare 1.1.1.1'] = '1.1.1.1'
    $targets['Google 8.8.8.8'] = '8.8.8.8'
    Update-DiagProgress $Ctx 12 (Get-Text 'Net.035')
    $series = Measure-PingSeries -Targets $targets -DurationSec $DurationSec -Ctx $Ctx -ProgressFrom 12 -ProgressTo 80
    if (Test-DiagCancel $Ctx) { $r.Cancelled = $true }

    Add-DiagSection $r ((Get-Text 'Net.036') -f $DurationSec) -Body {
        param($s)
        $rows = @()
        foreach ($k in $targets.Keys) {
            $st = Get-PingStats ([int[]]$series[$k].ToArray())
            if ($st.NoReply) {
                Add-DiagItem $s $k (Get-Text 'Net.037') 'Warn' (Get-Text 'Net.038')
                continue
            }
            $isLan = $k -eq 'Box'
            $lossSt = if ($st.LossPct -ge 5) { 'Crit' } elseif ($st.LossPct -ge 1) { 'Warn' } else { 'OK' }
            $latSt = if ($isLan) { if ($st.Avg -gt 5) { 'Warn' } else { 'OK' } } else { if ($st.Avg -gt 60) { 'Warn' } else { 'OK' } }
            $jitSt = if ($st.Jitter -gt 15) { 'Crit' } elseif ($st.Jitter -gt 5) { 'Warn' } else { 'OK' }
            $worst = @($lossSt, $latSt, $jitSt) | Sort-Object { @{ OK = 0; Warn = 1; Crit = 2 }[$_] } -Descending | Select-Object -First 1
            Add-DiagItem $s $k ((Get-Text 'Net.039') -f $st.Avg, $st.Jitter, $st.LossPct) $worst $(if ($st.MaxConsecutiveLoss -ge 3) { (Get-Text 'Net.040' $($st.MaxConsecutiveLoss)) } else { '' })
            $rows += [pscustomobject]@{ Cible = $k; Envoyés = $st.Sent; 'Pertes %' = $st.LossPct; Min = $st.Min; Moyenne = $st.Avg; Médiane = $st.Median; P95 = $st.P95; Max = $st.Max; Gigue = $st.Jitter; 'Pertes consécutives max' = $st.MaxConsecutiveLoss }
        }
        Add-DiagTable $s (Get-Text 'Net.041') $rows
        Add-DiagNote $s (Get-Text 'Net.042')
    }

    # --- Résolution DNS -----------------------------------------------------------
    if (-not $r.Cancelled) {
        Update-DiagProgress $Ctx 82 (Get-Text 'Net.043')
        Add-DiagSection $r (Get-Text 'Net.044') -Body {
            param($s)
            $names = 'google.com', 'youtube.com', 'discord.com', 'steampowered.com', 'wikipedia.org', 'microsoft.com', 'twitch.tv', 'amazon.fr'
            $servers = [ordered]@{}
            foreach ($d in $script:dnsServers) { $servers[(Get-Text 'Net.045' $d)] = $d }
            if (-not $servers.Contains((Get-Text 'Net.046'))) { $servers['Cloudflare (1.1.1.1)'] = '1.1.1.1' }
            if (-not $servers.Contains((Get-Text 'Net.048'))) { $servers['Google (8.8.8.8)'] = '8.8.8.8' }
            if ($gateway -and @($servers.Values) -notcontains $gateway) { $servers[(Get-Text 'Net.050' $gateway)] = $gateway }
            $rows = @(); $i = 0
            foreach ($k in $servers.Keys) {
                if (Test-DiagCancel $Ctx) { break }
                $i++; Update-DiagProgress $Ctx (82 + [int](12 * $i / $servers.Count)) (Get-Text 'Net.051' $k)
                $m = Measure-DnsResolution -Server $servers[$k] -Names $names
                $rows += [pscustomobject]@{ Serveur = $k; 'Médiane ms' = $m.Median; 'Max ms' = $m.Max; Échecs = ('{0}/{1}' -f $m.Failed, $m.Total) }
                if ($k -like ((Get-Text 'Net.045' 'ZZ') -replace 'ZZ\)$', '*')) {   # libellés « Actuel (…) » / « Current (…) »
                    $st = if ($m.Failed -ge 2 -or $null -eq $m.Median) { 'Crit' } elseif ($m.Median -gt 60) { 'Warn' } else { 'OK' }
                    Add-DiagItem $s $k $(if ($null -ne $m.Median) { (Get-Text 'Net.052' $($m.Median) $($m.Failed)) }) $st
                }
            }
            Add-DiagTable $s (Get-Text 'Net.053') $rows
            Add-DiagNote $s (Get-Text 'Net.054')
        }

        # --- TCP --------------------------------------------------------------------
        Update-DiagProgress $Ctx 96 (Get-Text 'Net.055')
        Add-DiagSection $r (Get-Text 'Net.056') -Body {
            param($s)
            $t = Get-SafeCim Win32_PerfRawData_Tcpip_TCPv4
            if ($t -and $t.SegmentsSentPersec -gt 0) {
                $ratio = [math]::Round($t.SegmentsRetransmittedPersec / $t.SegmentsSentPersec * 100, 2)
                Add-DiagItem $s (Get-Text 'Net.057') (Get-Text 'Net.058' $ratio) $(if ($ratio -ge 3) { 'Warn' } else { 'OK' }) (Get-Text 'Net.059')
            }
            $est = @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue).Count
            Add-DiagItem $s (Get-Text 'Net.060') $est 'Info'
        }
    }

    Update-DiagProgress $Ctx 100 (Get-Text 'Net.061')
    $r
}

Export-ModuleMember -Function Invoke-NetworkDiagnostic, Get-DefaultGateway, Measure-PingSeries, Get-PingStats, Measure-DnsResolution
