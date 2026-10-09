#Requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot

# Validate all shipped PowerShell source before loading it.
$sourceFiles = Get-ChildItem -LiteralPath $taskRoot -Recurse -File | Where-Object Extension -In @('.ps1','.psm1','.psd1')
foreach ($sourceFile in $sourceFiles) {
    $parseTokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($sourceFile.FullName, [ref]$parseTokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        $parseErrors | ForEach-Object { Write-Error "$($sourceFile.Name): $($_.Message)" -ErrorAction Continue }
        exit 1
    }
}
$manifest = Test-ModuleManifest -Path (Join-Path $taskRoot (Join-Path 'PortainerToolkit' 'PortainerToolkit.psd1'))
Write-Host "Syntax and manifest valid: $($manifest.Name) $($manifest.Version)"

if (-not (Get-Module -ListAvailable Pester | Where-Object Version -GE ([version]'5.7.1'))) {
    Write-Error 'Tests require Pester 5.7.1 or newer. Install Pester separately, then rerun.' -ErrorAction Continue
    exit 1
}
Import-Module Pester -MinimumVersion 5.7.1
$result = Invoke-Pester -Path (Join-Path $taskRoot 'tests') -Output Detailed -PassThru
if ($result.Result -ne 'Passed') { exit 1 }
exit 0

