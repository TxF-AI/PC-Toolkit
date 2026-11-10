# ⚡ PC//TOOLKIT — maintenance and diagnostics

🇫🇷 [Version française](https://github.com/TxF-AI/PC-Toolkit/blob/main/README.fr.md)

[![CI](https://github.com/TxF-AI/PC-Toolkit/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/TxF-AI/PC-Toolkit/actions/workflows/ci.yml)
![Version](https://img.shields.io/badge/version-v1.6.0-FF2A4D)
![Pester tests](https://img.shields.io/badge/Pester%20tests-166%2F166%20passing-brightgreen)
![License](https://img.shields.io/badge/license-MIT-22E5FF)
![Compatibility](https://img.shields.io/badge/PowerShell-5.1%2B%20%7C%20Windows%2010%20%26%2011-blue)

A diagnostics and optimization toolbox for Windows 10/11: hardware, network, Windows, storage, audio, maintenance and security.
Dark interface with neon red and cyan accents. **The interface is available in English and French** (FR / EN switch in the sidebar, applied live; the default follows your Windows language). **Nothing to install**: Windows is enough. Nothing is sent over the Internet.

## Highlights

- **Cyberpunk interface**: live CPU / RAM / C: disk gauges, neon glow, animated transitions and progress bars, built-in log console at the bottom of the window.
- **Security Guard**: a light audit of Windows Defender, the firewall and UAC; search for suspicious items (startup, scheduled tasks, Temp/AppData folders); file or folder scan; **restorable quarantine**. It is **not** an antivirus: Windows Defender remains your protection.
- **1-click Game / DAW (music production) / Office presets**: power plan, temporarily stopped secondary services, RAM cache, temp files and startup, with preview, confirmation and **one-click restore**. The DAW preset keeps RAM untouched and never touches audio services.
- **Controlled cleanup**: temp files, recycle bin, DNS cache, and automatic startup cleanup with a whitelist (graphics and audio drivers, security, anti-cheat); nothing is deleted, everything can be restored.
- **Before/after report on 11 indicators**: freed space, RAM, services, processes, startup programs, temp files, ghost audio devices, active suspicious items, quarantined threats, optimization profile… exportable as HTML and TXT.
- **Safe by design**: read-only diagnostics, preview then confirmation before any change, no invented measurement ("Non disponible" = "Not available"), no dependency.

## Quick start

1. **Extract the zip**: right-click `PC-Toolkit-v<version>.zip` > **Extract All…**
   (do not run it directly from inside the zip).
2. Pick one of the two ways to use it:

| | How | For whom |
|---|---|---|
| **Portable** | Double-click **`Lancer PC Toolkit.cmd`** | Try it without installing anything, or run it from a USB drive |
| **Installed** | Double-click **`Installer.cmd`** | Frequent use: **⚡ PC∕∕TOOLKIT** shortcuts on the Desktop and in the Start menu |

The installer copies the app to `%LocalAppData%\PCToolkit` and adds it to **Settings > Installed apps**. It needs no administrator rights and adds nothing to Windows startup.
To update, run `Installer.cmd` from the new version: your history is kept.
The installed version is shown at the bottom of the sidebar and in every report.

### If Windows shows a warning (SmartScreen)
PC Toolkit is not digitally signed (a certificate costs several hundred euros per year), so Windows treats it as an unknown file from the Internet. This is normal.
- **Before extracting**, right-click the zip > **Properties** > tick **Unblock** > OK. No warning afterwards.
- Or, in PowerShell, after extraction (or on the zip before extracting it):
  ```powershell
  Get-ChildItem -Path "C:\path\to\PC Toolkit" -Recurse | Unblock-File
  # or, for the zip only:
  Unblock-File -Path .\PC-Toolkit-v1.6.0.zip
  ```
- If the blue "Windows protected your PC" screen appears: click **More info** > **Run anyway**.
- All the code is readable: they are text files (`.ps1`, `.psm1`, `.xaml`) that you can open in Notepad before running anything.

### Unsigned scripts and the execution policy
PC Toolkit is a set of **unsigned** PowerShell scripts. Windows applies two separate protections:

- **SmartScreen / "Mark of the Web"**: a downloaded file gets an "from the Internet" mark, hence the warning. It is removed with `Unblock-File`:
  ```powershell
  Unblock-File -Path .\PC-Toolkit-v1.6.0.zip
  ```
  Do this **before** extracting the zip (or on the extracted folder with `Get-ChildItem -Recurse | Unblock-File`).
- **PowerShell execution policy**: on some PCs, scripts are blocked ("running scripts is disabled on this system"). `Lancer PC Toolkit.cmd` bypasses this for its own session. If you run the scripts by hand from PowerShell, allow them for the **current window only** (nothing is changed permanently):
  ```powershell
  Set-ExecutionPolicy RemoteSigned -Scope Process
  ```

These commands touch neither Windows Defender nor the system security settings.

### Check that the zip has not been modified
The `PC-Toolkit-v<version>.zip.sha256.txt` file shipped with the zip contains its hash. In PowerShell, in the zip's folder:
```
Get-FileHash .\PC-Toolkit-v<version>.zip
```
Both strings of digits and letters must be identical. Otherwise the file was modified or damaged during transfer: do not use it.

## What the app does

Page names below are the English labels; switch to French with the **FR / EN** selector at the bottom of the sidebar. Reports (HTML / TXT) follow the language selected at export time. Results already saved in the history stay in the language they were produced in, and Windows event-log messages are shown in your Windows language.

| Page | Content |
|---|---|
| Dashboard (*Tableau de bord*) | **Live gauges** (CPU, RAM, C: disk), then a 10-second overview: graphics driver, ping, critical events, points of attention. Built-in log console at the bottom of the window (actions in real time) |
| Hardware (*Matériel*) | Processor, memory (XMP, dual channel), graphics card, BIOS, temperatures that are actually exposed |
| Network (*Réseau*) | Connection, DNS and DoH, latency, jitter, packet loss, DNS speed |
| Windows | Version and end of support, crashes, blue screens, logs, services, startup, security |
| Storage (*Stockage*) | Free space, disk health, large folders, large files |
| Audio | Your **default** output and microphone, whatever they are: onboard sound (Realtek…), USB DAC or interface, Bluetooth headset, HDMI, GoXLR, virtual device. Connection type, driver, sample rates, ASIO, USB suspend, indicative latency |
| Maintenance | Temp files, recycle bin, DNS cache, SFC, DISM, CHKDSK, restore point |
| History and privacy (*Historique et confidentialité*) | Recent files and jump lists, unfinished downloads, reset of the network data counters (SRUM) |
| Startup (*Démarrage*) | Programs launched with Windows (Run keys, Startup folders): one-click enable / disable, automatic optimization with a whitelist (drivers, audio, security) and one-click restore; nothing is deleted |
| Performance Mode (*Mode Performance*) | **1-click Game / DAW / Office presets** (power plan, secondary services, RAM cache, temp files, startup) or manual Performance Mode; one-click restore (administrator required for the power plan and services) |
| Security Guard | Light audit (**not an antivirus**): Windows Defender and firewall state, suspicious startup items (Run keys, scheduled tasks, Temp/AppData folders), file or folder scan (signature, double extension, known hashes, known malicious scripts). Quarantine or disable after confirmation, restore possible; nothing is deleted |
| Before/after report (*Bilan avant/après*) | Baseline taken at the start of the diagnostic, comparison table at the end of cleanups (freed space, RAM, services, processes, startup programs, temp files, ghost audio devices). Kept in memory; appended to the end of HTML and TXT exports |
| History (*Historique*) | Saved diagnostics, export as an HTML or TXT report |

### Reports
Every diagnostic can be exported as **HTML**, formatted for the browser, or as **TXT**, plain text that is easy to paste on Discord or a forum.
The **"Open the TXT in Notepad"** checkbox opens the report directly. When unchecked, it simply selects the file in Explorer.

### Network data counters
The tool resets Windows' **SRUM** database: per-app data usage, the Task Manager "App history" and, on a laptop, battery history.
- The old database is not deleted: it is moved to `C:\Windows\System32\sru.sauvegarde-<date>`.
- The `netsh int ip reset` command is **not** used: it resets the whole network configuration (DNS, static IPs) without resetting the counters.

## Safety

- **Diagnostics change nothing**: they only read.
- Every maintenance action explains what it will do and waits for your **Yes** before acting.
- System tools (SFC, DISM, CHKDSK) open in a visible window, after Windows authorization.
- No measurement is invented: what Windows does not expose shows "Not available" ("Non disponible" in French).
- Nothing is sent over the Internet, apart from the pings and DNS queries of the network test.
- **Security Guard never deletes anything**: a suspicious file is moved to `Data\Quarantine` (restorable), a task or startup entry is only disabled. Its findings are clues, not verdicts; Windows Defender remains your protection.
- The **Relaunch as administrator** button is optional: it only lets the app read more information (SMART health, disk temperatures).

## Uninstall

- **Portable version**: simply delete the folder.
- **Installed version**: **Settings > Apps > Installed apps > PC Toolkit > Uninstall**.
  Uninstalling asks for confirmation, offers to keep your history, then removes the shortcuts, the Windows entry and the `%LocalAppData%\PCToolkit` folder.

## Files

```
PC Toolkit\
├─ Lancer PC Toolkit.cmd      portable launcher
├─ Installer.cmd / .ps1       installer (copy + shortcuts + Windows entry)
├─ Desinstaller.ps1           uninstaller
├─ PCToolkit.ps1              application (interface)
├─ VERSION                    version number (single source)
├─ CHANGELOG.md               what's new in each version
├─ LICENSE                    MIT license
├─ app.ico                    icon
├─ UI\MainWindow.xaml         interface design
├─ Modules\*.psm1             one module per diagnostic + Core (shared base) + I18n (languages)
├─ Lang\fr.psd1, en.psd1      interface texts, French and English
├─ Data\                      history, logs and language choice (created on use)
└─ Reports\                   exported HTML and TXT reports (created on use)
```

## Troubleshooting

- **Nothing opens**: open PowerShell in the folder and run
  `powershell -ExecutionPolicy Bypass -NoProfile -File .\PCToolkit.ps1` to see the error message.
- Technical errors are logged in `Data\Logs`.
- Requirements: Windows 10 or 11, with Windows PowerShell 5.1 (included in Windows).

## Running the tests

The suite uses Pester 3.4 (shipped with Windows); from the root of the cloned repository:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Run-Tests.ps1
```

The exit code is the number of failing tests (`0` = all good). The distribution zip does not contain the tests: they live in the Git repository. Continuous integration (GitHub Actions) reruns them on every `push` and `pull_request` to `main`.

## Methodology & AI pair programming

PC Toolkit is developed as a **human / AI pair**:

- **Project direction (TxF-AI)**: the specification of each version, architecture choices (WPF interface, one PowerShell module per page, background jobs), non-negotiable safety rules (read-only diagnostics, preview then confirmation before any change, backup and restore, no invented measurement, no dependency), review and validation of the results, tests on real PCs, CI/CD and release setup.
- **Development assistant (Claude Code, Anthropic)**: used as a *Senior Pair Programmer* to prototype fast and write most of the code, the **166 Pester tests** and the documentation, under that direction and those guardrails.

This way of working is a deliberate choice: every change goes through the test suite (`Run-Tests.ps1`), through the GitHub Actions CI and, for system actions, through a real test as administrator before delivery.

## Contributing

Contributions are welcome: read [CONTRIBUTING.md](CONTRIBUTING.md) (product rules, PowerShell 5.1 pitfalls, tests), then open an issue using the *Bug report* or *Feature request* templates.

## License

[MIT](LICENSE) © 2026 TxF-AI. Provided "as is", without warranty: read each action's preview before confirming.
