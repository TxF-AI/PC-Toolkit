#requires -Version 5.1
<#
    I18n.psm1 — Langues de l'interface (français / anglais)
    ---------------------------------------------------------
    - Get-Text <clé> [args]   texte dans la langue courante ; {0}, {1}… = arguments (comme -f)
    - Get-AppLanguage / Set-AppLanguage   langue courante ('fr' ou 'en'), mémorisée dans Data\language.json
    Dictionnaires : Lang\fr.psd1 (référence) et Lang\en.psd1.
    Ne plante jamais : clé absente en anglais -> français -> la clé elle-même.
    Les noms techniques (services, chemins, commandes) ne sont pas traduits.
#>

$script:AppRoot = Split-Path $PSScriptRoot -Parent
$script:LangDir = Join-Path $script:AppRoot 'Lang'
$script:LangFile = Join-Path $script:AppRoot 'Data\language.json'
$script:Supported = @('fr', 'en')
$script:Dict = @{}
$script:Current = $null

function Get-SupportedLanguage { <# Codes de langue gérés. #> @($script:Supported) }

function Read-LangFile {
    <# Lit un dictionnaire .psd1 par son arbre syntaxique (Import-PowerShellDataFile refuse plus de 500 clés). Aucun code n'est exécuté. #>
    param([string]$Path)
    $d = @{}
    $t = $null; $e = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$t, [ref]$e)
    $h = $ast.Find({ param($n) $n -is [Management.Automation.Language.HashtableAst] }, $true)
    if ($h) {
        foreach ($kv in $h.KeyValuePairs) {
            $k = $kv.Item1; $v = $kv.Item2.PipelineElements[0].Expression
            if ($k -is [Management.Automation.Language.StringConstantExpressionAst] -and $v -is [Management.Automation.Language.StringConstantExpressionAst]) { $d[$k.Value] = $v.Value }
        }
    }
    $d
}

function Get-LanguageData { <# Dictionnaire complet d'une langue (tests, outils). #> param([string]$Code) Read-Dictionary $Code }

function Read-Dictionary {
    param([string]$Code)
    if ($script:Dict.ContainsKey($Code)) { return $script:Dict[$Code] }
    $d = @{}
    try {
        $f = Join-Path $script:LangDir "$Code.psd1"
        if (Test-Path -LiteralPath $f) { $d = Read-LangFile $f }
    } catch { $d = @{} }
    $script:Dict[$Code] = $d
    $d
}

function Get-DefaultLanguage {
    <# Langue de Windows : français si la culture est française, anglais sinon. #>
    try { if ((Get-Culture).TwoLetterISOLanguageName -eq 'fr') { return 'fr' } } catch { }
    'en'
}

function Get-AppLanguage {
    <# Langue courante : celle de Data\language.json, sinon celle de Windows. #>
    if ($script:Current) { return $script:Current }
    $code = $null
    try {
        if (Test-Path -LiteralPath $script:LangFile) {
            $code = (Get-Content -LiteralPath $script:LangFile -Raw -Encoding UTF8 | ConvertFrom-Json).Language
        }
    } catch { $code = $null }
    if ($code -notin $script:Supported) { $code = Get-DefaultLanguage }
    $script:Current = $code
    $code
}

function Set-AppLanguage {
    <# Change la langue (à chaud) et la mémorise dans Data\language.json (jamais versionné). #>
    param([Parameter(Mandatory)][string]$Code, [switch]$NoSave)
    $Code = $Code.ToLower()
    if ($Code -notin $script:Supported) { return $false }
    $script:Current = $Code
    if (-not $NoSave) {
        try {
            $dir = Split-Path $script:LangFile -Parent
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            (@{ Language = $Code } | ConvertTo-Json) | Set-Content -LiteralPath $script:LangFile -Encoding UTF8
        } catch { }
    }
    $true
}

function Get-Text {
    <# Texte traduit. Usage : Get-Text 'Dashboard.Title'  ou  Get-Text 'Disk.Free' $go $total #>
    param([Parameter(Position = 0)][string]$Key, [Parameter(ValueFromRemainingArguments = $true)]$FormatArgs)
    try {
        $text = $null
        $d = Read-Dictionary (Get-AppLanguage)
        if ($d.ContainsKey($Key)) { $text = $d[$Key] }
        if ($null -eq $text) { $fr = Read-Dictionary 'fr'; if ($fr.ContainsKey($Key)) { $text = $fr[$Key] } }
        if ($null -eq $text) { return $Key }
        $text = $text.Replace('\n', "`n")   # \n = retour à la ligne dans les dictionnaires
        if ($FormatArgs -and @($FormatArgs).Count -gt 0) {
            try { return ($text -f @($FormatArgs)) } catch { return $text }
        }
        $text
    } catch { $Key }
}

Export-ModuleMember -Function Get-LanguageData, Get-Text, Get-AppLanguage, Set-AppLanguage, Get-SupportedLanguage, Get-DefaultLanguage
