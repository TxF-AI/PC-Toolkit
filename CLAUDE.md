# PC Toolkit — règles du projet

Outil de diagnostic et de maintenance Windows : **Windows PowerShell 5.1 + WPF**, interface en **français et anglais** (sélecteur FR/EN), thème sombre rouge néon (`#FF2A4D`).

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
- Un module par page : Dashboard, Hardware, Network, WindowsAnalysis, Storage, Audio, Maintenance, SecurityGuard (audit léger, scan heuristique, quarantaine `DataQuarantine` ; ne jamais nommer une fonction `Invoke-Persistence…` : l'antivirus bloque le fichier), Tuning (presets Jeu/MAO/Bureautique, réutilisent Enable-GameMode), Performance (démarrage via StartupApproved ; Mode Performance, état dans Data\GameMode.json ; noms de fonctions uniques entre modules), Bilan (photos avant/après en mémoire seulement : départ pris par le job de diagnostic (`Start-BackgroundJob -Baseline` → `Set-BilanBaseline`), fin par `Complete-Bilan` après chaque nettoyage ; le bilan est ajouté en dernier par `Export-DiagText` / `Export-DiagHtml`).
- **Langues FR/EN** : `Modules\I18n.psm1` (`Get-Text <clé> [args]`, `Get-AppLanguage`, `Set-AppLanguage`) + `Lang\fr.psd1` (référence) et `Lang\en.psd1`, lus par l'arbre syntaxique (`Import-PowerShellDataFile` plafonne à 500 clés). Langue : variable `PCTOOLKIT_LANG` (tests) > `Data\language.json` > culture Windows. Règles :
  - tout texte visible passe par `Get-Text` ; `{0}`, `{1}`… = arguments, `\n` = retour à la ligne ; clés `Prefixe.NNN` numérotées par module (Hw, Db, St, Net, Win, Aud, Mnt, Tun, Bil, Prf, Sec, Ui, Ins, Uni) + clés nommées (`Nav.*`, `Page.*.Desc`, `Col.<nom de colonne>`, `Fld.*`…) ;
  - une nouvelle clé s'ajoute **dans les deux** fichiers (avant le marqueur `# @@END@@`) : les tests exigent la même liste de clés et les mêmes `{n}` ;
  - **ne jamais appeler `Get-Text` au niveau script d'un module** (évalué à l'import, la langue ne suivrait pas le changement à chaud) : stocker la clé et résoudre à l'usage (voir `Performance.psm1`, `SecurityGuard.psm1`) ;
  - les valeurs internes qui servent de repère au code (`Kind` = Fichier / Tâche planifiée / Démarrage, `Type` audio, `État` Activé/Désactivé…) restent en français ; on traduit à l'affichage (`Get-SecurityKindLabel`, `Get-AudioTypeLabel`, `Get-ColumnLabel`) ;
  - les noms de colonnes des tableaux restent les noms internes ; l'en-tête affiché vient de `Col.<nom>` ; `Update-UiLanguage` (PCToolkit.ps1) ré-applique les textes fixes de la fenêtre ;
  - les tests forcent `PCTOOLKIT_LANG=fr`.
- Tests de l'interface réelle : piloter la vraie fenêtre avec UI Automation, en ne lançant et n'arrêtant que son propre processus (jamais « tuer tous les PCToolkit.ps1 » : l'utilisateur peut avoir l'appli ouverte).
- `VERSION` = seule source du numéro de version. `CHANGELOG.md` (anglais) et `CHANGELOG.fr.md` (français) à compléter à chaque version.
- `Installer.ps1` → `%LocalAppData%\PCToolkit` + entrée HKCU « Applications installées » ; `Desinstaller.ps1` (garde-fous de dossier).
- Interface : jauges en direct + console (relit le journal du jour) + animations dans `PCToolkit.ps1` (`Update-LiveGauges`, `Update-LogConsole`, `Set-SmoothValue`). Les tests écrivant des motifs de malware doivent les construire par morceaux (AMSI bloque les chaînes complètes).
- `graphify-out/` : graphe du code. Après une modification de code : `graphify update .` (gratuit).

## Commandes
- Tests : `powershell -NoProfile -ExecutionPolicy Bypass -File .\Run-Tests.ps1` — à lancer après chaque modification.
- Zip à partager : `powershell -NoProfile -ExecutionPolicy Bypass -File .\Build-Zip.ps1` (sur le Bureau, avec empreinte SHA-256).
- Lancement : `launch-all.ps1` (menu interactif : copie les textes des `LAUNCH_KIT*.md` dans le presse-papier, ouvre les pages de publication, montre les médias ; ne publie rien ; `-DryRun` pour tester). Médias dans `dist-launch/` (anonymisés : nom du PC et matériel masqués ; jamais de capture brute de la fenêtre).
- Lancer l'appli : `Lancer PC Toolkit.cmd`.

## Ne pas toucher
- `Data\` (historique et journaux de l'utilisateur) et `Reports\` : données personnelles, jamais dans le zip ni dans Git.

## Travail avec l'utilisateur
- Réponses en français, courtes. Résumé détaillé à la fin de chaque tâche.
