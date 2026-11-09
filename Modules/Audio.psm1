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
                Flow     = $(if ($flow -eq 'Render') { (Get-Text 'Aud.005') } else { (Get-Text 'Aud.006') })
                Name     = $p.$script:PKEY_Name
                Device   = $p.$script:PKEY_Adapter
                State    = switch ($state) { 1 { (Get-Text 'Aud.007') } 2 { (Get-Text 'Aud.008') } 4 { (Get-Text 'Aud.009') } 8 { (Get-Text 'Aud.010') } default { "$state" } }
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
    $ep = Get-AudioEndpoints | Where-Object { $_.Key -eq $key -and $_.Flow -eq $(if ($Flow -eq 'Render') { (Get-Text 'Aud.014') } else { (Get-Text 'Aud.015') }) } | Select-Object -First 1
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
    foreach ($view in @(@{ Key = 'HKLM:\SOFTWARE\ASIO'; Arch = (Get-Text 'Aud.023'); Cls = 'HKLM:\SOFTWARE\Classes\CLSID' },
                        @{ Key = 'HKLM:\SOFTWARE\WOW6432Node\ASIO'; Arch = (Get-Text 'Aud.024'); Cls = 'HKLM:\SOFTWARE\Classes\WOW6432Node\CLSID' })) {
        foreach ($k in Get-ChildItem $view.Key -ErrorAction SilentlyContinue) {
            $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
            $dll = (Get-ItemProperty (Join-Path $view.Cls "$($p.CLSID)\InprocServer32") -ErrorAction SilentlyContinue).'(default)'
            $exists = if ($dll) { Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($dll)) } else { $false }
            $out += [pscustomobject]@{ Nom = $k.PSChildName; Architecture = $view.Arch; Fichier = $dll; Présent = $(if ($exists) { Get-Text 'Core.Yes' } else { Get-Text 'Core.No' }) }
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

function Get-AudioTypeLabel {
    <# Libellé affiché d'un type de connexion (les valeurs internes du type restent en français : elles servent de repères au code). #>
    param([string]$Type)
    switch ($Type) {
        'Carte mère (HD Audio)'     { Get-Text 'Aud.TypeHD' }
        'Virtuel (logiciel)'        { Get-Text 'Aud.TypeVirtual' }
        'Autre'                     { Get-Text 'Aud.TypeOther' }
        'USB (pilote du fabricant)' { Get-Text 'Aud.TypeUsbVendor' }
        default                     { $Type }
    }
}

function Add-DefaultDeviceItems {
    <# Remplit une section avec la description d'un périphérique par défaut (sortie ou entrée). #>
    param($Section, $Endpoint, $Info, [string]$Kind)
    if (-not $Endpoint) { Add-DiagItem $Section (Get-Text 'Aud.025' $Kind) (Get-Text 'Aud.026') 'Warn' (Get-Text 'Aud.027'); return }
    Add-DiagItem $Section (Get-Text 'Aud.028' $Kind) ('{0} — {1}' -f $Endpoint.Name, $Endpoint.Device) 'OK'
    if ($Info) {
        Add-DiagItem $Section (Get-Text 'Aud.029') (Get-AudioTypeLabel $Info.Type) 'Info'
        Add-DiagItem $Section (Get-Text 'Aud.030') $Info.Status $(if ($Info.Status -eq 'OK') { 'OK' } else { 'Crit' })
        Add-DiagItem $Section (Get-Text 'Aud.031') ('{0} {1}' -f $Info.Provider, $Info.Driver).Trim() 'Info'
        switch ($Info.Type) {
            'Bluetooth' { Add-DiagItem $Section (Get-Text 'Aud.032') (Get-Text 'Aud.033') 'Info' (Get-Text 'Aud.034') }
            { $_ -like 'USB*' } {
                if ($Info.Hub) { Add-DiagItem $Section (Get-Text 'Aud.035') (Get-Text 'Aud.036' $($Info.Hub)) 'Warn' (Get-Text 'Aud.037') }
                else { Add-DiagItem $Section (Get-Text 'Aud.038') (Get-Text 'Aud.039') 'OK' }
            }
            'Virtuel (logiciel)' { Add-DiagItem $Section (Get-Text 'Aud.040') (Get-Text 'Aud.041') 'Info' (Get-Text 'Aud.042') }
        }
    }
    if ($Endpoint.Rate) { Add-DiagItem $Section (Get-Text 'Aud.043') ((Get-Text 'Aud.044') -f ($Endpoint.Rate / 1000), $Endpoint.Bits, $Endpoint.Channels) 'Info' }
}

function Invoke-AudioDiagnostic {
    param($Ctx)
    $r = New-DiagResult -Module (Get-Text 'Aud.045') -Title (Get-Text 'Aud.046') -Ctx $Ctx

    Update-DiagProgress $Ctx 5 (Get-Text 'Aud.047')
    $out = Get-DefaultAudioEndpoint 'Render'
    $in = Get-DefaultAudioEndpoint 'Capture'
    $outInfo = if ($out) { Get-AudioDeviceInfo $out.EndpointId }
    $inInfo = if ($in) { Get-AudioDeviceInfo $in.EndpointId }

    # --- Sortie / entrée par défaut ------------------------------------------------------
    Add-DiagSection $r (Get-Text 'Aud.050') -Body {
        param($s)
        Add-DefaultDeviceItems $s $out $outInfo (Get-Text 'Aud.051')
    }
    Update-DiagProgress $Ctx 20 (Get-Text 'Aud.052')
    Add-DiagSection $r (Get-Text 'Aud.053') -Body {
        param($s)
        Add-DefaultDeviceItems $s $in $inInfo (Get-Text 'Aud.054')
        # Même appareil en entrée et en sortie (interface, casque USB) : les fréquences doivent correspondre
        if ($out -and $in -and $outInfo -and $inInfo -and $outInfo.InstanceId -eq $inInfo.InstanceId -and $out.Rate -and $in.Rate) {
            if ($out.Rate -ne $in.Rate) {
                Add-DiagItem $s (Get-Text 'Aud.055') ((Get-Text 'Aud.056') -f ($out.Rate / 1000), ($in.Rate / 1000)) 'Warn' (Get-Text 'Aud.057')
            } else {
                Add-DiagItem $s (Get-Text 'Aud.058') ((Get-Text 'Aud.059') -f ($out.Rate / 1000)) 'OK'
            }
        }
    }

    # --- Tous les périphériques ------------------------------------------------------------
    Update-DiagProgress $Ctx 35 (Get-Text 'Aud.060')
    Add-DiagSection $r (Get-Text 'Aud.061') -Body {
        param($s)
        $eps = @(Get-AudioEndpoints)
        $active = @($eps | Where-Object State -eq (Get-Text 'Aud.062'))
        Add-DiagItem $s (Get-Text 'Aud.063') ((Get-Text 'Aud.064') -f @($active | Where-Object Flow -eq (Get-Text 'Aud.065')).Count, @($active | Where-Object Flow -eq (Get-Text 'Aud.066')).Count) 'Info'
        $duck = (Get-ItemProperty 'HKCU:\Software\Microsoft\Multimedia\Audio' -ErrorAction SilentlyContinue).UserDuckingPreference
        if ($null -ne $duck) { Add-DiagItem $s (Get-Text 'Aud.067') $(switch ($duck) { 0 { (Get-Text 'Aud.068') } 1 { (Get-Text 'Aud.069') } 2 { (Get-Text 'Aud.070') } 3 { (Get-Text 'Aud.071') } }) 'Info' (Get-Text 'Aud.072') }
        $defKeys = @($out.Key, $in.Key)
        $rows = $eps | Where-Object { $_.State -in (Get-Text 'Aud.073'), (Get-Text 'Aud.074') } | Sort-Object Flow, State, Name | ForEach-Object {
            [pscustomobject]@{ 'Par défaut' = $(if ($defKeys -contains $_.Key) { '★' } else { '' }); Type = $_.Flow; Nom = $_.Name; Appareil = $_.Device; État = $_.State; Fréquence = $(if ($_.Rate) { (Get-Text 'Aud.075') -f ($_.Rate / 1000) } else { '' }); Bits = $_.Bits; Canaux = $_.Channels }
        }
        Add-DiagTable $s (Get-Text 'Aud.076') $rows
        $snd = @(Get-SafeCim Win32_SoundDevice)
        $bad = @($snd | Where-Object Status -ne 'OK')
        Add-DiagItem $s (Get-Text 'Aud.077') ((Get-Text 'Aud.078') -f $snd.Count, $bad.Count) $(if ($bad.Count) { 'Warn' } else { 'OK' })
        Add-DiagTable $s (Get-Text 'Aud.079') ($snd | ForEach-Object { [pscustomobject]@{ Nom = $_.Name; Fabricant = $_.Manufacturer; État = $_.Status } })
    }

    # --- ASIO ----------------------------------------------------------------------------
    Update-DiagProgress $Ctx 55 (Get-Text 'Aud.080')
    Add-DiagSection $r (Get-Text 'Aud.081') -Body {
        param($s)
        $asio = @(Get-AsioDrivers)
        Add-DiagItem $s (Get-Text 'Aud.082') $asio.Count 'Info'
        $orph = @($asio | Where-Object Présent -eq (Get-Text 'Core.No'))
        if ($orph.Count) { Add-DiagItem $s (Get-Text 'Aud.083') (($orph.Nom) -join ', ') 'Warn' (Get-Text 'Aud.084') }
        if ($outInfo) {
            $brand = (($outInfo.Name, $out.Device) -join ' ' -split '[\s\(\)]+' | Where-Object { $_.Length -ge 4 -and $_ -notmatch '^(Audio|High|Definition|Device|USB|Speakers|Haut)' } | Select-Object -First 1)
            # À marque égale, on préfère le pilote qui correspond au branchement (USB, Thunderbolt…)
            $conn = if ($outInfo.Type -like 'USB*') { 'USB' } else { '' }
            $match = if ($brand) { $asio | Where-Object { $_.Nom -match [regex]::Escape($brand) -and $_.Présent -eq (Get-Text 'Core.Yes') } | Sort-Object { if ($conn -and $_.Nom -match $conn) { 0 } else { 1 } } | Select-Object -First 1 }
            if ($match) { Add-DiagItem $s (Get-Text 'Aud.085') $match.Nom 'OK' (Get-Text 'Aud.086') }
            elseif ($asio.Count) { Add-DiagItem $s (Get-Text 'Aud.087') (Get-Text 'Aud.088') 'Info' (Get-Text 'Aud.089') }
        }
        if ($asio.Count) { Add-DiagTable $s (Get-Text 'Aud.090') $asio } else { Add-DiagNote $s (Get-Text 'Aud.091') }
    }

    # --- Focusrite (seulement si présente) ------------------------------------------------
    $foc = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match 'Scarlett|Focusrite|Clarett|Vocaster' })
    $log = Join-Path $env:APPDATA 'Focusrite\Focusrite Control 2\fc2.log'
    if ($foc.Count -and (Test-Path -LiteralPath $log)) {
        Update-DiagProgress $Ctx 65 (Get-Text 'Aud.093')
        Add-DiagSection $r (Get-Text 'Aud.094') -Body {
            param($s)
            Add-DiagItem $s (Get-Text 'Aud.095') (($foc | Select-Object -First 1).FriendlyName) 'Info'
            $lines = Get-Content -LiteralPath $log -Tail 5000 -ErrorAction SilentlyContinue | Select-String -Pattern 'Device removed' -SimpleMatch
            $events = foreach ($l in $lines) {
                if ($l.Line -match '^(\d{1,2} \w{3} \d{4} \d{2}:\d{2}:\d{2})') {
                    $d = [datetime]::MinValue
                    if ([datetime]::TryParseExact($Matches[1], 'd MMM yyyy HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$d)) { $d }
                }
            }
            $events = @($events | Sort-Object -Descending)
            $recent = @($events | Where-Object { $_ -gt (Get-Date).AddDays(-14) })
            Add-DiagItem $s (Get-Text 'Aud.098') $recent.Count $(if ($recent.Count -ge 3) { 'Warn' } else { 'Info' }) (Get-Text 'Aud.099')
            if ($events) { Add-DiagTable $s (Get-Text 'Aud.100') ($events | Select-Object -First 10 | ForEach-Object { [pscustomobject]@{ Date = $_.ToString('ddd dd/MM/yyyy HH:mm:ss') } }) }
        }
    }

    # --- Système et latence -------------------------------------------------------------
    Update-DiagProgress $Ctx 72 (Get-Text 'Aud.102')
    Add-DiagSection $r (Get-Text 'Aud.103') -Body {
        param($s)
        foreach ($svcName in 'Audiosrv', 'AudioEndpointBuilder') {
            $svc = Get-Service $svcName -ErrorAction SilentlyContinue
            Add-DiagItem $s (Get-Text 'Aud.106' $svcName) "$($svc.Status)" $(if ($svc.Status -eq 'Running') { 'OK' } else { 'Crit' })
        }
        $usbDefault = ($outInfo.Type -like 'USB*') -or ($inInfo.Type -like 'USB*')
        $uss = Get-UsbSelectiveSuspend
        $ussSt = if ($null -eq $uss) { 'NA' } elseif ($uss -eq 1 -and $usbDefault) { 'Warn' } elseif ($uss -eq 1) { 'Info' } else { 'OK' }
        Add-DiagItem $s (Get-Text 'Aud.108') $(if ($null -eq $uss) { $null } elseif ($uss -eq 1) { (Get-Text 'Aud.109') } else { (Get-Text 'Aud.110') }) $ussSt $(if ($usbDefault) { (Get-Text 'Aud.111') } else { (Get-Text 'Aud.112') })
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
            Add-DiagItem $s (Get-Text 'Aud.114') ((Get-Text 'Aud.115' $dAvg $dMax)) $(if ($dMax -ge 5) { 'Warn' } else { 'OK' }) (Get-Text 'Aud.116')
            Add-DiagItem $s (Get-Text 'Aud.117') ('{0:N0}' -f ($int | Measure-Object -Average).Average) 'Info'
        }
        $apps = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(FL64|FL|Ableton.*|reaper|Cubase.*|Studio One|bitwig.*|Discord|obs64|Voicemeeter.*|GoXLR.*|SteelSeriesGG.*|NahimicSvc.*|WavesSvc.*|Focusrite Control 2|SonarStudioService|EqualizerAPO.*)$' } | Select-Object -ExpandProperty ProcessName -Unique
        Add-DiagItem $s (Get-Text 'Aud.118') $(if ($apps) { $apps -join ', ' } else { (Get-Text 'Aud.119') }) 'Info'
    }

    Update-DiagProgress $Ctx 100 (Get-Text 'Aud.120')
    $r
}

Export-ModuleMember -Function Get-AudioTypeLabel, Invoke-AudioDiagnostic, Get-AudioEndpoints, Get-DefaultAudioEndpoint, Get-AudioDeviceInfo, Get-AsioDrivers, Get-UsbSelectiveSuspend
