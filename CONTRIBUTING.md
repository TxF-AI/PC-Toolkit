# Contributing to PC Toolkit

🇫🇷 [Version française](CONTRIBUTING.fr.md)

Thanks for your interest! A few simple rules keep every contribution safe and easy to review.

## Before you start
- Open an **issue** first (bug or idea) to discuss it, especially for a new feature.
- Environment: **Windows 10/11**, **Windows PowerShell 5.1** (not PowerShell 7), Pester 3.4 (shipped with Windows).

## Project structure
```
PCToolkit.ps1        WPF interface: pages, background jobs (runspace), gauges, console
UI\MainWindow.xaml   interface design
Modules\Core.psm1    result model (New-DiagResult / Add-DiagSection / Add-DiagItem), log, HTML/TXT exports
Modules\*.psm1       one module per page: Dashboard, Hardware, Network, WindowsAnalysis, Storage, Audio,
                     Maintenance, Performance (startup, Performance Mode), Tuning (presets),
                     SecurityGuard (audit, scan, quarantine), Bilan (before/after)
Modules\I18n.psm1    FR/EN texts (Get-Text); dictionaries in Lang\fr.psd1 and Lang\en.psd1
Tests\               Pester suite (PCToolkit.Tests.ps1)
Run-Tests.ps1        runs the suite; Build-Zip.ps1 builds the distribution zip
Installer.ps1 / Desinstaller.ps1   per-user install and uninstall
VERSION              the only source of the version number
```

## Product rules (non-negotiable)
- **Diagnostics are read-only.** Any action that changes the system must show a preview, require explicit confirmation (`-Confirmed`), then write to the log (`Write-AppLog ... 'ACTION'`).
- **Never invent a measurement**: what Windows does not expose is shown as "Not available".
- **No external dependency**, nothing to install, nothing sent over the Internet (except the network test's pings/DNS).
- **Never change or bypass Windows security settings** (UAC, Defender, firewall).
- The interface must never crash on a module error: handle errors.
- Interface and messages are **in French and English** (FR/EN selector). Every visible text goes through `Get-Text`; a new key is added to **both** `Lang\fr.psd1` and `Lang\en.psd1` (the tests require the same keys and the same `{0}`, `{1}` placeholders).

## PowerShell 5.1 pitfalls
- `.ps1` / `.psm1` files must be **UTF-8 with BOM**, otherwise accents break.
- A function that returns a single item "unrolls" it: wrap the call in `@()`.
- Variables are case-insensitive; do not name a variable `$args`, `$input` or `$error`.
- Function names must be unique across modules.
- Never name a function `Invoke-Persistence…`: some antivirus products block the file. Tests that write malware patterns must build them in pieces.

## Tests
Pester 3.4: use `Should Be`, `Should Throw` (not `Should -Be`).

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Run-Tests.ps1
```

The exit code is the number of failed tests (`0` = all good). Add or adapt tests for every behavior change, and run the suite before opening a pull request. CI (GitHub Actions) runs it again automatically.

## Proposing a change
1. Fork the repository and create a branch from `main` (`feat/...`, `fix/...`, `docs/...`).
2. Keep changes focused: one pull request = one topic.
3. Update `CHANGELOG.md` (and `CHANGELOG.fr.md`); `VERSION` is the only source of the version number.
4. Commit messages use `type(scope): description` (`feat`, `fix`, `docs`, `test`, `chore`).
5. Open the pull request describing what changes, why, and how you tested it.

Never commit `Data\` or `Reports\`: they hold the user's personal data.

## Reporting a security issue
Do not post it in a public issue: contact the maintainer privately through the repository's GitHub profile.

## License
By contributing, you agree that your code is released under the [MIT](LICENSE) license.
