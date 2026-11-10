# dist-launch : visuels de lancement

Médias prêts à glisser-déposer dans les publications (voir `LAUNCH_KIT.md` et `launch-all.ps1`).

| Fichier | Contenu | Usage |
|---|---|---|
| `demo.gif` | Visite guidée de 9 s : Tableau de bord → Mode Performance (presets) → Security Guard → Bilan avant/après | **Média principal** (Reddit, X, LinkedIn, Discord) |
| `ui-dashboard.png` | Tableau de bord : jauges en direct, vue d'ensemble | Média de secours, README |
| `ui-presets.png` | Page Mode Performance : presets 1-clic Jeu / MAO / Bureautique | Média de secours |
| `ui-security.png` | Page Security Guard | Média de secours |
| `ui-bilan.png` | Page Bilan avant/après | Média de secours |

**Comment ils ont été faits :** captures de la vraie fenêtre de PC Toolkit v1.5.0 (pilotée par UI Automation, navigation seulement : aucune action n'a modifié le PC), assemblées en GIF avec un curseur dessiné et des fondus.

**Anonymisation :** le nom du PC, les modèles de processeur, de carte graphique et de périphérique audio ont été remplacés par des libellés génériques (`PC-DEMO`, « Processeur », « Carte graphique », « Périphérique audio »). Les mesures de charge (CPU, RAM, disque) et les horodatages sont réels. Si tu refais les visuels, relis chaque image avant de la publier.

Ce dossier n'est pas inclus dans le zip distribué (`Build-Zip.ps1` n'embarque que les fichiers listés).

**Langues :** les fichiers ci-dessus sont en **anglais** (interface lancée avec `PCTOOLKIT_LANG=en`) ; les versions françaises portent le suffixe `.fr` (`demo.fr.gif`, `ui-dashboard.fr.png`, etc.).
