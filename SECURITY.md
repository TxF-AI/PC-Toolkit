# Politique de sécurité

## Versions prises en charge
Seule la **dernière version publiée** (voir `VERSION` et la page Releases) reçoit des correctifs de sécurité.

## Signaler une vulnérabilité
**N'ouvrez pas d'issue publique** pour une faille de sécurité.

Utilisez les **GitHub Security Advisories**, en privé :
1. Onglet **Security** du dépôt > **Report a vulnerability**.
2. Décrivez le problème, les étapes pour le reproduire, la version concernée et son impact.

Vous recevrez une réponse dès que possible ; la correction et sa publication seront coordonnées avec vous avant toute divulgation publique.

## Ce qui est considéré comme une vulnérabilité
- Une action qui modifie ou supprime des données sans aperçu ni confirmation explicite.
- Un contournement des garde-fous : liste blanche du démarrage, protections de la quarantaine, refus de toucher au dossier Windows.
- Une élévation de privilèges, une exécution de code non voulue, ou une écriture hors des dossiers prévus (`Data\`, `Reports\`).
- Une fuite d'informations : l'outil n'envoie **rien** sur Internet (hors pings et DNS du test réseau).

## Hors périmètre
- Les constats de **Security Guard** (éléments « à examiner ») : ce sont des indices, pas des verdicts, et l'outil n'est pas un antivirus.
- L'avertissement SmartScreen : les scripts ne sont pas signés numériquement (voir le README).
- Les failles de Windows ou de PowerShell eux-mêmes.

## Vérifier un téléchargement
Comparez le SHA-256 du zip avec celui de la description de la release et du fichier `.sha256.txt` :

```powershell
Get-FileHash .\PC-Toolkit-v<version>.zip -Algorithm SHA256
```
