# Nouveautés

🇬🇧 [English version](CHANGELOG.md)

## 1.7.1 (2026-11-10)

**Mode anglais : suppression du français restant**
- **Nombres** selon la langue de l'interface : en anglais, `32.0 GB` et `44.1 kHz` au lieu de `32,0` et `44,1` sur un Windows français.
- **Mode d'alimentation** : les quatre plans standard de Windows s'affichent avec leur nom anglais (par exemple `High performance`).
- Le libellé d'**erreur de section** et la **console administrateur** de remise à zéro des compteurs de données sont maintenant traduits.
- Les noms fournis par Windows lui-même (périphériques audio, messages du journal d'événements) restent dans la langue de Windows : rien n'est inventé.

## 1.7.0 (2026-11-10)

**Diagnostic à copier pour un assistant IA**
- Nouveau bouton **AI** à côté de HTML et TXT : il copie dans le presse-papiers un résumé Markdown du diagnostic affiché, en ne gardant que les éléments critiques et à surveiller (par section), suivi d'une question toute prête pour un assistant IA (Claude Code, Cursor…).
- Le nom du PC et le nom d'utilisateur Windows sont masqués (`<pc>`, `<user>`). Rien n'est envoyé sur Internet : le texte va seulement dans le presse-papiers.
- `Format-DiagAiPrompt` dans `Modules\Core.psm1` ; 167 tests Pester.

## 1.6.0 (2026-11-10)

**Interface bilingue français / anglais**
- Sélecteur **FR / EN** en bas de la barre latérale, appliqué à chaud (sans relancer). Choix mémorisé dans `Data\language.json` (jamais versionné) ; par défaut, la langue de Windows.
- Tout est traduit : menus, pages, diagnostics, constats et recommandations, presets, Security Guard, bilan, console, exports HTML / TXT, installateur et désinstallateur.
- `Modules\I18n.psm1` (`Get-Text`, `Set-AppLanguage`) et dictionnaires `Lang\fr.psd1` / `Lang\en.psd1`. Une clé absente ne plante jamais : repli sur le français, puis sur la clé.
- Limites : les résultats déjà enregistrés dans l'historique gardent la langue dans laquelle ils ont été produits ; les messages du journal d'événements Windows, les noms de périphériques et de plans d'alimentation restent dans la langue de Windows ; la console administrateur « Réinitialiser les compteurs de données (SRUM) » reste en français.
- Tests : 166 (dont la parité FR/EN des dictionnaires, les marqueurs `{0}`, l'absence de français dans l'anglais, les exports en anglais).

**Documentation et correctif** (2026-11-10)
- README, CONTRIBUTING et modèles d'issues en anglais par défaut ; versions françaises dans `README.fr.md` et `CONTRIBUTING.fr.md`.
- GIF de démonstration et captures en anglais (`dist-launch/`), versions françaises en `*.fr.*`.
- Correctif : `Get-Text` ignorait un unique argument `$false` ou `0` (la console affichait « admin={0} »). Test ajouté.

## 1.5.0

**Interface modernisée (néon rouge et cyan)**
- Tableau de bord : jauges animées en direct pour le processeur, la mémoire et le disque C: (couleur cyan, orange à 70 %, rouge à 90 %), rafraîchies chaque seconde.
- Transitions fluides entre les onglets (fondu et glissement), barres de progression animées pendant les analyses et nettoyages, lueurs néon sur les titres et les jauges.
- Console intégrée en bas de la fenêtre : les actions, avertissements et erreurs s'affichent en temps réel (journal du jour), avec boutons « Effacer » et « Réduire ».

**Presets d'optimisation 1-clic** (page Mode Performance)
- **Jeu** : plan Performances ultimes / élevées, arrêt temporaire de 7 services secondaires, vidage du cache RAM, nettoyage des fichiers temporaires et du démarrage.
- **MAO** : plan haute performance, arrêt temporaire des services secondaires (Windows Update et SysMain inclus, sources de pics de latence), nettoyage du démarrage. La RAM n'est volontairement pas vidée (les échantillons et plugins chargés restent en mémoire). Les services audio ne sont jamais touchés.
- **Bureautique** : plan conservé, arrêt de 4 services inutiles (télémétrie, cartes, fax, registre distant), nettoyage des fichiers temporaires.
- Aperçu détaillé et confirmation avant application ; état sauvegardé et « Restaurer l'état initial » en un clic. Tout est exécuté en arrière-plan avec barre de progression.

**Security Guard** (nouvelle page, audit léger : ce n'est pas un antivirus)
- Audit système : service et protection en temps réel de Windows Defender, âge des définitions de virus, pare-feu (3 profils), contrôle de compte (UAC).
- Éléments suspects : programmes de démarrage actifs, tâches planifiées hors Microsoft, exécutables et scripts à la racine de Temp, AppData et Public. Indices relevés : exécutable non signé ou à signature invalide, double extension, caractère de lecture inversée, nom de processus Windows hors du dossier Windows, commandes encodées ou téléchargeant du code.
- Scan d'un fichier ou d'un dossier : signature, empreinte SHA-256 comparée à une liste de fichiers connus, motifs de scripts malveillants connus.
- Quarantaine sécurisée (`Data\Quarantine\`) : fichier déplacé sous un nom neutralisé, tâche ou démarrage désactivé, jamais supprimé ; restauration en un clic. Garde-fous : dossier Windows, fichiers de PC Toolkit, tâches Microsoft et liste blanche du démarrage ne sont jamais touchés. Confirmation et journal pour chaque action.
- Résultats exportables en HTML et TXT.

**Bilan avant/après**
- 3 nouveaux indicateurs (11 au total) : éléments suspects actifs, menaces en quarantaine, profil d'optimisation actif. Ils figurent aussi dans les exports TXT et HTML.
- Une neutralisation de Security Guard met le bilan à jour sans quitter la page.

**Technique**
- Nouveaux modules `SecurityGuard.psm1` et `Tuning.psm1`. `Enable-GameMode` accepte une liste de services, l'option « plan conservé » et un nom de profil.
- Le nom `Invoke-PersistenceScan` déclenchait l'antivirus sur le code source lui-même : les fonctions de détection portent des noms neutres.

## 1.4.0

**Nettoyage automatique du démarrage**
- Bouton « Optimiser automatiquement le démarrage » (page Démarrage) : désactive les programmes superflus (planificateurs de mise à jour Google, Adobe, Java, Edge ; Spotify, Discord, Steam, Skype, Teams, OneDrive, CyberLink, lanceurs de jeux ; agents de télémétrie). La liste s'affiche et demande confirmation avant toute action.
- **Liste blanche absolue** : pilotes graphiques (NVIDIA, AMD, Intel), audio (Realtek, Waves, ASIO, interfaces audio), sécurité (Defender, antivirus, anti-triche) et utilitaires système ne sont jamais désactivés, même si leur nom ressemble à une cible. Un programme inconnu n'est jamais touché.
- Désactivation par le mécanisme natif de Windows (`StartupApproved`) : aucune clé ni aucun raccourci supprimé. L'état initial est sauvegardé dans `Data\StartupBackup.json` ; « Restaurer la sauvegarde » remet chaque programme exactement comme avant.
- La page liste les programmes désactivés automatiquement avec leur statut.
- Le Bilan avant/après compte désormais les « Programmes au démarrage » purgés (8 indicateurs), y compris dans les exports TXT et HTML.

## 1.3.0

**Démarrage**
- Nouvelle page « Démarrage » : programmes lancés avec Windows (clés Run utilisateur et système, dossiers Démarrage) avec nom, chemin, source et statut Activé / Désactivé.
- Désactivation et réactivation en un clic (après confirmation) par le mécanisme natif de Windows (celui du Gestionnaire des tâches) : aucune clé ni aucun raccourci n'est supprimé ou déplacé. Les programmes « système » demandent le mode administrateur.

**Mode Performance**
- Nouvelle page « Mode Performance » : sauvegarde du plan d'alimentation et des services, passage en Performances ultimes / élevées, arrêt temporaire de 7 services secondaires (Spooler, SysMain, wuauserv, DiagTrack, MapsBroker, Fax, RemoteRegistry) s'ils sont en cours d'exécution, vidage facultatif du cache RAM (proposé à chaque activation).
- « Restaurer l'état initial » remet le plan d'origine et relance les services arrêtés. L'état est gardé dans `Data\GameMode.json` : la restauration reste possible après la fermeture de l'application. Administrateur requis.
- Le gain (RAM disponible, services coupés) apparaît automatiquement dans le Bilan avant/après.

## 1.2.0

**Bilan avant/après**
- L'état du PC est mesuré en silence au début de chaque diagnostic. À la fin d'un nettoyage confirmé dans Maintenance (fichiers temporaires, corbeille, fichiers récents, téléchargements inachevés), l'état final est mesuré et le tableau `INDICATEUR | AVANT | APRÈS | GAIN / NET` s'affiche dans la nouvelle page « Bilan avant/après ».
- Mesures : espace libre sur C:, RAM utilisée (% et Go) et disponible (Mo), services actifs, processus, périphériques audio fantômes, fichiers temporaires + corbeille. Une mesure indisponible s'affiche « Non disponible ».
- Le bilan est ajouté automatiquement à la fin des exports HTML et TXT. Tout reste en mémoire (aucun fichier créé). Deux boutons permettent aussi une mesure manuelle (script de confidentialité, nettoyage audio…).

**Outils (hors application, non inclus dans le zip)**
- `Outils\Confidentialite-Debloat-Win11.ps1` : optimisation de la confidentialité de Windows 11, à lancer en administrateur. Coupe la télémétrie et le suivi publicitaire, désactive Bing et Cortana dans la recherche, les Widgets et les suggestions, et supprime les applications préinstallées inutiles. Aperçu avant toute modification, point de restauration et sauvegarde des anciens réglages (`-Restaurer` pour revenir en arrière).

## 1.1.0

**Partage**
- Numéro de version affiché dans la barre latérale, le titre de la fenêtre et chaque rapport.
- PC Toolkit apparaît dans **Paramètres > Applications installées** et se désinstalle depuis Windows (confirmation, historique conservé au choix).
- Le zip est fourni avec son empreinte SHA-256 pour vérifier qu'il n'a pas été modifié.

**Rapports**
- Export en **TXT** en plus du HTML, avec ouverture directe dans le Bloc-notes.

**Audio**
- Diagnostic universel : il s'adapte à la sortie et au micro par défaut (Realtek, DAC ou interface USB, Bluetooth, HDMI, GoXLR, virtuel).

**Maintenance**
- Remise à zéro des compteurs de données réseau (SRUM), avec sauvegarde de l'ancienne base.
- Nettoyage des fichiers récents et listes de raccourcis, des téléchargements inachevés et de la corbeille, avec aperçu avant suppression.

**Corrections**
- Une seule liste des dates de fin de support de Windows, partagée par le Tableau de bord et la page Windows.

## 1.0.0

- Première version : Tableau de bord, Matériel, Réseau, Windows, Stockage, Audio, Maintenance et Historique.
