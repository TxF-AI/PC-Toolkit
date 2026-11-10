# What's new

🇫🇷 [Version française](CHANGELOG.fr.md)

## 1.7.1 (2026-11-10)

**English mode: remaining French removed**
- **Numbers** follow the interface language: in English, `32.0 GB` and `44.1 kHz` instead of `32,0` and `44,1` on a French Windows.
- **Power mode**: the four standard Windows plans are shown with their English name (for example `High performance`).
- **Section error** label and the **administrator console** that resets the data-usage counters are now translated.
- Names that come from Windows itself (audio devices, event-log messages) stay in the language of Windows: nothing is invented.

## 1.7.0 (2026-11-10)

**Copy AI diagnostic prompt**
- New **AI** button next to HTML and TXT: it copies to the clipboard a Markdown summary of the diagnostic on screen, keeping only the critical and warning items (by section), followed by a ready-made question for an AI assistant (Claude Code, Cursor…).
- The PC name and the Windows user name are masked (`<pc>`, `<user>`). Nothing is sent over the Internet: the text only goes to your clipboard.
- `Format-DiagAiPrompt` in `Modules\Core.psm1`; 167 Pester tests.

## 1.6.0 (2026-11-10)

**Bilingual interface, French / English** (2026-11-09)
- **FR / EN** selector at the bottom of the sidebar, applied live (no restart). The choice is remembered in `Data\language.json` (never versioned); by default, the Windows language.
- Everything is translated: menus, pages, diagnostics, findings and recommendations, presets, Security Guard, report, console, HTML / TXT exports, installer and uninstaller.
- `Modules\I18n.psm1` (`Get-Text`, `Set-AppLanguage`) and the `Lang\fr.psd1` / `Lang\en.psd1` dictionaries. A missing key never crashes: it falls back to French, then to the key itself.
- Limits: results already saved in the history keep the language they were produced in; Windows event log messages, device names and power plan names stay in the Windows language; the administrator console "Reset data counters (SRUM)" stays in French.
- Tests: 166 (including FR/EN dictionary parity, `{0}` placeholders, no French in the English dictionary, English exports).

**Documentation and fix** (2026-11-10)
- README, CONTRIBUTING and issue templates are in English by default; French versions in `README.fr.md` and `CONTRIBUTING.fr.md`.
- English demo GIF and screenshots (`dist-launch/`); French versions in `*.fr.*`.
- Fix: `Get-Text` ignored a single `$false` or `0` argument (the console showed "admin={0}"). Test added.

## 1.5.0 (2026-11-09)

**Modernized interface (neon red and cyan)**
- Dashboard: live animated gauges for processor, memory and C: disk (cyan, orange at 70%, red at 90%), refreshed every second.
- Smooth transitions between tabs (fade and slide), animated progress bars during scans and cleanups, neon glow on titles and gauges.
- Built-in console at the bottom of the window: actions, warnings and errors in real time (today's log), with "Clear" and "Collapse" buttons.

**One-click optimization presets** (Performance Mode page)
- **Game**: Ultimate / High performance plan, temporary stop of 7 secondary services, RAM cache flush, cleanup of temporary files and startup.
- **Music production**: high performance plan, temporary stop of secondary services (Windows Update and SysMain included, sources of latency spikes), startup cleanup. RAM is deliberately not flushed (loaded samples and plugins stay in memory). Audio services are never touched.
- **Office**: plan kept, 4 unneeded services stopped (telemetry, maps, fax, remote registry), temporary files cleanup.
- Detailed preview and confirmation before applying; state saved and "Restore initial state" in one click. Everything runs in the background with a progress bar.

**Security Guard** (new page, light audit: not an antivirus)
- System audit: Windows Defender service and real-time protection, virus definition age, firewall (3 profiles), User Account Control (UAC).
- Suspicious items: active startup programs, non-Microsoft scheduled tasks, executables and scripts at the root of Temp, AppData and Public. Clues flagged: unsigned or invalid signature, double extension, right-to-left override character, Windows process name outside the Windows folder, encoded or code-downloading commands.
- File or folder scan: signature, SHA-256 hash compared with a list of known files, known malicious script patterns.
- Safe quarantine (`Data\Quarantine\`): file moved under a neutralized name, task or startup entry disabled, never deleted; one-click restore. Guardrails: the Windows folder, PC Toolkit files, Microsoft tasks and the startup allow-list are never touched. Confirmation and log for every action.
- Results can be exported as HTML and TXT.

**Before/after report**
- 3 new indicators (11 in total): active suspicious items, threats in quarantine, active optimization profile. They also appear in the TXT and HTML exports.
- A Security Guard neutralization updates the report without leaving the page.

**Technical**
- New `SecurityGuard.psm1` and `Tuning.psm1` modules. `Enable-GameMode` accepts a service list, a "keep plan" option and a profile name.
- The name `Invoke-PersistenceScan` triggered the antivirus on the source code itself: detection functions now have neutral names.

## 1.4.0 (2026-11-09)

**Automatic startup cleanup**
- "Automatically optimize startup" button (Startup page): disables unneeded programs (Google, Adobe, Java and Edge updaters; Spotify, Discord, Steam, Skype, Teams, OneDrive, CyberLink, game launchers; telemetry agents). The list is shown and confirmation is required before any action.
- **Absolute allow-list**: graphics drivers (NVIDIA, AMD, Intel), audio (Realtek, Waves, ASIO, audio interfaces), security (Defender, antivirus, anti-cheat) and system utilities are never disabled, even if their name looks like a target. An unknown program is never touched.
- Disabled through the native Windows mechanism (`StartupApproved`): no key or shortcut is deleted. The initial state is saved in `Data\StartupBackup.json`; "Restore backup" puts every program back exactly as before.
- The page lists the automatically disabled programs with their status.
- The before/after report now counts purged "Startup programs" (8 indicators), including in TXT and HTML exports.

## 1.3.0 (2026-11-09)

**Startup**
- New "Startup" page: programs launched with Windows (user and system Run keys, Startup folders) with name, path, source and Enabled / Disabled status.
- One-click disable and re-enable (after confirmation) through the native Windows mechanism (the one used by Task Manager): no key or shortcut is deleted or moved. "System" programs require administrator mode.

**Performance Mode**
- New "Performance Mode" page: saves the power plan and services, switches to Ultimate / High performance, temporarily stops 7 secondary services (Spooler, SysMain, wuauserv, DiagTrack, MapsBroker, Fax, RemoteRegistry) if they are running, optional RAM cache flush (offered at each activation).
- "Restore initial state" puts back the original plan and restarts the stopped services. The state is kept in `Data\GameMode.json`: restoring remains possible after closing the application. Administrator required.
- The gain (available RAM, services stopped) automatically appears in the before/after report.

## 1.2.0 (2026-11-09)

**Before/after report**
- The PC state is measured silently at the start of each diagnostic. At the end of a confirmed cleanup in Maintenance (temporary files, recycle bin, recent files, incomplete downloads), the final state is measured and the table `INDICATOR | BEFORE | AFTER | GAIN / NET` is shown in the new "Before/after report" page.
- Measures: free space on C:, RAM used (% and GB) and available (MB), running services, processes, phantom audio devices, temporary files + recycle bin. An unavailable measure shows "Not available".
- The report is automatically appended to the end of the HTML and TXT exports. Everything stays in memory (no file is created). Two buttons also allow a manual measurement (privacy script, audio cleanup…).

**Tools (outside the application, not included in the zip)**
- `Outils\Confidentialite-Debloat-Win11.ps1`: Windows 11 privacy optimization, to run as administrator. Turns off telemetry and ad tracking, disables Bing and Cortana in search, Widgets and suggestions, and removes unneeded preinstalled apps. Preview before any change, restore point and backup of the old settings (`-Restaurer` to roll back).

## 1.1.0 (2026-11-09)

**Sharing**
- Version number shown in the sidebar, the window title and every report.
- PC Toolkit appears in **Settings > Installed apps** and can be uninstalled from Windows (confirmation, history kept as you choose).
- The zip ships with its SHA-256 hash to check it has not been modified.

**Reports**
- **TXT** export in addition to HTML, opening directly in Notepad.

**Audio**
- Universal diagnostic: adapts to the default output and microphone (Realtek, USB DAC or interface, Bluetooth, HDMI, GoXLR, virtual).

**Maintenance**
- Reset of network data usage counters (SRUM), with a backup of the old database.
- Cleanup of recent files and jump lists, incomplete downloads and the recycle bin, with a preview before deletion.

**Fixes**
- A single list of Windows end-of-support dates, shared by the Dashboard and the Windows page.

## 1.0.0

- First version: Dashboard, Hardware, Network, Windows, Storage, Audio, Maintenance and History.
