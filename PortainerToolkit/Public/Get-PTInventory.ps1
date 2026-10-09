#Requires -Version 7.0
function Get-PTInventory {
    <#
    .SYNOPSIS
    Returns a selected-metadata snapshot of the connected environment.
    .DESCRIPTION
    Combines stacks, all containers and image-use counts. Does not retrieve
    Compose, credentials, raw environment variables or raw labels. Images are
    references used by containers, not a list of unused Docker images or an
    update check. Calls are sequential and the snapshot is not transactional.
    .EXAMPLE
    $inventory = Get-PTInventory
    $inventory.Images | Format-Table Image, ImageId, ContainerCount
    #>
    [CmdletBinding()]
    param()
    $session = Get-PTSession
    $stacks = @(Get-PTStack)
    $containers = @(Get-PTContainer)
    $images = @(
        $containers | Group-Object -Property Image,ImageId | ForEach-Object {
            [pscustomobject]@{
                Image = $_.Group[0].Image
                ImageId = $_.Group[0].ImageId
                ContainerCount = $_.Count
            }
        } | Sort-Object Image,ImageId
    )
    [pscustomobject]@{
        PSTypeName = 'PortainerToolkit.Inventory'
        ToolkitVersion = '0.1.0'
        ServerUrl = $session.ServerUrl
        EnvironmentId = $session.EnvironmentId
        EnvironmentName = $session.EnvironmentName
        CollectedAtUtc = [datetime]::UtcNow
        Summary = [pscustomobject]@{
            StackCount = $stacks.Count
            ContainerCount = $containers.Count
            RunningContainerCount = @($containers | Where-Object State -EQ 'running').Count
            ImageReferenceCount = $images.Count
        }
        Stacks = $stacks
        Containers = $containers
        Images = $images
    }
}
