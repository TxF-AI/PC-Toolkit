#requires -Version 5.1
<#
    Lance tous les tests de PC Toolkit (Pester 3.4, fourni avec Windows).
    Usage : powershell -NoProfile -ExecutionPolicy Bypass -File .\Run-Tests.ps1
    Code de sortie = nombre de tests en échec (0 = tout est bon).
#>
Import-Module Pester -MaximumVersion 4.99 -ErrorAction Stop
$r = Invoke-Pester -Script (Join-Path $PSScriptRoot 'Tests') -PassThru
Write-Host ''
if ($r.FailedCount -eq 0) { Write-Host "  OK : $($r.PassedCount) tests réussis." -ForegroundColor Green }
else { Write-Host "  ÉCHEC : $($r.FailedCount) test(s) sur $($r.TotalCount)." -ForegroundColor Red }
exit $r.FailedCount
