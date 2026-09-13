#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Selects an Azure tenant and subscription, prepares its azd environment,
    and runs azd up.
.DESCRIPTION
    Stores non-secret Azure target metadata in the current user's profile so
    multiple tenants and subscriptions can be used from the same repository.
    Azure CLI and azd credentials are handled by their own login commands and
    are never written to the profile file.
.PARAMETER ProfilePath
    Path to the local target catalog. Defaults to a file under the user's
    profile directory.
.EXAMPLE
    .\Start-Azd-Migration.ps1

    Selects or creates a target, prepares its azd environment, and runs azd up.
.EXAMPLE
    .\Start-Azd-Migration.ps1 -WhatIf

    Selects or creates a target and shows the azd up action without running it.
.NOTES
    Requires Azure CLI, Azure Developer CLI, and an interactive PowerShell
    session. The profile file contains tenant and subscription IDs, which are
    identifiers rather than credentials.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ProfilePath = (Join-Path $HOME '.eklee-keyvault\azd-targets.json')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

#region Functions

function Test-CommandAvailable {
    <# .SYNOPSIS Checks that a required command is available. #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$CommandName
    )

    if (-not (Get-Command $CommandName -ErrorAction SilentlyContinue)) {
        throw "Required command '$CommandName' was not found on PATH."
    }
}

function Invoke-ExternalCommand {
    <# .SYNOPSIS Runs a command and stops when it fails. #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$CommandName,

        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [string[]]$Arguments = @()
    )

    & $CommandName @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE`: $CommandName $($Arguments -join ' ')"
    }
}

function Read-GuidValue {
    <# .SYNOPSIS Reads and validates a GUID from the console. #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Prompt
    )

    while ($true) {
        $value = (Read-Host $Prompt).Trim()
        $parsedValue = [guid]::Empty
        if ([guid]::TryParse($value, [ref]$parsedValue)) {
            return $parsedValue.ToString()
        }

        Write-Warning 'Enter a valid GUID.'
    }
}

function Read-RequiredValue {
    <# .SYNOPSIS Reads a required string from the console. #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Prompt,

        [Parameter(Mandatory = $false)]
        [string]$DefaultValue
    )

    while ($true) {
        $promptText = $Prompt
        if ($DefaultValue) {
            $promptText = "$Prompt [$DefaultValue]"
        }

        $value = (Read-Host $promptText).Trim()
        if (-not $value -and $DefaultValue) {
            $value = $DefaultValue
        }

        if ($value) {
            return $value
        }

        Write-Warning 'A value is required.'
    }
}

function Read-YesNoValue {
    <# .SYNOPSIS Reads a Yes or No value from the console. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Prompt,

        [Parameter(Mandatory = $false)]
        [bool]$DefaultValue = $false
    )

    $defaultText = if ($DefaultValue) { 'Y' } else { 'N' }
    while ($true) {
        $value = (Read-Host "$Prompt (Y/N) [$defaultText]").Trim()
        if (-not $value) {
            return $DefaultValue
        }

        if ($value -match '^[Yy](es)?$') {
            return $true
        }

        if ($value -match '^[Nn](o)?$') {
            return $false
        }

        Write-Warning 'Enter Y or N.'
    }
}

function ConvertTo-EnvironmentName {
    <# .SYNOPSIS Converts a display name to a usable azd environment name. #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $environmentName = $Value.ToLowerInvariant() -replace '[^a-z0-9-]', '-'
    $environmentName = $environmentName -replace '-+', '-'
    $environmentName = $environmentName.Trim('-')
    if (-not $environmentName) {
        $environmentName = 'azure-target'
    }

    return $environmentName.Substring(0, [Math]::Min(32, $environmentName.Length))
}

function Read-Target {
    <# .SYNOPSIS Collects a tenant and subscription target from the console. #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $displayName = Read-RequiredValue -Prompt 'Target display name'
    $tenantId = Read-GuidValue -Prompt 'Tenant ID'
    $subscriptionId = Read-GuidValue -Prompt 'Subscription ID'
    $environmentDefault = ConvertTo-EnvironmentName -Value $displayName
    $environmentName = Read-RequiredValue -Prompt 'azd environment name' -DefaultValue $environmentDefault
    $location = Read-RequiredValue -Prompt 'Azure location' -DefaultValue 'centralus'
    $prefix = Read-RequiredValue -Prompt 'Resource prefix (3-10 lowercase characters)' -DefaultValue $environmentName
    $resourceGroupName = Read-RequiredValue -Prompt 'Azure resource group name' -DefaultValue "$prefix-rg"
    $enablePrivateNetworking = Read-YesNoValue -Prompt 'Enable private networking' -DefaultValue $false
    $appRegistrationName = Read-RequiredValue -Prompt 'App registration name' -DefaultValue "$prefix-app"

    if ($prefix -notmatch '^[a-z0-9]{3,10}$') {
        throw "Resource prefix '$prefix' must contain 3-10 lowercase letters or numbers."
    }

    if ($resourceGroupName -notmatch '^[a-zA-Z0-9._()\-]{1,90}$') {
        throw "Resource group name '$resourceGroupName' contains unsupported characters or is longer than 90 characters."
    }

    if ($environmentName -notmatch '^[a-z0-9][a-z0-9-]{0,31}$') {
        throw "azd environment name '$environmentName' must contain lowercase letters, numbers, or hyphens."
    }

    return [ordered]@{
        displayName     = $displayName
        tenantId        = $tenantId
        subscriptionId  = $subscriptionId
        environmentName = $environmentName
        location        = $location
        prefix          = $prefix
        resourceGroupName = $resourceGroupName
        enablePrivateNetworking = $enablePrivateNetworking
        appRegistrationName = $appRegistrationName
    }
}

function Save-TargetCatalog {
    <# .SYNOPSIS Writes the target catalog to the user's profile. #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Targets
    )

    $parentPath = Split-Path -Parent $Path
    if ($parentPath) {
        New-Item -ItemType Directory -Path $parentPath -Force | Out-Null
    }

    $catalog = [ordered]@{
        version = 5
        targets = @($Targets)
    }
    $temporaryPath = "$Path.$([guid]::NewGuid()).tmp"
    try {
        $catalog | ConvertTo-Json -Depth 5 | Set-Content -Path $temporaryPath -Encoding utf8
        Move-Item -Path $temporaryPath -Destination $Path -Force
    }
    finally {
        Remove-Item $temporaryPath -ErrorAction SilentlyContinue
    }
}

function Get-TargetCatalog {
    <# .SYNOPSIS Loads the target catalog from the user's profile. #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        return @()
    }

    try {
        $catalog = Get-Content -Path $Path -Raw | ConvertFrom-Json
        return @($catalog.targets)
    }
    catch {
        throw "Could not read target catalog '$Path': $($_.Exception.Message)"
    }
}

function Select-Target {
    <# .SYNOPSIS Displays the target menu and returns the selected target. #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Targets
    )

    while ($true) {
        Write-Host ''
        Write-Host 'Choose an Azure target:' -ForegroundColor Cyan
        for ($index = 0; $index -lt $Targets.Count; $index++) {
            $target = $Targets[$index]
            $resourceGroupProperty = $target.PSObject.Properties['resourceGroupName']
            $resourceGroupName = if ($resourceGroupProperty) {
                $resourceGroupProperty.Value
            }
            else {
                "$($target.prefix)-rg"
            }
            $privateNetworkingProperty = $target.PSObject.Properties['enablePrivateNetworking']
            $networkingMode = if ($privateNetworkingProperty -and $privateNetworkingProperty.Value -is [bool] -and $privateNetworkingProperty.Value) {
                'private'
            }
            else {
                'public'
            }
            $appRegistrationProperty = $target.PSObject.Properties['appRegistrationName']
            $appRegistrationName = if ($appRegistrationProperty -and -not [string]::IsNullOrWhiteSpace([string]$appRegistrationProperty.Value)) {
                $appRegistrationProperty.Value
            }
            else {
                "$($target.prefix)-app"
            }
            Write-Host ("{0}. {1} | tenant {2} | subscription {3} | azd env {4} | prefix {5} | resource group {6} | networking {7} | app {8}" -f `
                ($index + 1), $target.displayName, $target.tenantId, $target.subscriptionId, $target.environmentName, $target.prefix, $resourceGroupName, $networkingMode, $appRegistrationName)
        }
        Write-Host 'A. Add another target'
        Write-Host 'Q. Quit'

        $choice = (Read-Host 'Selection').Trim()
        if ($choice -match '^[Qq]$') {
            return $null
        }

        if ($choice -match '^[Aa]$') {
            return Read-Target
        }

        $selectedIndex = 0
        if ([int]::TryParse($choice, [ref]$selectedIndex) -and
            $selectedIndex -ge 1 -and $selectedIndex -le $Targets.Count) {
            return $Targets[$selectedIndex - 1]
        }

        Write-Warning 'Choose one of the listed targets, A, or Q.'
    }
}

function Connect-ToTarget {
    <# .SYNOPSIS Aligns Azure CLI and azd authentication with a target. #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Target
    )

    $currentAccountJson = & az account show --output json 2>$null
    $currentAccount = $null
    if ($LASTEXITCODE -eq 0 -and $currentAccountJson) {
        $currentAccount = ($currentAccountJson -join [Environment]::NewLine) | ConvertFrom-Json
    }

    if (-not $currentAccount -or $currentAccount.tenantId -ne $Target.tenantId) {
        Write-Host "Signing in to tenant $($Target.tenantId)..." -ForegroundColor Cyan
        Invoke-ExternalCommand -CommandName 'az' -Arguments @(
            'login', '--tenant', $Target.tenantId
        )
    }

    Write-Host "Selecting subscription $($Target.subscriptionId)..." -ForegroundColor Cyan
    Invoke-ExternalCommand -CommandName 'az' -Arguments @(
        'account', 'set', '--subscription', $Target.subscriptionId
    )

    Write-Host "Refreshing azd authentication for tenant $($Target.tenantId)..." -ForegroundColor Cyan
    Invoke-ExternalCommand -CommandName 'azd' -Arguments @(
        'auth', 'logout', '--no-prompt'
    )
    Invoke-ExternalCommand -CommandName 'azd' -Arguments @(
        'auth', 'login', '--tenant-id', $Target.tenantId
    )
}

function Set-AzdEnvironment {
    <# .SYNOPSIS Selects or creates and configures the target azd environment. #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Target,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RepositoryPath
    )

    $environmentPath = Join-Path $RepositoryPath ".azure\$($Target.environmentName)\.env"
    if (Test-Path $environmentPath) {
        Write-Host "Selecting existing azd environment '$($Target.environmentName)'..." -ForegroundColor Cyan
        Invoke-ExternalCommand -CommandName 'azd' -Arguments @(
            'env', 'select', $Target.environmentName
        )
    }
    else {
        Write-Host "Creating azd environment '$($Target.environmentName)'..." -ForegroundColor Cyan
        Invoke-ExternalCommand -CommandName 'azd' -Arguments @(
            'env', 'new', $Target.environmentName,
            '--subscription', $Target.subscriptionId,
            '--location', $Target.location
        )
    }

    Invoke-ExternalCommand -CommandName 'azd' -Arguments @(
        'env', 'set', 'AZURE_TENANT_ID', $Target.tenantId
    )
    Invoke-ExternalCommand -CommandName 'azd' -Arguments @(
        'env', 'set', 'AZURE_SUBSCRIPTION_ID', $Target.subscriptionId
    )
    Invoke-ExternalCommand -CommandName 'azd' -Arguments @(
        'env', 'set', 'AZURE_LOCATION', $Target.location
    )
    $privateNetworkingValue = if ($Target.enablePrivateNetworking) { 'true' } else { 'false' }
    Invoke-ExternalCommand -CommandName 'azd' -Arguments @(
        'env', 'set', 'ENABLE_PRIVATE_NETWORKING', $privateNetworkingValue
    )
    Invoke-ExternalCommand -CommandName 'azd' -Arguments @(
        'env', 'set', 'APP_REGISTRATION_NAME', $Target.appRegistrationName
    )
    Invoke-ExternalCommand -CommandName 'azd' -Arguments @(
        'env', 'config', 'set', 'infra.parameters.prefix', $Target.prefix
    )
    Invoke-ExternalCommand -CommandName 'azd' -Arguments @(
        'env', 'config', 'set', 'infra.parameters.resourceGroupName', $Target.resourceGroupName
    )
}

function Get-AzdEnvironmentConfigValue {
    <# .SYNOPSIS Gets a named infrastructure parameter from an azd environment. #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RepositoryPath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EnvironmentName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    $configPath = Join-Path $RepositoryPath ".azure\$EnvironmentName\config.json"
    if (-not (Test-Path $configPath)) {
        return $null
    }

    try {
        $config = Get-Content -Path $configPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "Could not read azd environment configuration '$configPath': $($_.Exception.Message)"
    }

    $infraProperty = $config.PSObject.Properties['infra']
    $parametersProperty = if ($infraProperty) { $infraProperty.Value.PSObject.Properties['parameters'] } else { $null }
    $valueProperty = if ($parametersProperty) { $parametersProperty.Value.PSObject.Properties[$Name] } else { $null }

    if ($valueProperty) {
        return [string]$valueProperty.Value
    }

    return $null
}

function Resolve-TargetResourceGroupName {
    <# .SYNOPSIS Reconciles a target's resource group with its azd environment. #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Target,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Targets,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ProfilePath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RepositoryPath
    )

    $environmentResourceGroupName = Get-AzdEnvironmentConfigValue -RepositoryPath $RepositoryPath -EnvironmentName $Target.environmentName -Name 'resourceGroupName'
    if (-not $environmentResourceGroupName -or $environmentResourceGroupName -eq $Target.resourceGroupName) {
        return $Target
    }

    Write-Warning "Target resource group '$($Target.resourceGroupName)' differs from the existing azd environment configuration value '$environmentResourceGroupName'."
    $resourceGroupName = Read-RequiredValue -Prompt 'Azure resource group name'
    if ($resourceGroupName -notmatch '^[a-zA-Z0-9._()\-]{1,90}$') {
        throw "Resource group name '$resourceGroupName' contains unsupported characters or is longer than 90 characters."
    }

    $Target.resourceGroupName = $resourceGroupName
    $targetIndex = [Array]::IndexOf($Targets, $Target)
    if ($targetIndex -ge 0) {
        $Targets[$targetIndex] = $Target
        Save-TargetCatalog -Path $ProfilePath -Targets $Targets
        Write-Host "Target catalog updated at '$ProfilePath'." -ForegroundColor Green
    }

    return $Target
}

function Confirm-TargetDeployment {
    <# .SYNOPSIS Displays the resolved target and confirms deployment. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Target
    )

    Write-Host ''
    Write-Host 'Deployment target:' -ForegroundColor Cyan
    Write-Host "  azd environment : $($Target.environmentName)"
    Write-Host "  Resource prefix : $($Target.prefix)"
    Write-Host "  Resource group  : $($Target.resourceGroupName)"

    return Read-YesNoValue -Prompt 'Run azd up for this target?' -DefaultValue $false
}

function Set-TargetResourceGroupName {
    <# .SYNOPSIS Adds a resource group name to legacy target entries. #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Target,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Targets,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ProfilePath
    )

    $resourceGroupProperty = $Target.PSObject.Properties['resourceGroupName']
    if ($resourceGroupProperty -and -not [string]::IsNullOrWhiteSpace([string]$resourceGroupProperty.Value)) {
        return $Target
    }

    $defaultResourceGroupName = "$($Target.prefix)-rg"
    Write-Host "Target '$($Target.displayName)' has no resource group configured." -ForegroundColor Yellow
    $resourceGroupName = Read-RequiredValue -Prompt 'Azure resource group name' -DefaultValue $defaultResourceGroupName
    if ($resourceGroupName -notmatch '^[a-zA-Z0-9._()\-]{1,90}$') {
        throw "Resource group name '$resourceGroupName' contains unsupported characters or is longer than 90 characters."
    }

    $Target | Add-Member -MemberType NoteProperty -Name resourceGroupName -Value $resourceGroupName
    $targetIndex = [Array]::IndexOf($Targets, $Target)
    if ($targetIndex -ge 0) {
        $Targets[$targetIndex] = $Target
        Save-TargetCatalog -Path $ProfilePath -Targets $Targets
        Write-Host "Target catalog updated at '$ProfilePath'." -ForegroundColor Green
    }

    return $Target
}

function Set-TargetPrivateNetworking {
    <# .SYNOPSIS Adds a private networking choice to legacy target entries. #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Target,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Targets,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ProfilePath
    )

    $privateNetworkingProperty = $Target.PSObject.Properties['enablePrivateNetworking']
    if ($privateNetworkingProperty -and $privateNetworkingProperty.Value -is [bool]) {
        return $Target
    }

    Write-Host "Target '$($Target.displayName)' has no private networking preference configured." -ForegroundColor Yellow
    $enablePrivateNetworking = Read-YesNoValue -Prompt 'Enable private networking' -DefaultValue $false
    if ($privateNetworkingProperty) {
        $privateNetworkingProperty.Value = $enablePrivateNetworking
    }
    else {
        $Target | Add-Member -MemberType NoteProperty -Name enablePrivateNetworking -Value $enablePrivateNetworking
    }

    $targetIndex = [Array]::IndexOf($Targets, $Target)
    if ($targetIndex -ge 0) {
        $Targets[$targetIndex] = $Target
        Save-TargetCatalog -Path $ProfilePath -Targets $Targets
        Write-Host "Target catalog updated at '$ProfilePath'." -ForegroundColor Green
    }

    return $Target
}

function Set-TargetAppRegistrationName {
    <# .SYNOPSIS Adds an app registration name to legacy target entries. #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Target,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Targets,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ProfilePath
    )

    $appRegistrationProperty = $Target.PSObject.Properties['appRegistrationName']
    if ($appRegistrationProperty -and -not [string]::IsNullOrWhiteSpace([string]$appRegistrationProperty.Value)) {
        return $Target
    }

    $defaultAppRegistrationName = "$($Target.prefix)-app"
    Write-Host "Target '$($Target.displayName)' has no app registration name configured." -ForegroundColor Yellow
    $appRegistrationName = Read-RequiredValue -Prompt 'App registration name' -DefaultValue $defaultAppRegistrationName
    if ($appRegistrationProperty) {
        $appRegistrationProperty.Value = $appRegistrationName
    }
    else {
        $Target | Add-Member -MemberType NoteProperty -Name appRegistrationName -Value $appRegistrationName
    }

    $targetIndex = [Array]::IndexOf($Targets, $Target)
    if ($targetIndex -ge 0) {
        $Targets[$targetIndex] = $Target
        Save-TargetCatalog -Path $ProfilePath -Targets $Targets
        Write-Host "Target catalog updated at '$ProfilePath'." -ForegroundColor Green
    }

    return $Target
}

#endregion Functions

#region Main Execution

if ($MyInvocation.InvocationName -ne '.') {
    try {
        Test-CommandAvailable -CommandName 'az'
        Test-CommandAvailable -CommandName 'azd'

        $repositoryPath = $PSScriptRoot
        Push-Location $repositoryPath
        try {
            $targets = @(Get-TargetCatalog -Path $ProfilePath)
            if ($targets.Count -eq 0) {
                Write-Host 'No targets found. Add your tenant and subscription targets.' -ForegroundColor Yellow
                $targets = @()
                do {
                    $targets += Read-Target
                    Save-TargetCatalog -Path $ProfilePath -Targets $targets
                    Write-Host "Target catalog saved to '$ProfilePath'." -ForegroundColor Green
                    $addAnother = (Read-Host 'Add another target? (Y/N)').Trim()
                } while ($addAnother -match '^[Yy]$')
            }

            $target = Select-Target -Targets $targets
            if (-not $target) {
                Write-Host 'Cancelled.'
                exit 0
            }

            $target = Set-TargetResourceGroupName -Target $target -Targets $targets -ProfilePath $ProfilePath
            $target = Resolve-TargetResourceGroupName -Target $target -Targets $targets -ProfilePath $ProfilePath -RepositoryPath $repositoryPath
            $target = Set-TargetPrivateNetworking -Target $target -Targets $targets -ProfilePath $ProfilePath
            $target = Set-TargetAppRegistrationName -Target $target -Targets $targets -ProfilePath $ProfilePath

                if ($target.displayName -and @($targets | Where-Object {
                        $_.tenantId -eq $target.tenantId -and
                        $_.subscriptionId -eq $target.subscriptionId -and
                        $_.environmentName -eq $target.environmentName
                    }).Count -eq 0) {
                $targets += $target
                Save-TargetCatalog -Path $ProfilePath -Targets $targets
                Write-Host "Target catalog updated at '$ProfilePath'." -ForegroundColor Green
            }

            if (-not $WhatIfPreference -and -not (Confirm-TargetDeployment -Target $target)) {
                Write-Host 'Cancelled.'
                exit 0
            }

            Connect-ToTarget -Target $target
            Set-AzdEnvironment -Target $target -RepositoryPath $repositoryPath

            Write-Host ''
            Write-Host "Tenant / subscription selected: $($target.displayName)" -ForegroundColor Green
            Write-Host "Running azd up..." -ForegroundColor Cyan
            if ($PSCmdlet.ShouldProcess("azd environment '$($target.environmentName)'", 'Run azd up')) {
                Invoke-ExternalCommand -CommandName 'azd' -Arguments @('up')
            }
        }
        finally {
            Pop-Location
        }
        exit 0
    }
    catch {
        Write-Error "Azd migration setup failed: $($_.Exception.Message)"
        exit 1
    }
}

#endregion Main Execution