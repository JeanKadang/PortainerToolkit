#Requires -Version 7.0
Set-StrictMode -Version 3.0
$script:PTSession = $null

function Get-PTField {
    param([AllowNull()][object]$InputObject, [string]$Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) { return $InputObject[$Name] }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Get-PTSession {
    if ($null -eq $script:PTSession) {
        throw 'Connect-PTServer must succeed before running this command.'
    }
    return $script:PTSession
}

function Invoke-PTRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][string]$Path
    )
    # No method argument or arbitrary URL is exposed: only these GET routes are permitted.
    $environmentId = $Session.EnvironmentId
    $allowedPaths = @(
        "/api/endpoints/$environmentId",
        '/api/stacks',
        "/api/endpoints/$environmentId/docker/containers/json?all=true",
        "/api/endpoints/$environmentId/docker/containers/json?all=false"
    )
    if ($Path -cnotin $allowedPaths -and $Path -cnotmatch '\A/api/stacks/[1-9][0-9]*/file\z') {
        throw 'The route is outside the read-only PortainerToolkit allowlist.'
    }

    $pointer = [IntPtr]::Zero
    $plainText = $null
    $headers = @{}
    try {
        # A plaintext managed string is necessary for the HTTP header; never output or persist it.
        $pointer = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Session.ApiKey)
        $plainText = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        $headers['X-API-Key'] = $plainText
        $headers['Accept'] = 'application/json'
        $result = Invoke-RestMethod -Uri ($Session.ServerUrl + $Path) -Method Get -Headers $headers -TimeoutSec $Session.TimeoutSec -MaximumRedirection 0 -ErrorAction Stop -Verbose:$false -Debug:$false
        # HTTP 204 can be represented as an empty string by PowerShell's HTTP client.
        if ($null -eq $result -or ($result -is [string] -and [string]::IsNullOrWhiteSpace($result))) { return }
        return $result
    } catch {
        $status = $null
        $response = Get-PTField -InputObject $_.Exception -Name 'Response'
        if ($null -ne $response) { $status = Get-PTField -InputObject $response -Name 'StatusCode' }
        $message = 'Portainer GET request failed'
        if ($null -ne $status) { $message += " (HTTP $([int]$status))" }
        $message += '. Check the address, certificate, API token, environment access and server availability. Redirects are blocked.'
        # Do not retain an inner exception, response body, request headers or secret target object.
        $exception = [System.InvalidOperationException]::new($message)
        $record = [System.Management.Automation.ErrorRecord]::new(
            $exception, 'PTRequestFailed', [System.Management.Automation.ErrorCategory]::ConnectionError, $null
        )
        $PSCmdlet.ThrowTerminatingError($record)
    } finally {
        $headers.Clear()
        $plainText = $null
        if ($pointer -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    }
}

function Connect-PTServer {
    <#
    .SYNOPSIS
    Connects to one Portainer environment using an in-memory API token.
    .DESCRIPTION
    Prompts with Read-Host -AsSecureString when ApiKey is omitted. Uses one GET
    to validate access. HTTPS is required unless AllowHttp is explicitly set.
    A successful reconnect replaces the previous session. A failed reconnect
    preserves it. Returned metadata never contains the token.
    .PARAMETER ServerUrl
    Portainer base URL; an optional reverse proxy prefix and trailing /api are supported.
    .PARAMETER EnvironmentId
    Positive Portainer environment (endpoint) ID.
    .PARAMETER ApiKey
    An optional SecureString token. Plain text tokens are not accepted.
    .PARAMETER AllowHttp
    Explicitly permits unencrypted HTTP, with a warning. Prefer trusted HTTPS.
    .PARAMETER TimeoutSec
    Request timeout in seconds, from 1 to 300. Default is 30.
    .EXAMPLE
    Connect-PTServer -ServerUrl 'https://portainer.example:9443' -EnvironmentId 1
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ServerUrl,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$EnvironmentId,
        [System.Security.SecureString]$ApiKey,
        [switch]$AllowHttp,
        [ValidateRange(1,300)][int]$TimeoutSec = 30
    )

    $uri = $null
    if (-not [uri]::TryCreate($ServerUrl, [System.UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('https','http')) {
        throw 'ServerUrl must be an absolute HTTP or HTTPS URL.'
    }
    if ($uri.UserInfo -or $uri.Query -or $uri.Fragment) {
        throw 'ServerUrl must not contain credentials, a query string or a fragment.'
    }
    if ($uri.Scheme -eq 'http') {
        if (-not $AllowHttp) { throw 'HTTP requires -AllowHttp. Use HTTPS to protect the API token.' }
        Write-Warning 'HTTP sends the API token and responses unencrypted. Use HTTPS with a trusted certificate.'
    }
    $baseUrl = $uri.GetLeftPart([System.UriPartial]::Path).TrimEnd('/')
    if ($baseUrl.EndsWith('/api', [System.StringComparison]::OrdinalIgnoreCase)) {
        $baseUrl = $baseUrl.Substring(0, $baseUrl.Length - 4)
    }

    $prompted = $false
    if ($null -eq $ApiKey) {
        $ApiKey = Read-Host -Prompt 'Portainer API access token (kept in memory only)' -AsSecureString
        $prompted = $true
    }
    $candidate = $null
    $connected = $false
    try {
        if ($null -eq $ApiKey -or $ApiKey.Length -eq 0) { throw 'An API token is required and cannot be empty.' }
        $keyCopy = $ApiKey.Copy()
        $keyCopy.MakeReadOnly()
        $candidate = @{
            ServerUrl = $baseUrl
            EnvironmentId = $EnvironmentId
            EnvironmentName = $null
            ApiKey = $keyCopy
            TimeoutSec = $TimeoutSec
        }
        $environment = Invoke-PTRequest -Session $candidate -Path "/api/endpoints/$EnvironmentId"
        if ((Get-PTField $environment 'Id') -ne $EnvironmentId) {
            throw 'Portainer returned an invalid environment response. Connection was not changed.'
        }
        $candidate.EnvironmentName = [string](Get-PTField $environment 'Name')
        if ($null -ne $script:PTSession) { $script:PTSession.ApiKey.Dispose() }
        $script:PTSession = $candidate
        $connected = $true
        [pscustomobject]@{
            PSTypeName = 'PortainerToolkit.Connection'
            ServerUrl = $baseUrl
            EnvironmentId = $EnvironmentId
            EnvironmentName = $candidate.EnvironmentName
            Transport = $uri.Scheme
            ReadOnly = $true
        }
    } finally {
        if (-not $connected -and $null -ne $candidate) { $candidate.ApiKey.Dispose() }
        if ($prompted -and $null -ne $ApiKey) { $ApiKey.Dispose() }
    }
}

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

# Remove-Module releases our SecureString copy. Nothing is saved to disk.
$ExecutionContext.SessionState.Module.OnRemove = {
    if ($null -ne $script:PTSession) {
        $script:PTSession.ApiKey.Dispose()
        $script:PTSession = $null
    }
}
Export-ModuleMember -Function Connect-PTServer,Get-PTStack,Get-PTContainer,Get-PTStackCompose,Get-PTInventory

