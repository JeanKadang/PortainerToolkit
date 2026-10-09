#Requires -Version 7.0
Import-Module (Join-Path $PSScriptRoot '..\..\PortainerToolkit\PortainerToolkit.psd1') -Force
BeforeAll { Import-Module (Join-Path $PSScriptRoot '..\..\PortainerToolkit\PortainerToolkit.psd1') -Force }
AfterAll { Remove-Module PortainerToolkit -ErrorAction SilentlyContinue }

Describe 'Local HTTP integration (synthetic server, no Portainer access)' {
    BeforeAll {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $port = $listener.LocalEndpoint.Port
        $baseUrl = "http://127.0.0.1:$port"
        $requests = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
        $state = [System.Collections.Concurrent.ConcurrentDictionary[string,string]]::new()
        $state['Mode'] = 'ok'
        $serverPowerShell = [powershell]::Create()
        $serverScript = {
            param($Listener, $Requests, $State, $Port)
            while ($true) {
                try { $client = $Listener.AcceptTcpClient() } catch { break }
                try {
                    $stream = $client.GetStream()
                    $stream.ReadTimeout = 5000
                    $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::ASCII, $false, 1024, $true)
                    $line = $reader.ReadLine()
                    if (-not $line) { continue }
                    $parts = $line.Split(' ')
                    $method = $parts[0]
                    $path = $parts[1]
                    $authOK = $false
                    while ($header = $reader.ReadLine()) {
                        if ($header -eq 'X-API-Key: synthetic-integration-token') { $authOK=$true }
                    }
                    $Requests.Enqueue([pscustomobject]@{Method=$method;Path=$path;AuthOK=$authOK})
                    $status = '200 OK'
                    $extra = ''
                    $mode = $State['Mode']
                    if ($mode -match '^error-(\d+)$') {
                        $status = "$($Matches[1]) Fixture"
                        $body = '{"message":"synthetic-integration-token sensitive-response"}'
                    } elseif ($mode -eq 'redirect') {
                        $status = '302 Found'
                        $extra = "Location: http://127.0.0.1:$Port/redirect-target" + [string][char]13 + [string][char]10
                        $body = '{}'
                    } else {
                        switch -Regex ($path) {
                            '^/api/endpoints/1$' { $body='{"Id":1,"Name":"fixture","Type":1,"Status":1}' }
                            '^/api/stacks$' { $body='[{"Id":10,"Name":"web","EndpointId":1,"Type":2,"Status":1,"EntryPoint":"compose.yml","Env":[{"name":"PASSWORD","value":"synthetic-secret"}]}]' }
                            '^/api/endpoints/1/docker/containers/json\?all=(true|false)$' {
                                $body='[{"Id":"aaaa","Names":["/web-1"],"Image":"nginx:1.27","ImageID":"sha256:aaa","State":"running","Status":"Up","Labels":{"com.docker.compose.project":"web","password":"synthetic-secret"}}]'
                            }
                            '^/api/stacks/10/file$' {
                                $body='{"StackFileContent":"services:\n  web:\n    image: nginx:1.27\n"}'
                                if ($mode -eq 'invalid-compose') { $body='{"StackFileContent":42}' }
                            }
                            default { $status='404 Not Found'; $body='{}' }
                        }
                        if ($mode -eq 'invalid-json') { $body = '{malformed json' }
                        if ($mode -eq 'empty' -and $path -ne '/api/endpoints/1') { $status='204 No Content'; $body='' }
                    }
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
                    $crlf = [string][char]13 + [string][char]10
                    $head = "HTTP/1.1 $status" + $crlf + $extra + 'Content-Type: application/json' + $crlf + "Content-Length: $($bytes.Length)" + $crlf + 'Connection: close' + $crlf + $crlf
                    $headBytes = [System.Text.Encoding]::ASCII.GetBytes($head)
                    $stream.Write($headBytes,0,$headBytes.Length)
                    $stream.Write($bytes,0,$bytes.Length)
                    $stream.Flush()
                    $reader.Dispose()
                } finally { $client.Dispose() }
            }
        }
        [void]$serverPowerShell.AddScript($serverScript.ToString()).AddArgument($listener).AddArgument($requests).AddArgument($state).AddArgument($port)
        $serverHandle = $serverPowerShell.BeginInvoke()
        $key = ConvertTo-SecureString 'synthetic-integration-token' -AsPlainText -Force
    }
    BeforeEach { $state['Mode']='ok'; $requests.Clear() }
    AfterAll {
        if ($listener) { $listener.Stop() }
        if ($serverPowerShell) {
            try { $serverPowerShell.EndInvoke($serverHandle) | Out-Null } finally { $serverPowerShell.Dispose() }
        }
        if ($key) { $key.Dispose() }
    }

    It 'runs all five commands through the real HTTP client using GET only' {
        $connection = Connect-PTServer -ServerUrl $baseUrl -EnvironmentId 1 -ApiKey $key -AllowHttp -WarningAction SilentlyContinue
        $connection.EnvironmentName | Should -Be 'fixture'
        (Get-PTStack).Name | Should -Be 'web'
        (Get-PTContainer).StackName | Should -Be 'web'
        Get-PTStackCompose -StackId 10 -WarningAction SilentlyContinue | Should -Match 'nginx:1.27'
        $inventory = Get-PTInventory
        $inventory.Stacks.Count | Should -Be 1
        $inventory.Containers.Count | Should -Be 1
        $inventory.Images.Count | Should -Be 1
        $requests.Count | Should -BeGreaterThan 0
        foreach ($request in $requests.ToArray()) {
            $request.Method | Should -Be 'GET'
            $request.AuthOK | Should -BeTrue
        }
        ($inventory | ConvertTo-Json -Depth 10) | Should -Not -Match 'synthetic-secret|synthetic-integration-token'
    }
    It 'reports HTTP <Status> without retaining sensitive response text' -ForEach @(
        @{Status=401}, @{Status=403}, @{Status=404}, @{Status=429}, @{Status=500}
    ) {
        $state['Mode']="error-$Status"
        $caught = $null
        try {
            Connect-PTServer -ServerUrl $baseUrl -EnvironmentId 1 -ApiKey $key -AllowHttp -WarningAction SilentlyContinue
        } catch { $caught=$_ }
        $caught | Should -Not -BeNullOrEmpty
        $caught.Exception.Message | Should -Match "HTTP $Status"
        $caught.Exception.Message | Should -Not -Match 'synthetic-integration-token|sensitive-response'
        $caught.Exception.InnerException | Should -BeNullOrEmpty
    }
    It 'does not follow HTTP redirects or forward a token to the redirect target' {
        $state['Mode']='redirect'
        { Connect-PTServer -ServerUrl $baseUrl -EnvironmentId 1 -ApiKey $key -AllowHttp -WarningAction SilentlyContinue } | Should -Throw '*request failed*'
        $requests.Count | Should -Be 1
        @($requests.ToArray() | Where-Object Path -EQ '/redirect-target').Count | Should -Be 0
    }
    It 'handles HTTP 204 as an empty inventory' {
        Connect-PTServer -ServerUrl $baseUrl -EnvironmentId 1 -ApiKey $key -AllowHttp -WarningAction SilentlyContinue | Out-Null
        $state['Mode']='empty'
        $inventory = Get-PTInventory
        $inventory.Summary.ContainerCount | Should -Be 0
        $inventory.Summary.StackCount | Should -Be 0
    }
    It 'rejects a non-text Compose response' {
        Connect-PTServer -ServerUrl $baseUrl -EnvironmentId 1 -ApiKey $key -AllowHttp -WarningAction SilentlyContinue | Out-Null
        $state['Mode']='invalid-compose'
        { Get-PTStackCompose -StackId 10 -WarningAction SilentlyContinue } | Should -Throw '*valid Compose text*'
    }
    It 'rejects malformed connection responses' {
        $state['Mode']='invalid-json'
        { Connect-PTServer -ServerUrl $baseUrl -EnvironmentId 1 -ApiKey $key -AllowHttp -WarningAction SilentlyContinue } | Should -Throw
    }
    It 'disposes its token on unload while leaving the caller token usable' {
        Connect-PTServer -ServerUrl $baseUrl -EnvironmentId 1 -ApiKey $key -AllowHttp -WarningAction SilentlyContinue | Out-Null
        $moduleToken = & (Get-Module PortainerToolkit) { $script:PTSession.ApiKey }
        Remove-Module PortainerToolkit
        { $moduleToken.Copy() } | Should -Throw
        $key.Length | Should -BeGreaterThan 0
        Import-Module (Join-Path $PSScriptRoot '..\..\PortainerToolkit\PortainerToolkit.psd1')
        $session = & (Get-Module PortainerToolkit) { $script:PTSession }
        $session | Should -BeNullOrEmpty
    }

}

