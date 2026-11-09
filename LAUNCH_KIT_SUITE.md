# LAUNCH_KIT_SUITE — « Suite Doctor & Windows Toolkit »

Lancement groupé des 3 projets (utilisé par l'option [4] de `launch-all.ps1`). Mêmes règles que les kits individuels : relire, adapter, respecter les règles d'auto-promotion, répondre aux commentaires.

| Projet | Repo | Média |
|---|---|---|
| DevEnv Doctor v0.2.0 (Rust + Tauri v2) | https://github.com/TxF-AI/devenv-doctor | `devenv-doctor/assets/demo.gif` |
| PortDoctor v0.1.0 (Rust + Tauri v2) | https://github.com/TxF-AI/port-doctor | `port-doctor/assets/demo.gif` |
| PC Toolkit v1.5.0 (PowerShell + WPF) | https://github.com/TxF-AI/PC-Toolkit | `PC Toolkit/dist-launch/demo.gif` |

> Réalité à ne pas déformer : ce sont **3 outils indépendants** (pas un installateur commun), publiés sous licence MIT. Les deux « Doctor » sont des exécutables portables de 4,5 et 4,3 Mo, non signés (SmartScreen) ; PC Toolkit est un zip de 130 Ko. Aucun chiffre de RAM n'est annoncé (non mesuré en release). Hacker News préfère **un projet par Show HN** : pour la suite, soumettre plutôt le projet principal et citer les deux autres dans le premier commentaire.

---

## 1. Reddit — Show & Tell

**Subreddits :** `r/windows`, `r/programming` (lien), `r/CoolGithubProjects` ; `r/rust` seulement si le post insiste sur les deux outils Rust. Un subreddit par jour.

**Média :** joindre le GIF du projet principal (jusqu'à 3 médias selon le subreddit : les trois `demo.gif`).

**Titre (au choix)**
- `I built 3 free, open-source Windows tools for developers & power users: a PATH cleaner, a port killer (EADDRINUSE) and a PowerShell toolbox`
- `Tired of Windows chores (dead PATH entries, ports stuck on 3000, slow PC), I wrote a small suite of safe, local-only tools`

**Corps**

Hi all,

Over the last weeks I built three small Windows tools that share the same philosophy: **local-only, preview before any change, backups or restore, no telemetry, MIT**.

1. **DevEnv Doctor** (Rust + Tauri v2, 4.5 MB portable exe): cleans your Windows `PATH`: orphan and duplicate entries, version conflicts (which `python.exe` really runs?), a length compressor, diff preview, automatic JSON backup and one-click restore. https://github.com/TxF-AI/devenv-doctor
2. **PortDoctor** (Rust + Tauri v2, 4.3 MB, system tray): lists listening ports and frees them in one click, **Smart Kill** of whole `npm → node` process trees, WSL2 / Docker labels, Hyper-V reserved-range alerts, with system processes locked. https://github.com/TxF-AI/port-doctor
3. **PC Toolkit** (PowerShell 5.1 + WPF): read-only diagnostics, reversible 1-click Game / Audio / Office presets, a light security audit (not an antivirus) and a before/after report. https://github.com/TxF-AI/PC-Toolkit

The binaries are not code-signed (SmartScreen will warn), so every release page lists a SHA-256 to compare. They were written with an AI pair programmer under strict rules, documented in the repos.

I'd really like **feedback**: which of the three is useful to you, what they should never touch, and bugs on your setup. Issues and PRs welcome.

---

## 2. Hacker News — Show HN

**Titre**
`Show HN: Doctor suite – Small safe Windows dev tools (PATH cleaner, port killer, toolbox)`

**URL :** https://github.com/TxF-AI?tab=repositories

**Média :** HN n'héberge pas d'images ; mettre les liens des GIFs dans le premier commentaire (`https://github.com/TxF-AI/devenv-doctor/raw/main/assets/demo.gif`, `https://github.com/TxF-AI/port-doctor/raw/main/assets/demo.gif`, `https://github.com/TxF-AI/PC-Toolkit/raw/main/dist-launch/demo.gif`).

**Premier commentaire**

Hi HN, author here. These are three independent, MIT-licensed Windows utilities with the same safety rules: everything is local, destructive actions show a preview first, and there is a way back (backups / restore / guardrails).

- **DevEnv Doctor** (Rust + Tauri v2): reads the PATH straight from `HKCU`/`HKLM`, keeps `REG_SZ` vs `REG_EXPAND_SZ` right, only compresses entries when strictly shorter, checks rights before the first write, backs up as JSON.
- **PortDoctor** (Rust + Tauri v2): `EADDRINUSE` fixer in the tray. The backend re-scans before every kill, refuses system processes, itself and its own ancestors, and computes process trees so a respawning `npm` parent doesn't undo the kill.
- **PC Toolkit** (PowerShell 5.1 + WPF): read-only diagnostics, reversible tuning presets, light security audit with restorable quarantine, before/after report.

Repos: https://github.com/TxF-AI/devenv-doctor , https://github.com/TxF-AI/port-doctor , https://github.com/TxF-AI/PC-Toolkit

Caveats: Windows only, unsigned binaries (SHA-256 on each release), memory use not benchmarked, built with an AI pair programmer under explicit rules. Feedback on what such tools should refuse to touch is very welcome.

---

## 3. X (Twitter) & LinkedIn

**Média à joindre :** les `demo.gif` des trois projets (X accepte jusqu'à 4 médias ; un GIF seul par post). Secours : une capture par projet.

**X (≤ 280 caractères)**

```
3 free Windows tools I built, all local & reversible 🩺🔌⚡

🩺 DevEnv Doctor: clean your PATH
🔌 PortDoctor: free stuck ports
⚡ PC Toolkit: safe diagnostics & tuning

Rust/Tauri + PowerShell, MIT
github.com/TxF-AI
#RustLang #PowerShell #OpenSource
```

**X (thread, 2ᵉ tweet)**
```
Same rules everywhere: preview before any change, backup or restore, system processes locked, no telemetry. Unsigned binaries, SHA-256 on every release. DevEnv Doctor 👉 github.com/TxF-AI/devenv-doctor PortDoctor 👉 github.com/TxF-AI/port-doctor PC Toolkit 👉 github.com/TxF-AI/PC-Toolkit
```

**LinkedIn (FR)**

```
🧰 3 outils Windows open source, 3 douleurs du quotidien de dev — avec les mêmes règles : tout est local, aperçu avant toute modification, retour arrière possible.

🩺 DevEnv Doctor (Rust + Tauri v2) — nettoie le PATH : orphelins, doublons, conflits de version, compression, sauvegarde et restauration en un clic.
🔌 PortDoctor (Rust + Tauri v2) — libère les ports bloqués (EADDRINUSE) depuis la zone de notification, Smart Kill de l'arbre npm → node, repérage WSL2/Docker/Hyper-V, processus système verrouillés.
⚡ PC Toolkit (PowerShell + WPF) — diagnostics en lecture seule, presets Jeu / MAO / Bureautique réversibles, audit de sécurité léger, bilan avant/après.

Licence MIT, aucune télémétrie, développés avec un assistant IA sous des règles strictes documentées dans les dépôts.

👉 https://github.com/TxF-AI/devenv-doctor
👉 https://github.com/TxF-AI/port-doctor
👉 https://github.com/TxF-AI/PC-Toolkit

Lequel vous serait le plus utile, et que devraient-ils ne jamais toucher ?

#RustLang #Tauri #PowerShell #BuildInPublic #OpenSource #Windows
```

**LinkedIn (EN, variante courte)**
```
Three free, MIT-licensed Windows tools with the same safety rules (local-only, preview first, way back): DevEnv Doctor (PATH cleaner), PortDoctor (port killer with process trees), PC Toolkit (PowerShell diagnostics & tuning presets).
github.com/TxF-AI — feedback very welcome!
#RustLang #Tauri #PowerShell #BuildInPublic #OpenSource
```

---

## 4. Discord — #showcase

**Salons :** Discord officiel Tauri (pour les deux outils Rust), PowerShell, DevFR. Adapter : ne présenter que les outils pertinents pour la communauté. Lire les règles avant de poster.

**Média :** joindre les `demo.gif` des projets pertinents.

**Message (EN)**
```
🧰 **Doctor suite** — 3 free Windows tools, local-only, preview-first, MIT
🩺 DevEnv Doctor (Tauri v2): safe PATH cleaner → https://github.com/TxF-AI/devenv-doctor
🔌 PortDoctor (Tauri v2): free stuck ports, Smart Kill of process trees → https://github.com/TxF-AI/port-doctor
⚡ PC Toolkit (PowerShell + WPF): read-only diagnostics & reversible tuning presets → https://github.com/TxF-AI/PC-Toolkit
Feedback welcome! 🙏
```

**Message (FR, DevFR)**
```
🧰 **Suite Doctor & Windows Toolkit** — 3 outils Windows gratuits, 100 % locaux, aperçu avant toute action, MIT
🩺 DevEnv Doctor (Tauri v2) : nettoyeur de PATH → https://github.com/TxF-AI/devenv-doctor
🔌 PortDoctor (Tauri v2) : libère les ports bloqués, Smart Kill des arbres de processus → https://github.com/TxF-AI/port-doctor
⚡ PC Toolkit (PowerShell + WPF) : diagnostics en lecture seule et presets réversibles → https://github.com/TxF-AI/PC-Toolkit
Vos retours sont les bienvenus ! 🙏
```
