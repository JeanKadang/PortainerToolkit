#Requires -Version 7.0
function Get-PTSession {
    if ($null -eq $script:PTSession) {
        throw 'Connect-PTServer must succeed before running this command.'
    }
    return $script:PTSession
}
