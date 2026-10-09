#Requires -Version 7.0
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
