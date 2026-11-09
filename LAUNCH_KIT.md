# LAUNCH_KIT — PC Toolkit v1.5.0

Textes prêts à publier (le script `launch-all.ps1` les copie dans le presse-papier et ouvre les pages). Avant de poster : relire, adapter le ton, joindre **`dist-launch/demo.gif`** (9 s, 1 Mo : média principal) ou, à défaut, une capture (`dist-launch/ui-dashboard.png`, `dist-launch/ui-presets.png`) et **respecter les règles d'auto-promotion de chaque communauté** (flair « Show & Tell » / « Project », pas de multi-posts le même jour, répondre aux commentaires).

- Repo : https://github.com/TxF-AI/PC-Toolkit
- Release : https://github.com/TxF-AI/PC-Toolkit/releases/tag/v1.5.0 (`PC-Toolkit-v1.5.0.zip`, 130 Ko)
- SHA-256 : `B17A4528575AAEA3EEF527F58BF1B5BA6E629F819B7C8E1C7BDDAB48FB6138B9`

> Rappels : PC Toolkit est en **PowerShell 5.1 + WPF** (pas Rust, pas Tauri) : ne pas poster sur r/rust. Ce n'est **pas un antivirus** (Security Guard est un audit léger) : ne jamais le présenter comme tel. Le zip n'est pas signé (SmartScreen). Les visuels de `dist-launch/` sont anonymisés (nom du PC et matériel remplacés) ; les mesures de charge sont réelles. Aucun chiffre de performance n'est annoncé : les gains se mesurent dans le Bilan avant/après de chacun.

---

## 1. Reddit — Show & Tell

**Subreddits :** `r/PowerShell` (lire les règles d'auto-promotion), `r/windows`, `r/programming` (lien vers le repo), `r/CoolGithubProjects`. Un subreddit par jour.

**Média :** joindre `dist-launch/demo.gif` (upload natif Reddit).

**Titre (au choix)**
- `I built a free PowerShell + WPF toolbox for Windows 10/11 (diagnostics, 1-click Game/Audio/Office presets, light security audit) - read-only by default, nothing sent online`
- `My Windows PC kept getting slower and I didn't know why, so I wrote PC Toolkit: a dark neon diagnostics & tuning tool in plain PowerShell`

**Corps**

Hi all,

I wanted one place to see what is going on with my Windows PC (hardware, network, storage, audio, startup items) and to tune it for gaming or music production, **without installing anything and without a tool that quietly changes my system**. So I wrote **PC Toolkit** in Windows PowerShell 5.1 + WPF.

**Principles**
- **Diagnostics are read-only.** Anything that modifies the system shows a preview, asks for explicit confirmation, and is logged.
- **No invented numbers**: what Windows doesn't expose shows "Non disponible".
- **No dependency, nothing to install** (portable `.cmd`, or an optional per-user installer with no admin rights). **Nothing is sent to the Internet** (apart from the pings/DNS of the network test).

**What it does**
- **Dashboard** with live CPU / RAM / disk gauges, and pages for hardware, network, Windows analysis, storage, audio, maintenance and startup items.
- **1-click presets: Game / Audio production (DAW) / Office**: power plan, temporary stop of secondary services, RAM cache, temp files, startup — with preview, confirmation and a **one-click "restore initial state"**. The audio preset never touches audio services.
- **Security Guard**: a *light* audit (Defender, firewall, UAC), suspicious startup entries / scheduled tasks, file or folder scan, **restorable quarantine** (nothing is ever deleted). It is **not an antivirus**: Windows Defender remains your protection.
- **Before/after report on 11 indicators** (freed space, RAM, services, startup programs, temp files, ghost audio devices, ...), exportable as HTML/TXT.
- UI in French or English (FR/EN switch, applied live), neon red/cyan theme, built-in console that shows what the app does in real time.

**Quality**: 165 Pester tests, MIT licensed. The release zip is not code-signed, so SmartScreen will warn; compare the hash.

**Download / verify**
https://github.com/TxF-AI/PC-Toolkit/releases/tag/v1.5.0
`SHA-256: B17A4528575AAEA3EEF527F58BF1B5BA6E629F819B7C8E1C7BDDAB48FB6138B9`

It was built with an AI pair programmer under strict rules (documented in the README). I'd love **feedback**: pages or indicators you'd want, presets that should (not) stop a given service, bugs on your setup. Issues and PRs welcome.

---

## 2. Hacker News — Show HN

**Titre**
`Show HN: PC Toolkit – Read-only Windows diagnostics and reversible tuning presets (PowerShell)`

**URL :** https://github.com/TxF-AI/PC-Toolkit

**Média :** HN n'héberge pas d'images : `dist-launch/demo.gif` n'est pas affiché ; ajouter dans le premier commentaire le lien `https://github.com/TxF-AI/PC-Toolkit/raw/main/dist-launch/demo.gif`.

**Premier commentaire**

Hi HN, author here.

PC Toolkit is a Windows 10/11 diagnostics and tuning toolbox written in Windows PowerShell 5.1 with a WPF UI (French or English, dark neon theme). I wrote it because most "optimizer" tools either do too much silently or need an installer, and I wanted something I could read in an evening.

Design choices:
- **Read-only by default.** Diagnostics only read. Every action that changes the system goes through preview → explicit confirmation (`-Confirmed`) → log entry, and the presets (Game / Audio / Office) store the previous state so "restore initial state" is one click.
- **Honesty about measurements.** If Windows doesn't expose a value, the UI says "Non disponible" instead of guessing. A before/after report measures 11 indicators around each cleanup so you can see what actually changed.
- **Security Guard is an audit, not an antivirus.** It looks at Defender / firewall / UAC state, suspicious startup entries and tasks, and can scan a file or folder (signature, SHA-256 against a known-files list, known malicious script patterns). Suspicious items are quarantined (restorable), never deleted.
- **No dependency, nothing sent online.** PowerShell + WPF only; the UI runs jobs in runspaces with a synchronized hashtable for progress/cancel.
- **Tests**: 165 Pester tests (Pester 3.4 syntax on stock Windows), including UTF-8 BOM and syntax checks on every script.
- A funny lesson: a function named like a persistence scanner made antivirus flag the source file itself, so detection functions have neutral names.

Caveats: the UI is bilingual FR/EN (Windows event-log messages stay in your Windows language), the zip is unsigned (SmartScreen; SHA-256 in the release), and it was written with an AI pair programmer under explicit rules (the README says so).

I'd love feedback on what a tool like this should refuse to touch.

---

## 3. X (Twitter) & LinkedIn

**Média à joindre :** `dist-launch/demo.gif` (X : GIF natif ; LinkedIn : ajouter comme image/GIF au post, 1er commentaire = lien du repo). En secours : `dist-launch/ui-dashboard.png` + `dist-launch/ui-presets.png`.

**X (≤ 280 caractères)**

```
My Windows PC felt slow and I had no idea why ⚡

So I built PC//TOOLKIT (PowerShell + WPF):
🔍 read-only diagnostics
🎮 reversible Game/DAW/Office presets
🛡️ light security audit

Free, MIT 👉 github.com/TxF-AI/PC-Toolkit
#PowerShell #OpenSource
```

**X (thread, 2ᵉ tweet)**
```
Rules I set: diagnostics are read-only, every change = preview + confirmation + log, no dependency, nothing sent online, and "Non disponible" instead of invented numbers. 165 Pester tests. It's NOT an antivirus. Feedback welcome 🙏
```

**LinkedIn (FR)**

```
⚡ J'ai codé une boîte à outils Windows en PowerShell — et je la publie en open source.

Mon PC ralentissait, je ne savais pas pourquoi, et je ne voulais pas d'un « optimiseur » qui modifie tout en silence ni d'un logiciel à installer.

PC//TOOLKIT (v1.5.0), en PowerShell 5.1 + WPF :
🔍 diagnostics en lecture seule : matériel, réseau, Windows, stockage, audio, démarrage
🎮 presets 1-clic Jeu / MAO / Bureautique, avec aperçu, confirmation et restauration en un clic
🛡️ Security Guard : audit léger et quarantaine restaurable (ce n'est pas un antivirus)
📊 bilan avant/après sur 11 indicateurs, exportable en HTML/TXT

Règles du produit : aucune mesure inventée (« Non disponible »), aucune dépendance, rien n'est envoyé sur Internet, 165 tests Pester, licence MIT. Développé avec un assistant IA sous des règles strictes, documentées dans le README.

👉 https://github.com/TxF-AI/PC-Toolkit

Quels réglages un tel outil devrait-il ne jamais toucher ? Vos retours m'intéressent.

#PowerShell #Windows #BuildInPublic #OpenSource #DevTools
```

**LinkedIn (EN, variante courte)**
```
Built a free Windows 10/11 toolbox in PowerShell + WPF: read-only diagnostics, reversible 1-click Game/DAW/Office presets, light security audit with restorable quarantine, before/after report. No dependency, nothing sent online, 165 tests, MIT.
github.com/TxF-AI/PC-Toolkit — feedback very welcome!
#PowerShell #BuildInPublic #OpenSource
```

---

## 4. Discord — #showcase

**Salons :** serveurs PowerShell, DevFR (salon projets), communautés Windows / MAO (pour le preset audio). Lire les règles avant de poster.

**Média :** joindre `dist-launch/demo.gif` directement dans le message.

**Message (EN)**
```
⚡ **PC//TOOLKIT** — a free PowerShell 5.1 + WPF toolbox for Windows 10/11
Read-only diagnostics (hardware, network, storage, audio, startup), reversible 1-click Game / DAW / Office presets, a *light* security audit with restorable quarantine (not an antivirus), and a before/after report. No dependency, nothing sent online, 165 Pester tests, MIT.
🔗 https://github.com/TxF-AI/PC-Toolkit
Feedback welcome — especially on what the presets should never touch! 🙏
```

**Message (FR, DevFR)**
```
⚡ **PC//TOOLKIT** — boîte à outils Windows 10/11 en PowerShell 5.1 + WPF
Diagnostics en lecture seule (matériel, réseau, stockage, audio, démarrage), presets 1-clic Jeu / MAO / Bureautique réversibles, audit de sécurité *léger* avec quarantaine restaurable (pas un antivirus) et bilan avant/après. Aucune dépendance, rien d'envoyé sur Internet, 165 tests Pester, MIT.
🔗 https://github.com/TxF-AI/PC-Toolkit
Vos retours sont les bienvenus (notamment sur ce que les presets ne doivent jamais toucher) !
```
