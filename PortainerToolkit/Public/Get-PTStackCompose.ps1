#Requires -Version 7.0
function Get-PTStackCompose {
    <#
    .SYNOPSIS
    Returns a selected stack's Compose file as text, without saving it.
    .DESCRIPTION
    Verifies stack membership in the connected environment before retrieving
    the file. The exact original text may contain passwords, tokens and other
    secrets. No redaction or export is performed. Avoid transcripts and commits.
    .PARAMETER StackId
    ID of a Portainer-managed stack in the current environment.
    .EXAMPLE
    $compose = Get-PTStackCompose -StackId 10
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][ValidateRange(1,[int]::MaxValue)][int]$StackId)
    $session = Get-PTSession
    $stack = @(Get-PTStack -Id $StackId)
    if ($stack.Count -ne 1) { throw 'The stack was not found in the connected environment or is not accessible.' }
    Write-Warning 'Compose content may contain secrets. Avoid transcripts, shared logs and committing exports.'
    $response = Invoke-PTRequest -Session $session -Path "/api/stacks/$StackId/file"
    $content = Get-PTField $response 'StackFileContent'
    if ($content -isnot [string]) { throw 'Portainer did not return valid Compose text.' }
    return $content
}
