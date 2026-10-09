#Requires -Version 7.0
Import-Module (Join-Path $PSScriptRoot '..\..\PortainerToolkit\PortainerToolkit.psd1') -Force
BeforeAll { Import-Module (Join-Path $PSScriptRoot '..\..\PortainerToolkit\PortainerToolkit.psd1') -Force }
AfterAll { Remove-Module PortainerToolkit -ErrorAction SilentlyContinue }

Describe 'PortainerToolkit read-only behavior' {
    InModuleScope PortainerToolkit {
        BeforeEach {
            if ($script:PTSession) { $script:PTSession.ApiKey.Dispose() }
            $script:PTSession = $null
            $script:Calls = [System.Collections.Generic.List[object]]::new()
            $script:FixtureKey = ConvertTo-SecureString 'synthetic-test-token' -AsPlainText -Force
            $script:Stacks = @(
                [pscustomobject]@{ Id=10; Name='web'; EndpointId=1; Type=2; Status=1; EntryPoint='compose.yml'; Env=@(@{name='PASSWORD';value='synthetic-secret'}); GitConfig=@{Password='synthetic-secret'} },
                [pscustomobject]@{ Id=20; Name='other'; EndpointId=2; Type=2; Status=1 },
                [pscustomobject]@{ Id=30; Name='swarm'; EndpointId=1; Type=1; Status=1; EntryPoint='stack.yml' }
            )
            $script:Containers = @(
                [pscustomobject]@{ Id='aaaa'; Names=@('/web-1'); Image='nginx:1.27'; ImageID='sha256:aaa'; State='running'; Status='Up'; Labels=@{'com.docker.compose.project'='web';password='synthetic-secret'}; Mounts=@(@{Source='private'}) },
                [pscustomobject]@{ Id='bbbb'; Names=@('/worker-1'); Image='nginx:1.27'; ImageID='sha256:aaa'; State='exited'; Status='Exited'; Labels=@{} },
                [pscustomobject]@{ Id='cccc'; Names=@('/swarm.1'); Image='busybox:1'; ImageID='sha256:bbb'; State='running'; Status='Up'; Labels=@{'com.docker.stack.namespace'='swarm'} }
            )
            Mock Read-Host { $script:FixtureKey }
            Mock Invoke-RestMethod {
                param($Uri, $Method, $Headers, $MaximumRedirection, $TimeoutSec, $ConnectionTimeoutSeconds)
                $script:Calls.Add([pscustomobject]@{
                    Uri=[string]$Uri; Method=[string]$Method; Redirections=$MaximumRedirection
                    Timeout=$(if ($null -ne $TimeoutSec) { $TimeoutSec } else { $ConnectionTimeoutSeconds }); AuthOK=($Headers['X-API-Key'] -eq 'synthetic-test-token')
                })
                switch -Regex ([string]$Uri) {
                    '/api/endpoints/1$' { return [pscustomobject]@{ Id=1; Name='local'; Type=1; Status=1; TLSConfig=@{TLSKey='synthetic-secret'} } }
                    '/api/stacks/10/file$' { return [pscustomobject]@{ StackFileContent=([string]::Join([Environment]::NewLine, @('services:', '  web:', '    image: nginx:1.27'))) } }
                    '/api/stacks$' { return $script:Stacks }
                    '/api/endpoints/1/docker/containers/json\?all=true$' { return $script:Containers }
                    '/api/endpoints/1/docker/containers/json\?all=false$' { return @($script:Containers | Where-Object State -EQ 'running') }
                    default { throw 'Unexpected test route' }
                }
            }
        }
        AfterEach {
            if ($script:PTSession) { $script:PTSession.ApiKey.Dispose(); $script:PTSession=$null }
            $script:FixtureKey.Dispose()
        }

        It 'connects with a secure prompt and returns only safe connection metadata' {
            $connection = Connect-PTServer -ServerUrl 'https://portainer.example' -EnvironmentId 1
            Should -Invoke Read-Host -Times 1 -Exactly -ParameterFilter { $AsSecureString }
            $connection.EnvironmentId | Should -Be 1
            $connection.EnvironmentName | Should -Be 'local'
            ($connection | ConvertTo-Json -Depth 8) | Should -Not -Match 'synthetic|ApiKey|TLSKey'
            $script:Calls[0].AuthOK | Should -BeTrue
        }
        It 'does not require a prompt when passed a SecureString' {
            Connect-PTServer -ServerUrl 'https://portainer.example' -EnvironmentId 1 -ApiKey $script:FixtureKey | Out-Null
            Should -Invoke Read-Host -Times 0
            $script:FixtureKey.Length | Should -BeGreaterThan 0
        }
        It 'rejects a plain text API key' {
            { Connect-PTServer -ServerUrl 'https://portainer.example' -EnvironmentId 1 -ApiKey 'unsafe' } | Should -Throw
            $script:Calls.Count | Should -Be 0
        }
        It 'requires explicit opt-in to HTTP before prompting or sending a token' {
            { Connect-PTServer -ServerUrl 'http://portainer.example:9000' -EnvironmentId 1 } | Should -Throw '*AllowHttp*'
            Should -Invoke Read-Host -Times 0
            $script:Calls.Count | Should -Be 0
        }
        It 'warns about unencrypted HTTP when explicitly enabled' {
            $warnings = @()
            Connect-PTServer -ServerUrl 'http://portainer.example:9000' -EnvironmentId 1 -ApiKey $script:FixtureKey -AllowHttp -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null
            ($warnings -join ' ') | Should -Match 'HTTPS'
            $script:Calls[0].Uri | Should -Be 'http://portainer.example:9000/api/endpoints/1'
        }
        It 'normalizes a reverse proxy prefix with a trailing API suffix' {
            Connect-PTServer -ServerUrl 'https://portainer.example/tools/api/' -EnvironmentId 1 -ApiKey $script:FixtureKey | Out-Null
            $script:Calls[0].Uri | Should -Be 'https://portainer.example/tools/api/endpoints/1'
        }
        It 'rejects URLs containing credentials, query strings or fragments' -ForEach @(
            @{ Url='https://user:password@portainer.example' },
            @{ Url='https://portainer.example/?token=unsafe' },
            @{ Url='https://portainer.example/#fragment' },
            @{ Url='ftp://portainer.example' }
        ) {
            { Connect-PTServer -ServerUrl $Url -EnvironmentId 1 -ApiKey $script:FixtureKey } | Should -Throw
            $script:Calls.Count | Should -Be 0
        }
        It 'rejects invalid environment IDs and empty secure tokens' {
            { Connect-PTServer -ServerUrl 'https://portainer.example' -EnvironmentId 0 -ApiKey $script:FixtureKey } | Should -Throw
            $empty = [System.Security.SecureString]::new()
            try {
                { Connect-PTServer -ServerUrl 'https://portainer.example' -EnvironmentId 1 -ApiKey $empty } | Should -Throw
            } finally { $empty.Dispose() }
            $script:Calls.Count | Should -Be 0
        }
        It 'requires a connection before reading data' {
            { Get-PTStack } | Should -Throw '*Connect-PTServer*'
            { Get-PTContainer } | Should -Throw '*Connect-PTServer*'
            { Get-PTStackCompose -StackId 10 } | Should -Throw '*Connect-PTServer*'
            { Get-PTInventory } | Should -Throw '*Connect-PTServer*'
            $script:Calls.Count | Should -Be 0
        }
        It 'limits stack results to the selected environment including Swarm stacks' {
            Connect-PTServer -ServerUrl 'https://portainer.example' -EnvironmentId 1 -ApiKey $script:FixtureKey | Out-Null
            $stacks = @(Get-PTStack)
            $stacks.Count | Should -Be 2
            @($stacks.Id) | Should -Contain 10
            @($stacks.Id) | Should -Contain 30
            @($stacks.Id) | Should -Not -Contain 20
            ($stacks | ConvertTo-Json -Depth 8) | Should -Not -Match 'synthetic-secret|GitConfig|"Env"'
        }
        It 'supports exact stack name and ID filters' {
            Connect-PTServer -ServerUrl 'https://portainer.example' -EnvironmentId 1 -ApiKey $script:FixtureKey | Out-Null
            @(Get-PTStack -Name web).Count | Should -Be 1
            (Get-PTStack -Id 30).Name | Should -Be 'swarm'
            @(Get-PTStack -Name 'w*').Count | Should -Be 0
            @(Get-PTStack -Id 20).Count | Should -Be 0
        }
        It 'lists stopped containers by default and omits arbitrary labels and mounts' {
            Connect-PTServer -ServerUrl 'https://portainer.example' -EnvironmentId 1 -ApiKey $script:FixtureKey | Out-Null
            $containers = @(Get-PTContainer)
            $containers.Count | Should -Be 3
            $containers[0].Name | Should -Be 'web-1'
            $containers[0].StackName | Should -Be 'web'
            $containers[2].StackName | Should -Be 'swarm'
            ($containers | ConvertTo-Json -Depth 8) | Should -Not -Match 'synthetic-secret|Mounts|"Labels"'
        }
        It 'supports running-only and exact container filters' {
            Connect-PTServer -ServerUrl 'https://portainer.example' -EnvironmentId 1 -ApiKey $script:FixtureKey | Out-Null
            @(Get-PTContainer -RunningOnly).Count | Should -Be 2
            (Get-PTContainer -Id bbbb).State | Should -Be 'exited'
            (Get-PTContainer -Name web-1).Id | Should -Be 'aaaa'
            @(Get-PTContainer -Name 'web*').Count | Should -Be 0
        }
        It 'retrieves Compose as text with a sensitive-content warning' {
            Connect-PTServer -ServerUrl 'https://portainer.example' -EnvironmentId 1 -ApiKey $script:FixtureKey | Out-Null
            $warnings = @()
            $compose = Get-PTStackCompose -StackId 10 -WarningVariable warnings -WarningAction SilentlyContinue
            $compose | Should -BeOfType ([string])
            $compose | Should -Match 'image: nginx:1.27'
            ($warnings -join ' ') | Should -Match 'secret'
        }
        It 'rejects Compose requests for another environment or a missing stack before fetching the file' -ForEach @(
            @{ Stack=20 }, @{ Stack=999 }
        ) {
            Connect-PTServer -ServerUrl 'https://portainer.example' -EnvironmentId 1 -ApiKey $script:FixtureKey | Out-Null
            { Get-PTStackCompose -StackId $Stack -WarningAction SilentlyContinue } | Should -Throw '*not found*'
            @($script:Calls | Where-Object Uri -Match '/file').Count | Should -Be 0
        }
        It 'builds a sanitized inventory with arrays and image-use counts without reading Compose' {
            Connect-PTServer -ServerUrl 'https://portainer.example' -EnvironmentId 1 -ApiKey $script:FixtureKey | Out-Null
            $inventory = Get-PTInventory
            $inventory.Stacks.Count | Should -Be 2
            $inventory.Containers.Count | Should -Be 3
            $inventory.Images.Count | Should -Be 2
            ($inventory.Images | Where-Object Image -EQ 'nginx:1.27').ContainerCount | Should -Be 2
            $inventory.Summary.RunningContainerCount | Should -Be 2
            $inventory.CollectedAtUtc | Should -BeOfType ([datetime])
            ($inventory | ConvertTo-Json -Depth 12) | Should -Not -Match 'synthetic-secret|ApiKey|StackFileContent'
            @($script:Calls | Where-Object Uri -Match '/file').Count | Should -Be 0
        }
        It 'preserves empty inventory collections as arrays' {
            $script:Stacks=@(); $script:Containers=@()
            Connect-PTServer -ServerUrl 'https://portainer.example' -EnvironmentId 1 -ApiKey $script:FixtureKey | Out-Null
            $inventory = Get-PTInventory
            Should -ActualValue $inventory.Stacks -BeOfType ([array])
            Should -ActualValue $inventory.Containers -BeOfType ([array])
            Should -ActualValue $inventory.Images -BeOfType ([array])
            $inventory.Summary.ContainerCount | Should -Be 0
        }
        It 'uses GET only with redirect protection and a bounded timeout' {
            Connect-PTServer -ServerUrl 'https://portainer.example' -EnvironmentId 1 -ApiKey $script:FixtureKey -TimeoutSec 12 | Out-Null
            Get-PTInventory | Out-Null
            Get-PTStackCompose -StackId 10 -WarningAction SilentlyContinue | Out-Null
            foreach ($call in $script:Calls) {
                $call.Method | Should -Be 'Get'
                $call.Redirections | Should -Be 0
                $call.Timeout | Should -Be 12
                $call.AuthOK | Should -BeTrue
            }
        }
        It 'blocks non-allowlisted routes before contacting the server' {
            Connect-PTServer -ServerUrl 'https://portainer.example' -EnvironmentId 1 -ApiKey $script:FixtureKey | Out-Null
            $before = $script:Calls.Count
            { Invoke-PTRequest -Session $script:PTSession -Path '/api/endpoints/1/docker/containers/aaaa/start' } | Should -Throw '*read-only*'
            { Invoke-PTRequest -Session $script:PTSession -Path 'https://attacker.example/api/stacks' } | Should -Throw '*read-only*'
            { Invoke-PTRequest -Session $script:PTSession -Path '/api/endpoints/2/docker/containers/json?all=true' } | Should -Throw '*read-only*'
            $script:Calls.Count | Should -Be $before
        }
        It 'keeps the previous connection when reconnect validation fails' {
            Connect-PTServer -ServerUrl 'https://portainer.example' -EnvironmentId 1 -ApiKey $script:FixtureKey | Out-Null
            Mock Invoke-RestMethod { throw 'synthetic-test-token sensitive-response' }
            { Connect-PTServer -ServerUrl 'https://broken.example' -EnvironmentId 1 -ApiKey $script:FixtureKey } | Should -Throw '*request failed*'
            $script:PTSession.ServerUrl | Should -Be 'https://portainer.example'
            $script:PTSession.ApiKey.Length | Should -BeGreaterThan 0
        }
        It 'sanitizes transport error text instead of exposing headers or response content' {
            Connect-PTServer -ServerUrl 'https://portainer.example' -EnvironmentId 1 -ApiKey $script:FixtureKey | Out-Null
            Mock Invoke-RestMethod { throw 'synthetic-test-token sensitive-response' }
            $caught = $null
            try { Get-PTContainer } catch { $caught = $_ }
            $caught | Should -Not -BeNullOrEmpty
            $caught.Exception.Message | Should -Match 'request failed'
            $caught.Exception.Message | Should -Not -Match 'synthetic-test-token|sensitive-response'
            $caught.Exception.InnerException | Should -BeNullOrEmpty
        }
        It 'does not commit a malformed or wrong-environment connection' {
            Mock Invoke-RestMethod { [pscustomobject]@{ Id=2;Name='wrong' } }
            { Connect-PTServer -ServerUrl 'https://portainer.example' -EnvironmentId 1 -ApiKey $script:FixtureKey } | Should -Throw '*environment*'
            $script:PTSession | Should -BeNullOrEmpty
        }
        It 'exports exactly the five requested commands' {
            (Get-Module PortainerToolkit).ExportedFunctions.Count | Should -Be 5
            foreach ($name in @('Connect-PTServer','Get-PTStack','Get-PTContainer','Get-PTStackCompose','Get-PTInventory')) {
                Get-Command $name -Module PortainerToolkit | Should -Not -BeNullOrEmpty
            }
        }
    }
}
