#Requires -Version 7.0
function Get-PTContainer {
    <#
    .SYNOPSIS
    Lists Docker containers in the connected environment, including stopped containers.
    .DESCRIPTION
    Returns selected metadata, excluding raw labels, mounts, configuration and
    environment variables. StackName comes from the Compose project label or
    Swarm stack namespace. Names and IDs use exact case-insensitive matching.
    .PARAMETER RunningOnly
    Requests running containers only; the default includes stopped containers.
    .PARAMETER Id
    Optional full container ID filter; abbreviations are not expanded.
    .PARAMETER Name
    Optional exact container name, with or without Docker's leading slash.
    .EXAMPLE
    Get-PTContainer -RunningOnly
    #>
    [CmdletBinding()]
    param(
        [switch]$RunningOnly,
        [ValidateNotNullOrEmpty()][string]$Id,
        [ValidateNotNullOrEmpty()][string]$Name
    )
    $session = Get-PTSession
    $all = if ($RunningOnly) { 'false' } else { 'true' }
    $response = Invoke-PTRequest -Session $session -Path "/api/endpoints/$($session.EnvironmentId)/docker/containers/json?all=$all"
    foreach ($container in $response) {
        if ($null -eq $container) { continue }
        $containerId = [string](Get-PTField $container 'Id')
        $names = @(foreach ($item in (Get-PTField $container 'Names')) { ([string]$item).TrimStart('/') })
        if ($PSBoundParameters.ContainsKey('Id') -and $containerId -ne $Id) { continue }
        if ($PSBoundParameters.ContainsKey('Name') -and $Name.TrimStart('/') -notin $names) { continue }
        $labels = Get-PTField $container 'Labels'
        $stackName = [string](Get-PTField $labels 'com.docker.compose.project')
        if (-not $stackName) { $stackName = [string](Get-PTField $labels 'com.docker.stack.namespace') }
        [pscustomobject]@{
            PSTypeName = 'PortainerToolkit.Container'
            Id = $containerId
            Name = if ($names.Count -gt 0) { $names[0] } else { '' }
            Names = $names
            EnvironmentId = $session.EnvironmentId
            Image = [string](Get-PTField $container 'Image')
            ImageId = [string](Get-PTField $container 'ImageID')
            State = [string](Get-PTField $container 'State')
            Status = [string](Get-PTField $container 'Status')
            StackName = $stackName
        }
    }
}
