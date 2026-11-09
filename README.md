# ⚡ PC//TOOLKIT — maintenance et diagnostic

Boîte à outils de diagnostic pour Windows 11 : matériel, réseau, Windows, stockage, audio et maintenance.
Interface sombre au rouge néon, en français. **Aucun logiciel à installer** : Windows suffit.

## Démarrage rapide

1. **Extraire le zip** : clic droit sur `PC-Toolkit-v<version>.zip` > **Extraire tout…**
   (ne pas lancer directement depuis l'intérieur du zip).
2. Choisir une des deux façons de l'utiliser :

| | Comment | Pour qui |
|---|---|---|
| **Portable** | Double-clic sur **`Lancer PC Toolkit.cmd`** | Essayer sans rien installer, ou l'utiliser depuis une clé USB |
| **Installation** | Double-clic sur **`Installer.cmd`** | L'utiliser souvent : raccourcis **⚡ PC∕∕TOOLKIT** sur le Bureau et dans le menu Démarrer |

L'installation copie l'application dans `%LocalAppData%\PCToolkit` et l'ajoute à **Paramètres > Applications installées**. Elle ne demande aucun droit administrateur et n'ajoute rien au démarrage de Windows.
Pour mettre à jour, relancez `Installer.cmd` depuis la nouvelle version : l'historique est conservé.
La version installée s'affiche en bas de la barre latérale et dans chaque rapport.

### Si Windows affiche un avertissement
PC Toolkit n'est pas signé numériquement (un certificat coûte plusieurs centaines d'euros par an) : Windows le traite donc comme un fichier inconnu venant d'Internet ou de Discord. C'est normal.
- **Avant d'extraire**, faites un clic droit sur le zip > **Propriétés** > cochez **Débloquer** > OK. Plus aucun avertissement ensuite.
- Si l'écran bleu « Windows a protégé votre ordinateur » apparaît : cliquez **Informations complémentaires** > **Exécuter quand même**.
- Tout le code est lisible : ce sont des fichiers texte (`.ps1`, `.psm1`, `.xaml`) que vous pouvez ouvrir avec le Bloc-notes avant de lancer quoi que ce soit.

### Vérifier que le zip n'a pas été modifié
Le fichier `PC-Toolkit-v<version>.zip.sha256.txt` fourni avec le zip contient son empreinte. Dans PowerShell, dans le dossier du zip :
```
Get-FileHash .\PC-Toolkit-v<version>.zip
```
Les deux suites de chiffres et de lettres doivent être identiques. Sinon, le fichier a été modifié ou abîmé pendant le transfert : ne l'utilisez pas.

## Ce que fait l'application

| Page | Contenu |
|---|---|
| Tableau de bord | État général en 10 s : CPU, RAM, disque, pilote graphique, ping, événements critiques, points d'attention |
| Matériel | Processeur, mémoire (XMP, dual channel), carte graphique, BIOS, températures réellement exposées |
| Réseau | Connexion, DNS et DoH, latence, gigue, pertes de paquets, rapidité DNS |
| Windows | Version et fin de support, plantages, écrans bleus, journaux, services, démarrage, sécurité |
| Stockage | Espace libre, santé des disques, dossiers volumineux, gros fichiers |
| Audio | Votre sortie et votre micro **par défaut**, quels qu'ils soient : carte son intégrée (Realtek…), DAC ou interface USB, casque Bluetooth, HDMI, GoXLR, périphérique virtuel. Type de connexion, pilote, fréquences, ASIO, suspension USB, latence indicative |
| Maintenance | Fichiers temporaires, corbeille, cache DNS, SFC, DISM, CHKDSK, point de restauration |
| Historique et confidentialité | Fichiers récents et listes de raccourcis, téléchargements inachevés, remise à zéro des compteurs de données réseau (SRUM) |
| Bilan avant/après | Mesure automatique de chaque nettoyage : espace libéré, RAM, services actifs, fichiers temporaires, périphériques audio fantômes. En mémoire, export HTML ou TXT |
| Historique | Diagnostics enregistrés, export en rapport HTML ou TXT |

### Rapports
Chaque diagnostic s'exporte en **HTML**, mis en forme pour le navigateur, ou en **TXT**, du texte brut facile à coller sur Discord ou un forum.
La case **« Ouvrir le TXT dans le Bloc-notes »** ouvre directement le rapport. Décochée, elle sélectionne simplement le fichier dans l'Explorateur.

### Compteurs de données réseau
L'outil remet à zéro la base **SRUM** de Windows : la consommation de données par application, l'« Historique des applications » du Gestionnaire des tâches et, sur un portable, l'historique de la batterie.
- L'ancienne base n'est pas supprimée : elle est déplacée dans `C:\Windows\System32\sru.sauvegarde-<date>`.
- La commande `netsh int ip reset` n'est **pas** utilisée : elle réinitialise toute la configuration réseau (DNS, IP fixes) sans remettre les compteurs à zéro.

## Sécurité

- **Les diagnostics ne modifient rien** : ils se contentent de lire.
- Chaque action de maintenance explique ce qu'elle va faire et attend votre **Oui** avant d'agir.
- Les outils système (SFC, DISM, CHKDSK) s'ouvrent dans une fenêtre visible, après l'autorisation de Windows.
- Aucune mesure n'est inventée : ce que Windows n'expose pas s'affiche « Non disponible ».
- Rien n'est envoyé sur Internet, à part les pings et les requêtes DNS du test réseau.
- Le bouton **Relancer en administrateur** est facultatif : il permet seulement de lire plus d'informations (santé SMART, températures des disques).

## Désinstaller

- **Version portable** : supprimez simplement le dossier.
- **Version installée** : **Paramètres > Applications > Applications installées > PC Toolkit > Désinstaller**.
  La désinstallation demande confirmation, propose de garder l'historique, puis retire les raccourcis, l'entrée Windows et le dossier `%LocalAppData%\PCToolkit`.

## Fichiers

```
PC Toolkit\
├─ Lancer PC Toolkit.cmd      lancement portable
├─ Installer.cmd / .ps1       installation (copie + raccourcis + entrée Windows)
├─ Desinstaller.ps1           désinstallation
├─ PCToolkit.ps1              application (interface)
├─ VERSION                    numéro de version (seule source)
├─ CHANGELOG.md               nouveautés de chaque version
├─ app.ico                    icône
├─ UI\MainWindow.xaml         design de l'interface
├─ Modules\*.psm1             un module par diagnostic + Core (base commune)
├─ Data\                      historique et journaux (créé à l'utilisation)
└─ Reports\                   rapports HTML et TXT exportés (créé à l'utilisation)
```

## Dépannage

- **Rien ne s'ouvre** : ouvrez PowerShell dans le dossier et lancez
  `powershell -ExecutionPolicy Bypass -NoProfile -File .\PCToolkit.ps1` pour voir le message d'erreur.
- Les erreurs techniques sont enregistrées dans `Data\Logs`.
- Configuration requise : Windows 10 ou 11, avec Windows PowerShell 5.1 (inclus dans Windows).
