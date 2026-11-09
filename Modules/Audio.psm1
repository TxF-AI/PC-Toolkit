#requires -Version 5.1
<#
    Audio.psm1 — Diagnostic audio universel (lecture seule)
    Analyse le périphérique audio PAR DÉFAUT de Windows, quel qu'il soit : carte son de la carte mère
    (Realtek…), DAC ou interface USB, casque Bluetooth, sortie HDMI de la carte graphique, GoXLR, périphérique virtuel…
    Fréquences d'échantillonnage, pilotes, ASIO, suspension USB, latence DPC indicative.
    Une section Focusrite supplémentaire n'apparaît que si une interface Focusrite est branchée.
#>

$script:PKEY_Name    = '{a45c254e-df1c-4efd-8020-67d146a850e0},2'   # nom du point de terminaison (« Haut-parleurs »)
$script:PKEY_Adapter = '{b3f8fa53-0004-438e-9003-51a46e139bfc},6'   # nom du périphérique (« Realtek(R) Audio »)
$script:PKEY_Format  = '{f19f064d-082c-4e27-bc73-6882a1bb8e4c},0'   # format partagé (WAVEFORMATEX précédé de 8 octets)

# Lecture du périphérique par défaut via l'API Core Audio de Windows (IMMDeviceEnumerator), sans dépendance externe
if (-not ('PCToolkit.AudioDefault' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace PCToolkit {
    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator {
        int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
    }
    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice {
        int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, out IntPtr iface);
        int OpenPropertyStore(int access, out IntPtr store);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
    }
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorCom { }
    public static class AudioDefault {
        // flow : 0 = sortie (render), 1 = entrée (capture) ; role : 0 = console, 1 = multimédia, 2 = communications
        public static string GetId(int flow, int role) {
            try {
                var e = (IMMDeviceEnumerator)new MMDeviceEnumeratorCom();
                IMMDevice d;
                if (e.GetDefaultAudioEndpoint(flow, role, out d) != 0 || d == null) return null;
                string id; d.GetId(out id); return id;
            } catch { return null; }
        }
    }
}
'@
}

function Get-AudioEndpoints {
    <# Points de terminaison audio lus dans le registre (MMDevices) avec leur format partagé. #>
    $out = @()
    foreach ($flow in 'Render', 'Capture') {
        $base = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\$flow"
        foreach ($k in Get-ChildItem $base -ErrorAction SilentlyContinue) {
            $state = [int]((Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue).DeviceState) -band 0xF
            $p = Get-ItemProperty (Join-Path $k.PSPath 'Properties') -ErrorAction SilentlyContinue
            if (-not $p) { continue }
            $fmt = $p.$script:PKEY_Format
            $rate = $null; $bits = $null; $ch = $null
            if ($fmt -is [byte[]] -and $fmt.Length -ge 24) {
                $ch = [BitConverter]::ToUInt16($fmt, 10)
                $rate = [BitConverter]::ToUInt32($fmt, 12)
                $bits = [BitConverter]::ToUInt16($fmt, 22)
            }
            $out += [pscustomobject]@{
                Key      = $k.PSChildName.ToLower()
                Flow     = $(if ($flow -eq 'Render') { 'Sortie' } else { 'Entrée' })
                Name     = $p.$script:PKEY_Name
                Device   = $p.$script:PKEY_Adapter
                State    = switch ($state) { 1 { 'Actif' } 2 { 'Désactivé' } 4 { 'Absent' } 8 { 'Débranché' } default { "$state" } }
                Rate     = $rate
                Bits     = $bits
                Channels = $ch
            }
        }
    }
    $out
}

function Get-DefaultAudioEndpoint {
    <# Point de terminaison par défaut (rôle multimédia) avec son identifiant complet. #>
    param([ValidateSet('Render', 'Capture')][string]$Flow = 'Render')
    $id = [PCToolkit.AudioDefault]::GetId($(if ($Flow -eq 'Render') { 0 } else { 1 }), 1)
    if (-not $id) { return $null }
    $key = ($id -split '\.')[-1].ToLower()     # « {0.0.0.00000000}.{guid} » -> « {guid} »
    $ep = Get-AudioEndpoints | Where-Object { $_.Key -eq $key -and $_.Flow -eq $(if ($Flow -eq 'Render') { 'Sortie' } else { 'Entrée' }) } | Select-Object -First 1
    if ($ep) { $ep | Add-Member -NotePropertyName EndpointId -NotePropertyValue $id -PassThru }
}

function Get-AudioDeviceInfo {
    <# Périphérique physique derrière un point de terminaison : type de connexion, pilote, chaîne USB. #>
    param([string]$EndpointId)
    $epDev = "SWD\MMDEVAPI\$EndpointId"
    $parent = (Get-PnpDeviceProperty -InstanceId $epDev -KeyName 'DEVPKEY_Device_Parent' -ErrorAction SilentlyContinue).Data
    if (-not $parent) { return $null }
    $dev = Get-PnpDevice -InstanceId $parent -ErrorAction SilentlyContinue
    $name = "$($dev.FriendlyName)"
    $type = switch -Regex ($parent) {
        '^USB'                     { 'USB'; break }
        '^(BTH|BTHENUM|BTHHFENUM|BTHLEDEVICE)' { 'Bluetooth'; break }
        '^HDAUDIO'                 { if ($name -match 'HDMI|DisplayPort|NVIDIA|AMD High Definition|Intel\(R\) Display') { 'HDMI / DisplayPort' } else { 'Carte mère (HD Audio)' }; break }
        '^(ROOT|SWD|SW)\\'         { 'Virtuel (logiciel)'; break }
        default                    { 'Autre' }
    }
    # Interfaces « pro » (Focusrite, RME, Universal Audio…) : le pilote du fabricant crée son propre bus logiciel.
    # On retrouve alors le vrai périphérique USB par le nom du fabricant.
    $usbNode = if ($type -eq 'USB') { $parent }
    if ($type -eq 'Autre') {
        $brand = ($name -split '\s+' | Select-Object -First 1)
        if ($brand -and $brand.Length -ge 3) {
            $usb = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
                Where-Object { $_.InstanceId -like 'USB\*' -and ($_.Manufacturer -match [regex]::Escape($brand) -or $_.FriendlyName -match [regex]::Escape($brand)) } |
                Select-Object -First 1
            if ($usb) { $type = 'USB (pilote du fabricant)'; $usbNode = $usb.InstanceId }
        }
    }
    $hub = $null
    if ($usbNode) {
        $id = $usbNode
        for ($i = 0; $i -lt 6 -and $id; $i++) {
            $id = (Get-PnpDeviceProperty -InstanceId $id -KeyName 'DEVPKEY_Device_Parent' -ErrorAction SilentlyContinue).Data
            if (-not $id) { break }
            $n = (Get-PnpDevice -InstanceId $id -ErrorAction SilentlyContinue).FriendlyName
            if ($n -match 'Hub|Concentrateur' -and $n -notmatch 'Root|racine') { $hub = $n; break }
        }
    }
    [pscustomobject]@{
        InstanceId = $parent
        Name       = $name
        Status     = "$($dev.Status)"
        Type       = $type
        Driver     = (Get-PnpDeviceProperty -InstanceId $parent -KeyName 'DEVPKEY_Device_DriverVersion' -ErrorAction SilentlyContinue).Data
        Provider   = (Get-PnpDeviceProperty -InstanceId $parent -KeyName 'DEVPKEY_Device_DriverProvider' -ErrorAction SilentlyContinue).Data
        Hub        = $hub
    }
}

function Get-AsioDrivers {
    <# Pilotes ASIO déclarés (64 et 32 bits) avec vérification de la DLL associée. #>
    $out = @()
    foreach ($view in @(@{ Key = 'HKLM:\SOFTWARE\ASIO'; Arch = '64 bits'; Cls = 'HKLM:\SOFTWARE\Classes\CLSID' },
                        @{ Key = 'HKLM:\SOFTWARE\WOW6432Node\ASIO'; Arch = '32 bits'; Cls = 'HKLM:\SOFTWARE\Classes\WOW6432Node\CLSID' })) {
        foreach ($k in Get-ChildItem $view.Key -ErrorAction SilentlyContinue) {
            $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
            $dll = (Get-ItemProperty (Join-Path $view.Cls "$($p.CLSID)\InprocServer32") -ErrorAction SilentlyContinue).'(default)'
            $exists = if ($dll) { Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($dll)) } else { $false }
            $out += [pscustomobject]@{ Nom = $k.PSChildName; Architecture = $view.Arch; Fichier = $dll; Présent = $(if ($exists) { 'Oui' } else { 'Non' }) }
        }
    }
    $out
}

function Get-UsbSelectiveSuspend {
    <# Valeur « Suspension sélective USB » du mode d'alimentation actif, sur secteur (1 = activée). #>
    try {
        $q = powercfg /query SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 2>$null
        $ac = $q | Select-String -Pattern '0x0000000(\d)' | Select-Object -First 1
        if ($ac) { return [int]$ac.Matches[0].Groups[1].Value }
    } catch { }
    $null
}

function Add-DefaultDeviceItems {
    <# Remplit une section avec la description d'un périphérique par défaut (sortie ou entrée). #>
    param($Section, $Endpoint, $Info, [string]$Kind)
    if (-not $Endpoint) { Add-DiagItem $Section "$Kind par défaut" 'Aucune' 'Warn' 'Aucun périphérique par défaut : vérifiez Paramètres > Système > Son.'; return }
    Add-DiagItem $Section "$Kind par défaut" ('{0} — {1}' -f $Endpoint.Name, $Endpoint.Device) 'OK'
    if ($Info) {
        Add-DiagItem $Section 'Type de connexion' $Info.Type 'Info'
        Add-DiagItem $Section 'État du périphérique' $Info.Status $(if ($Info.Status -eq 'OK') { 'OK' } else { 'Crit' })
        Add-DiagItem $Section 'Pilote' ('{0} {1}' -f $Info.Provider, $Info.Driver).Trim() 'Info'
        switch ($Info.Type) {
            'Bluetooth' { Add-DiagItem $Section 'Latence Bluetooth' 'Élevée par nature (100 à 250 ms)' 'Info' 'Décalage audio normal en Bluetooth. Pour jouer en compétitif ou faire de la musique, préférez un casque filaire ou un dongle 2,4 GHz.' }
            { $_ -like 'USB*' } {
                if ($Info.Hub) { Add-DiagItem $Section 'Branchement USB' "Via un hub ($($Info.Hub))" 'Warn' 'Un hub USB partagé (façade du boîtier, multiprise USB) peut provoquer craquements et coupures. Préférez un port arrière de la carte mère.' }
                else { Add-DiagItem $Section 'Branchement USB' 'Port direct de la carte mère' 'OK' }
            }
            'Virtuel (logiciel)' { Add-DiagItem $Section 'Périphérique virtuel' 'Le son passe par un logiciel (Voicemeeter, VB-Cable, Sonar…)' 'Info' 'En cas de souci, vérifiez d''abord ce logiciel et le périphérique réel vers lequel il renvoie le son.' }
        }
    }
    if ($Endpoint.Rate) { Add-DiagItem $Section 'Format partagé Windows' ('{0:N1} kHz · {1} bits · {2} canal(aux)' -f ($Endpoint.Rate / 1000), $Endpoint.Bits, $Endpoint.Channels) 'Info' }
}

function Invoke-AudioDiagnostic {
    param($Ctx)
    $r = New-DiagResult -Module 'Audio' -Title 'Diagnostic audio' -Ctx $Ctx

    Update-DiagProgress $Ctx 5 'Recherche du périphérique audio par défaut…'
    $out = Get-DefaultAudioEndpoint 'Render'
    $in = Get-DefaultAudioEndpoint 'Capture'
    $outInfo = if ($out) { Get-AudioDeviceInfo $out.EndpointId }
    $inInfo = if ($in) { Get-AudioDeviceInfo $in.EndpointId }

    # --- Sortie / entrée par défaut ------------------------------------------------------
    Add-DiagSection $r 'Sortie audio par défaut (haut-parleurs / casque)' -Body {
        param($s)
        Add-DefaultDeviceItems $s $out $outInfo 'Sortie'
    }
    Update-DiagProgress $Ctx 20 'Entrée audio par défaut…'
    Add-DiagSection $r 'Entrée audio par défaut (micro)' -Body {
        param($s)
        Add-DefaultDeviceItems $s $in $inInfo 'Entrée'
        # Même appareil en entrée et en sortie (interface, casque USB) : les fréquences doivent correspondre
        if ($out -and $in -and $outInfo -and $inInfo -and $outInfo.InstanceId -eq $inInfo.InstanceId -and $out.Rate -and $in.Rate) {
            if ($out.Rate -ne $in.Rate) {
                Add-DiagItem $s 'Fréquences entrée / sortie' ('{0:N1} kHz / {1:N1} kHz' -f ($out.Rate / 1000), ($in.Rate / 1000)) 'Warn' 'Même appareil réglé à deux fréquences différentes : alignez-les (Panneau de configuration Son > Propriétés > Avancé), et utilisez la même dans votre logiciel audio.'
            } else {
                Add-DiagItem $s 'Fréquences entrée / sortie' ('{0:N1} kHz des deux côtés' -f ($out.Rate / 1000)) 'OK'
            }
        }
    }

    # --- Tous les périphériques ------------------------------------------------------------
    Update-DiagProgress $Ctx 35 'Liste des périphériques audio…'
    Add-DiagSection $r 'Tous les périphériques audio' -Body {
        param($s)
        $eps = @(Get-AudioEndpoints)
        $active = @($eps | Where-Object State -eq 'Actif')
        Add-DiagItem $s 'Points de terminaison actifs' ('{0} sortie(s), {1} entrée(s)' -f @($active | Where-Object Flow -eq 'Sortie').Count, @($active | Where-Object Flow -eq 'Entrée').Count) 'Info'
        $duck = (Get-ItemProperty 'HKCU:\Software\Microsoft\Multimedia\Audio' -ErrorAction SilentlyContinue).UserDuckingPreference
        if ($null -ne $duck) { Add-DiagItem $s 'Atténuation pendant les appels' $(switch ($duck) { 0 { 'Couper tous les autres sons' } 1 { 'Réduire de 80 %' } 2 { 'Réduire de 50 %' } 3 { 'Ne rien faire' } }) 'Info' 'Réglage Windows qui baisse le son pendant un appel (Discord, Teams…). Explique des baisses de volume « mystérieuses ».' }
        $defKeys = @($out.Key, $in.Key)
        $rows = $eps | Where-Object { $_.State -in 'Actif', 'Débranché' } | Sort-Object Flow, State, Name | ForEach-Object {
            [pscustomobject]@{ 'Par défaut' = $(if ($defKeys -contains $_.Key) { '★' } else { '' }); Type = $_.Flow; Nom = $_.Name; Appareil = $_.Device; État = $_.State; Fréquence = $(if ($_.Rate) { '{0:N1} kHz' -f ($_.Rate / 1000) } else { '' }); Bits = $_.Bits; Canaux = $_.Channels }
        }
        Add-DiagTable $s 'Points de terminaison (★ = par défaut)' $rows
        $snd = @(Get-SafeCim Win32_SoundDevice)
        $bad = @($snd | Where-Object Status -ne 'OK')
        Add-DiagItem $s 'Contrôleurs audio' ('{0} détecté(s), {1} en erreur' -f $snd.Count, $bad.Count) $(if ($bad.Count) { 'Warn' } else { 'OK' })
        Add-DiagTable $s 'Contrôleurs (pilotes)' ($snd | ForEach-Object { [pscustomobject]@{ Nom = $_.Name; Fabricant = $_.Manufacturer; État = $_.Status } })
    }

    # --- ASIO ----------------------------------------------------------------------------
    Update-DiagProgress $Ctx 55 'Lecture des pilotes ASIO…'
    Add-DiagSection $r 'Pilotes ASIO (musique assistée par ordinateur)' -Body {
        param($s)
        $asio = @(Get-AsioDrivers)
        Add-DiagItem $s 'Pilotes ASIO déclarés' $asio.Count 'Info'
        $orph = @($asio | Where-Object Présent -eq 'Non')
        if ($orph.Count) { Add-DiagItem $s 'Pilotes ASIO orphelins' (($orph.Nom) -join ', ') 'Warn' 'Déclarés mais leur fichier n''existe plus (restes de désinstallation). Sans danger, mais ils encombrent la liste des logiciels audio.' }
        if ($outInfo) {
            $brand = (($outInfo.Name, $out.Device) -join ' ' -split '[\s\(\)]+' | Where-Object { $_.Length -ge 4 -and $_ -notmatch '^(Audio|High|Definition|Device|USB|Speakers|Haut)' } | Select-Object -First 1)
            # À marque égale, on préfère le pilote qui correspond au branchement (USB, Thunderbolt…)
            $conn = if ($outInfo.Type -like 'USB*') { 'USB' } else { '' }
            $match = if ($brand) { $asio | Where-Object { $_.Nom -match [regex]::Escape($brand) -and $_.Présent -eq 'Oui' } | Sort-Object { if ($conn -and $_.Nom -match $conn) { 0 } else { 1 } } | Select-Object -First 1 }
            if ($match) { Add-DiagItem $s 'ASIO du périphérique par défaut' $match.Nom 'OK' 'Pilote dédié trouvé : c''est celui à choisir dans votre logiciel audio pour la latence la plus basse.' }
            elseif ($asio.Count) { Add-DiagItem $s 'ASIO du périphérique par défaut' 'Aucun pilote dédié reconnu' 'Info' 'Normal pour une carte son intégrée, un casque ou du Bluetooth. Pour la musique, les génériques ASIO4ALL ou FlexASIO conviennent.' }
        }
        if ($asio.Count) { Add-DiagTable $s 'Liste' $asio } else { Add-DiagNote $s 'Aucun pilote ASIO : normal si vous ne faites pas de musique assistée par ordinateur.' }
    }

    # --- Focusrite (seulement si présente) ------------------------------------------------
    $foc = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match 'Scarlett|Focusrite|Clarett|Vocaster' })
    $log = Join-Path $env:APPDATA 'Focusrite\Focusrite Control 2\fc2.log'
    if ($foc.Count -and (Test-Path -LiteralPath $log)) {
        Update-DiagProgress $Ctx 65 'Journal Focusrite…'
        Add-DiagSection $r 'Interface Focusrite (détectée)' -Body {
            param($s)
            Add-DiagItem $s 'Interface' (($foc | Select-Object -First 1).FriendlyName) 'Info'
            $lines = Get-Content -LiteralPath $log -Tail 5000 -ErrorAction SilentlyContinue | Select-String -Pattern 'Device removed' -SimpleMatch
            $events = foreach ($l in $lines) {
                if ($l.Line -match '^(\d{1,2} \w{3} \d{4} \d{2}:\d{2}:\d{2})') {
                    $d = [datetime]::MinValue
                    if ([datetime]::TryParseExact($Matches[1], 'd MMM yyyy HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$d)) { $d }
                }
            }
            $events = @($events | Sort-Object -Descending)
            $recent = @($events | Where-Object { $_ -gt (Get-Date).AddDays(-14) })
            Add-DiagItem $s 'Déconnexions (14 derniers jours)' $recent.Count $(if ($recent.Count -ge 3) { 'Warn' } else { 'Info' }) 'Source : journal Focusrite Control 2. Inclut les débranchements manuels et extinctions du PC.'
            if ($events) { Add-DiagTable $s 'Dernières déconnexions' ($events | Select-Object -First 10 | ForEach-Object { [pscustomobject]@{ Date = $_.ToString('ddd dd/MM/yyyy HH:mm:ss') } }) }
        }
    }

    # --- Système et latence -------------------------------------------------------------
    Update-DiagProgress $Ctx 72 'Mesure indicative des interruptions (5 s)…'
    Add-DiagSection $r 'Système et latence' -Body {
        param($s)
        foreach ($svcName in 'Audiosrv', 'AudioEndpointBuilder') {
            $svc = Get-Service $svcName -ErrorAction SilentlyContinue
            Add-DiagItem $s "Service $svcName" "$($svc.Status)" $(if ($svc.Status -eq 'Running') { 'OK' } else { 'Crit' })
        }
        $usbDefault = ($outInfo.Type -like 'USB*') -or ($inInfo.Type -like 'USB*')
        $uss = Get-UsbSelectiveSuspend
        $ussSt = if ($null -eq $uss) { 'NA' } elseif ($uss -eq 1 -and $usbDefault) { 'Warn' } elseif ($uss -eq 1) { 'Info' } else { 'OK' }
        Add-DiagItem $s 'Suspension sélective USB (secteur)' $(if ($null -eq $uss) { $null } elseif ($uss -eq 1) { 'Activée' } else { 'Désactivée' }) $ussSt $(if ($usbDefault) { 'Votre périphérique audio par défaut est en USB : activée, Windows peut mettre son port en veille (cause connue de coupures).' } else { 'Concerne surtout les périphériques audio USB.' })
        $dpc = @(); $int = @()
        for ($i = 0; $i -lt 5; $i++) {
            if (Test-DiagCancel $Ctx) { break }
            $p = Get-SafeCim Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'"
            if ($p) { $dpc += [double]$p.PercentDPCTime; $int += [double]$p.InterruptsPersec }
            Update-DiagProgress $Ctx (72 + 5 * $i)
            Start-Sleep -Milliseconds 1000
        }
        if ($dpc.Count) {
            $dAvg = [math]::Round(($dpc | Measure-Object -Average).Average, 2); $dMax = ($dpc | Measure-Object -Maximum).Maximum
            Add-DiagItem $s 'Temps CPU en DPC' ("moy. $dAvg % · max $dMax %") $(if ($dMax -ge 5) { 'Warn' } else { 'OK' }) 'Indicateur grossier des micro-coupures audio. Seul un outil comme LatencyMon mesure la latence par pilote.'
            Add-DiagItem $s 'Interruptions par seconde' ('{0:N0}' -f ($int | Measure-Object -Average).Average) 'Info'
        }
        $apps = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(FL64|FL|Ableton.*|reaper|Cubase.*|Studio One|bitwig.*|Discord|obs64|Voicemeeter.*|GoXLR.*|SteelSeriesGG.*|NahimicSvc.*|WavesSvc.*|Focusrite Control 2|SonarStudioService|EqualizerAPO.*)$' } | Select-Object -ExpandProperty ProcessName -Unique
        Add-DiagItem $s 'Logiciels audio ouverts' $(if ($apps) { $apps -join ', ' } else { 'Aucun parmi ceux surveillés' }) 'Info'
    }

    Update-DiagProgress $Ctx 100 'Terminé'
    $r
}

Export-ModuleMember -Function Invoke-AudioDiagnostic, Get-AudioEndpoints, Get-DefaultAudioEndpoint, Get-AudioDeviceInfo, Get-AsioDrivers, Get-UsbSelectiveSuspend
