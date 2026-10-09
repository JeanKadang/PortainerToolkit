@{
    RootModule = 'PortainerToolkit.psm1'
    ModuleVersion = '0.1.0'
    GUID = '2dded2a9-2b6f-4b7b-9d60-f8977c51c0de'
    Author = 'PortainerToolkit contributors'
    Description = 'Read-only Portainer inventory toolkit with in-memory API token authentication.'
    PowerShellVersion = '7.0'
    CompatiblePSEditions = @('Core')
    FunctionsToExport = @('Connect-PTServer','Get-PTStack','Get-PTContainer','Get-PTStackCompose','Get-PTInventory')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{ PSData = @{ Tags = @('Portainer','ReadOnly','Windows','PowerShell7') } }
}

