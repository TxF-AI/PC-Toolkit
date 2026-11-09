# Contribuer à PC Toolkit

Merci de l'intérêt porté au projet ! Quelques règles simples pour que chaque contribution reste sûre et facile à relire.

## Avant de commencer
- Ouvrez d'abord une **issue** (bug ou idée) pour en discuter, surtout pour une nouvelle fonctionnalité.
- Environnement : **Windows 10/11**, **Windows PowerShell 5.1** (pas PowerShell 7), Pester 3.4 (fourni avec Windows).

## Règles du produit (non négociables)
- **Diagnostics en lecture seule.** Toute action qui modifie le système doit : afficher un aperçu, exiger une confirmation explicite (`-Confirmed`), puis écrire dans le journal (`Write-AppLog ... 'ACTION'`).
- **Ne jamais inventer une mesure** : ce que Windows n'expose pas s'affiche « Non disponible ».
- **Aucune dépendance externe**, rien à installer, rien envoyé sur Internet (hors pings/DNS du test réseau).
- **Ne jamais modifier ni contourner les réglages de sécurité de Windows** (UAC, Defender, pare-feu).
- L'interface ne doit jamais planter sur une erreur de module : gérer les erreurs.
- Interface et messages **en français**.

## Pièges PowerShell 5.1
- Les fichiers `.ps1` / `.psm1` doivent être en **UTF-8 avec BOM**, sinon les accents sont cassés.
- Une fonction qui renvoie un seul élément le « déroule » : entourer l'appel de `@()`.
- Les variables sont insensibles à la casse ; ne pas nommer une variable `$args`, `$input` ou `$error`.
- Les noms de fonctions doivent être uniques entre modules.
- Ne nommez jamais une fonction `Invoke-Persistence…` : certains antivirus bloquent le fichier. Les tests qui écrivent des motifs de malware doivent les construire par morceaux.

## Tests
Pester 3.4 : syntaxe `Should Be`, `Should Throw` (pas `Should -Be`).

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Run-Tests.ps1
```

Le code de sortie est le nombre de tests en échec (`0` = tout est bon). Ajoutez ou adaptez des tests pour chaque changement de comportement, et lancez la suite avant d'ouvrir une pull request. La CI (GitHub Actions) la relance automatiquement.

## Proposer un changement
1. Forkez le dépôt et créez une branche à partir de `main` (`feat/...`, `fix/...`, `docs/...`).
2. Faites des changements ciblés : une pull request = un sujet.
3. Mettez à jour `CHANGELOG.md` ; `VERSION` est la seule source du numéro de version.
4. Messages de commit au format `type(portée): description` (`feat`, `fix`, `docs`, `test`, `chore`).
5. Ouvrez la pull request en décrivant ce qui change, pourquoi, et comment vous l'avez testé.

Ne commitez jamais `Data\` ni `Reports\` : ce sont les données personnelles de l'utilisateur.

## Signaler une faille de sécurité
Ne l'exposez pas dans une issue publique : contactez le mainteneur en privé via le profil GitHub du dépôt.

## Licence
En contribuant, vous acceptez que votre code soit publié sous licence [MIT](LICENSE).
