#Requires -Version 7.0
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
