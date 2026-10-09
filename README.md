# PortainerToolkit v0.1.0

A small, read-only Portainer toolkit for Windows PowerShell 7. The toolkit
never creates GitHub repositories or Git commits and makes no Portainer changes.

## Requirements

- Windows and PowerShell 7.0 or newer (`pwsh`).
- A reachable Portainer server and a Portainer **API access token** with access
  to the chosen environment. This is an access token, not a username/password
  or a JWT.
- Pester 5.7.1 or newer to run tests. The module itself has no external dependencies.

## Start here

Run this in an interactive PowerShell 7 terminal:

```powershell
Import-Module C:\OpenAI\PortainerToolkit\PortainerToolkit.psd1

# Example address; HTTP requires explicit opt-in.
# The next command prompts securely for your API access token.
Connect-PTServer -ServerUrl 'http://portainer.example:9000' -EnvironmentId 1 -AllowHttp

Get-PTStack | Format-Table Id, Name, Type, Status
Get-PTContainer | Format-Table Name, Image, State, Status, StackName

$inventory = Get-PTInventory
$inventory.Summary
$inventory.Images | Format-Table Image, ImageId, ContainerCount

# Release the toolkit's in-memory token when finished.
Remove-Module PortainerToolkit
```

**Recommend HTTPS with a trusted certificate.** For example, use your actual
HTTPS hostname and port in place of `https://portainer.example:9443`.
That example URL is a placeholder; HTTPS has not been verified on your server.
A secure prompt hides the token during entry, but HTTP still sends it
unencrypted over the network. The toolkit does not bypass certificate validation.

## Commands

| Command | Behavior | Optional filters |
| --- | --- | --- |
| `Connect-PTServer` | Securely prompts for an API token, validates the selected environment with GET, and stores one session in memory. Returns connection metadata without the token. | `-ApiKey <SecureString>`, `-AllowHttp`, `-TimeoutSec 1..300` |
| `Get-PTStack` | Selected metadata for Portainer-managed stacks in the connected environment. Excludes raw Env and Git configuration. | `-Id`, `-Name` |
| `Get-PTContainer` | Selected Docker container metadata; includes stopped containers by default. Excludes raw labels, mounts and configuration. | `-Id`, `-Name`, `-RunningOnly` |
| `Get-PTStackCompose` | Verifies stack membership, then returns the original Compose text in memory. Warns about sensitive content. | Required `-StackId` |
| `Get-PTInventory` | Object with metadata, UTC collection time, Summary, Stacks, Containers and Images. Does not fetch Compose. | None |

Name and container ID filters are exact and case-insensitive; names do not
expand wildcards. Container IDs must be complete. Stack Type and Status retain
the numeric values returned by Portainer. `StackName` uses Docker Compose's
project label or a Swarm stack namespace label.

```powershell
Get-PTStack -Name 'web'
Get-PTContainer -RunningOnly
Get-PTContainer -Name 'web-1'

# Compose can contain passwords and tokens. Assign it rather than printing it.
$compose = Get-PTStackCompose -StackId 10
# Inspect locally only when appropriate. Nothing is saved automatically.
$compose = $null

Get-Help Connect-PTServer -Full
Get-Help Get-PTInventory -Full
```

## Configuration without secrets

The template `config\portainer.example.json` contains only a server URL,
environment ID, timeout and HTTP opt-in. Copy it to a local configuration file:

```powershell
Set-Location C:\OpenAI\PortainerToolkit
Copy-Item .\config\portainer.example.json .\config\portainer.local.json
# Edit portainer.local.json with your address. Set AllowHttp to true only for HTTP.

$config = Get-Content .\config\portainer.local.json -Raw | ConvertFrom-Json -AsHashtable
Import-Module .\PortainerToolkit.psd1
Connect-PTServer @config
```

The module does not load configuration automatically. **Never add an API key,
password or token to configuration.** `Connect-PTServer` prompts for the token
when `-ApiKey` is omitted. If supplying a token from your own process, use a
SecureString created with `Read-Host -AsSecureString`; do not put plaintext
tokens in scripts, command history, environment variables or command arguments.

A successful reconnect disposes the previous toolkit token and selects the new
environment. A failed reconnect preserves the previous session. The toolkit
copies a caller-supplied SecureString and does not dispose the caller's original.

## Read-only and privacy safeguards

- The private HTTP helper exposes no method parameter and uses GET only.
- Routes are allowlisted: environment inspection, stack listing, stack file
  retrieval, and Docker container listing in the selected environment.
- Redirects are blocked to avoid forwarding an API token elsewhere. No TLS
  validation bypass, login POST, deployment, update, restart, pull or delete exists.
- Tokens remain as SecureString objects in module memory. A temporary plaintext
  HTTP header is unavoidable; its references are cleared and its unmanaged
  buffer is zeroed after each request. Managed strings and HTTP internals cannot
  be guaranteed to be immediately erased. This is not a credential vault.
- No token, header, raw API response or export is logged or saved by the module.
  Error messages omit response bodies and underlying exception details.
- Stack/container outputs select fields rather than exposing raw responses.
  Names, image references and inventory metadata can still be confidential.
- Compose text is returned **unredacted** to preserve its exact contents. It can
  contain secrets. Avoid transcripts, console logs, shared captures and commits
  when retrieving it. Inventory does not fetch it.
- Use the least-privileged Portainer identity available. This client's GET-only
  behavior does not reduce the server-side permissions of its API token.
- `.gitignore` excludes local config, exports, logs, JSON/text/YAML data and common
  credential file types. It is a precaution, not a guarantee against committing
  secrets. Review staged files before any future commit. No sensitive exports
  are supplied with this project.

## Tests

From the project folder:

```powershell
pwsh -NoProfile -File .\Test-PTToolkit.ps1
```

The runner checks PowerShell syntax and module manifest, then runs Pester.
Tests use synthetic tokens, mocked API responses and a loopback-only HTTP
fixture built with PowerShell runspaces. They do not connect to your Portainer
server and require neither a real token nor ThreadJob. Fixture data contains
only deliberate fake secret markers used to verify exclusion.

If Pester 5.7.1+ is missing, install it using your preferred PowerShell module
management process, then rerun. The test runner never installs dependencies.

## Limitations and troubleshooting

- v0.1 targets Docker environments. Container listing will not work against a
  Kubernetes-only environment. Docker Engine/Portainer version compatibility
  still needs a live authenticated check on your server.
- Stack listing returns only stacks Portainer manages and the current identity
  can access. External/limited stacks might appear only as containers. It does
  not retrieve all files from Git-backed stacks or referenced includes.
- Images are grouped from container references and image IDs. Unused Docker
  images, registry versions and update availability are outside v0.1.
- Inventory requests are sequential, so a changing server can produce a snapshot
  collected at slightly different times. A request failure terminates inventory;
  the toolkit does not silently return a partial inventory.
- A 401 usually means the token is invalid; a 403 indicates insufficient access;
  a 404 may mean a missing stack/environment or wrong base URL. Check Portainer
  locally. Redirects, invalid certificates and unavailable servers also fail.
- Default timeout is 30 seconds; `-TimeoutSec` uses PowerShell's connection timeout
  option. DNS lookup and established-transfer behavior can vary by PowerShell
  version. This is not a strict wall-clock deadline.
- Removing the module or ending PowerShell drops its token. The toolkit cannot
  erase tokens or sensitive output that other tools captured.

API references: [Portainer API authentication](https://docs.portainer.io/api/access),
[Docker container listing through Portainer](https://docs.portainer.io/sts/api/examples),
[stack-file GET handler](https://github.com/portainer/portainer/blob/develop/api/http/handler/stacks/stack_file.go).

