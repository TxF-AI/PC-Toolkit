@echo off
rem Installe PC Toolkit pour l'utilisateur courant (aucun droit administrateur requis).
if not exist "%~dp0Installer.ps1" goto :notextracted
if not exist "%~dp0Modules\Core.psm1" goto :notextracted
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0Installer.ps1"
exit /b

:notextracted
echo.
echo  PC Toolkit doit etre extrait avant d'etre installe.
echo  Clic droit sur le fichier .zip, "Extraire tout...", puis relancez "Installer.cmd".
echo.
pause
