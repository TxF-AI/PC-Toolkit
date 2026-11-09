# PC Toolkit — règles du projet

Outil de diagnostic et de maintenance Windows : **Windows PowerShell 5.1 + WPF**, interface en **français**, thème sombre rouge néon (`#FF2A4D`).

## Règles du produit (non négociables)
- Diagnostics **en lecture seule**. Toute action qui modifie le système : aperçu, puis **confirmation explicite** (`-Confirmed`), puis journal (`Write-AppLog ... 'ACTION'`).
- **Ne jamais inventer une mesure** : ce que Windows n'expose pas s'affiche « Non disponible ».
- Aucune dépendance externe, aucun logiciel à installer, rien envoyé sur Internet (sauf pings/DNS du test réseau).
- Gestion d'erreurs partout : l'interface ne doit jamais planter sur une erreur de module.

## Pièges PowerShell 5.1 (déjà rencontrés)
- `.ps1` / `.psm1` **en UTF-8 avec BOM**, sinon les accents cassent. L'outil Write n'ajoute pas de BOM : le rajouter après coup.
- `Get-ChildItem -LiteralPath ... -Include` ignore `-Include` : filtrer avec `Where-Object Extension`.
- Une fonction qui renvoie un seul élément le « déroule » : entourer de `@()`.
- Variables insensibles à la casse (`$t` = `$T`) ; ne pas utiliser `$args`, `$input`, `$error` comme noms.
- Arguments vers un exe natif : les guillemets se perdent. Console admin → `-EncodedCommand` ; Python → fichier script.
- Raccourcis au nom Unicode (⚡, ∕) : **créer** avec WScript.Shell sous un nom ASCII puis renommer ; **lire** avec Shell.Application (`GetLink`).
- Pester installé = **3.4** : syntaxe `Should Be`, `Should Throw` (pas `Should -Be`).

## Architecture
- `PCToolkit.ps1` : interface (XAML `UI\MainWindow.xaml`), jobs en runspace avec hashtable synchronisée (`Progress`, `Status`, `Cancel`).
- `Modules\Core.psm1` : modèle de résultat (`New-DiagResult` / `Add-DiagSection` / `Add-DiagItem`), historique JSON, exports HTML/TXT, `Get-AppVersion`.
- Un module par page : Dashboard, Hardware, Network, WindowsAnalysis, Storage, Audio, Maintenance, Bilan (photos avant/après dans `Data\Snapshots`, résultat au modèle standard donc exportable).
- `VERSION` = seule source du numéro de version. `CHANGELOG.md` à compléter à chaque version.
- `Installer.ps1` → `%LocalAppData%\PCToolkit` + entrée HKCU « Applications installées » ; `Desinstaller.ps1` (garde-fous de dossier).
- `graphify-out/` : graphe du code. Après une modification de code : `graphify update .` (gratuit).

## Commandes
- Tests : `powershell -NoProfile -ExecutionPolicy Bypass -File .\Run-Tests.ps1` — à lancer après chaque modification.
- Zip à partager : `powershell -NoProfile -ExecutionPolicy Bypass -File .\Build-Zip.ps1` (sur le Bureau, avec empreinte SHA-256).
- Lancer l'appli : `Lancer PC Toolkit.cmd`.

## Ne pas toucher
- `Data\` (historique et journaux de l'utilisateur) et `Reports\` : données personnelles, jamais dans le zip ni dans Git.

## Travail avec l'utilisateur
- Réponses en français, courtes. Résumé détaillé à la fin de chaque tâche.
