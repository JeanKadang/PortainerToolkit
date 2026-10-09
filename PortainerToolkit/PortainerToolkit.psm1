#Requires -Version 7.0
Set-StrictMode -Version 3.0
$script:PTSession = $null

# Private helpers first, then public commands. Dot-sourcing keeps everything in module
# scope, so $script:PTSession is shared exactly as in a single-file module.
foreach ($folder in 'Private', 'Public') {
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot $folder) -Filter '*.ps1' -File | Sort-Object Name) {
        . $file.FullName
    }
}

# Remove-Module releases our SecureString copy. Nothing is saved to disk.
$ExecutionContext.SessionState.Module.OnRemove = {
    if ($null -ne $script:PTSession) {
        $script:PTSession.ApiKey.Dispose()
        $script:PTSession = $null
    }
}
Export-ModuleMember -Function Connect-PTServer,Get-PTStack,Get-PTContainer,Get-PTStackCompose,Get-PTInventory
