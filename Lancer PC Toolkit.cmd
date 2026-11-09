@echo off
rem Lance PC Toolkit en mode portable (sans installation), depuis n'importe quel dossier ou cle USB.
if not exist "%~dp0PCToolkit.ps1" goto :notextracted
if not exist "%~dp0Modules\Core.psm1" goto :notextracted
start "" powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File "%~dp0PCToolkit.ps1"
exit /b

:notextracted
echo.
echo  PC Toolkit doit etre extrait avant d'etre lance.
echo  Clic droit sur le fichier .zip, "Extraire tout...", puis relancez "Lancer PC Toolkit.cmd".
echo.
pause
