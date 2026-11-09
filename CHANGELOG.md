# Nouveautés

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
