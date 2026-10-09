#Requires -Version 7.0
function Get-PTStack {
    <#
    .SYNOPSIS
    Lists Portainer-managed stacks in the connected environment.
    .DESCRIPTION
    Returns selected metadata only, excluding environment variables and Git
    credentials. Filters use exact case-insensitive names and exact numeric IDs.
    External/limited stacks may not be present in Portainer's stack-list response.
    .PARAMETER Id
    Optional stack ID filter.
    .PARAMETER Name
    Optional exact name filter; wildcard expansion is not performed.
    .EXAMPLE
    Get-PTStack -Name 'web'
    #>
    [CmdletBinding()]
    param(
        [ValidateRange(1, [int]::MaxValue)][int]$Id,
        [ValidateNotNullOrEmpty()][string]$Name
    )
    $session = Get-PTSession
    # Filter locally: Portainer's EndpointID-only filter can omit Swarm stacks.
    $response = Invoke-PTRequest -Session $session -Path '/api/stacks'
    foreach ($stack in $response) {
        if ($null -eq $stack) { continue }
        $stackId = Get-PTField $stack 'Id'
        $stackName = [string](Get-PTField $stack 'Name')
        if ((Get-PTField $stack 'EndpointId') -ne $session.EnvironmentId) { continue }
        if ($PSBoundParameters.ContainsKey('Id') -and $stackId -ne $Id) { continue }
        if ($PSBoundParameters.ContainsKey('Name') -and $stackName -ne $Name) { continue }
        [pscustomobject]@{
            PSTypeName = 'PortainerToolkit.Stack'
            Id = [int]$stackId
            Name = $stackName
            EnvironmentId = $session.EnvironmentId
            Type = Get-PTField $stack 'Type'
            Status = Get-PTField $stack 'Status'
            EntryPoint = [string](Get-PTField $stack 'EntryPoint')
        }
    }
}
