#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Resolves existing stack resource names from resource-id tags for azd.
.DESCRIPTION
    Reads the current azd environment and, when its target resource group
    exists, resolves each declared Bicep resource by a unique resource-id tag.
    The resolved names are stored as azd environment values consumed by
    azd.parameters.json. A missing tag intentionally produces an empty
    override so Bicep creates the resource with its normal generated name.

    All Azure CLI queries are explicitly scoped to AZURE_SUBSCRIPTION_ID. This
    script never writes Azure resources or tags.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

#region Functions

function Test-CommandAvailable {
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

function Invoke-AzureCliJson {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Arguments
    )

    $result = & az @Arguments --output json
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed with exit code ${LASTEXITCODE}: az $($Arguments -join ' ')"
    }

    return $result | ConvertFrom-Json
}

function Get-AzdEnvironmentValue {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    $value = & azd env get-value $Name 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    return ($value | Out-String).Trim()
}

function Get-AzdInfrastructureParameter {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    $value = & azd env config get "infra.parameters.$Name" 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    return ($value | Out-String).Trim().Trim('"')
}

function Set-AzdEnvironmentValue {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    & azd env set $Name $Value
    if ($LASTEXITCODE -ne 0) {
        throw "azd failed to set environment value '$Name'."
    }
}

function Get-EnablePrivateNetworking {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $value = Get-AzdEnvironmentValue -Name 'ENABLE_PRIVATE_NETWORKING'
    if ($value -eq 'true') {
        return $true
    }

    if ($value -eq 'false') {
        return $false
    }

    throw "ENABLE_PRIVATE_NETWORKING must be 'true' or 'false', but was '$value'."
}

function Get-RoleDefinitions {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    return @(
        [pscustomobject]@{ Role = 'storage-account'; ResourceId = 'app-storage-account'; Type = 'Microsoft.Storage/storageAccounts'; EnvironmentVariable = 'EXISTING_STORAGE_ACCOUNT_NAME'; RequiresPrivateNetworking = $false }
        [pscustomobject]@{ Role = 'key-vault'; ResourceId = 'app-key-vault'; Type = 'Microsoft.KeyVault/vaults'; EnvironmentVariable = 'EXISTING_KEY_VAULT_NAME'; RequiresPrivateNetworking = $false }
        [pscustomobject]@{ Role = 'log-analytics-workspace'; ResourceId = 'app-log-analytics-workspace'; Type = 'Microsoft.OperationalInsights/workspaces'; EnvironmentVariable = 'EXISTING_LOG_ANALYTICS_WORKSPACE_NAME'; RequiresPrivateNetworking = $false }
        [pscustomobject]@{ Role = 'managed-identity'; ResourceId = 'app-managed-identity'; Type = 'Microsoft.ManagedIdentity/userAssignedIdentities'; EnvironmentVariable = 'EXISTING_MANAGED_IDENTITY_NAME'; RequiresPrivateNetworking = $false }
        [pscustomobject]@{ Role = 'container-app-environment'; ResourceId = 'app-container-app-environment'; Type = 'Microsoft.App/managedEnvironments'; EnvironmentVariable = 'EXISTING_CONTAINER_APP_ENVIRONMENT_NAME'; RequiresPrivateNetworking = $false }
        [pscustomobject]@{ Role = 'container-app'; ResourceId = 'app-container-app'; Type = 'Microsoft.App/containerApps'; EnvironmentVariable = 'EXISTING_CONTAINER_APP_NAME'; RequiresPrivateNetworking = $false }
        [pscustomobject]@{ Role = 'virtual-network'; ResourceId = 'app-virtual-network'; Type = 'Microsoft.Network/virtualNetworks'; EnvironmentVariable = 'EXISTING_VIRTUAL_NETWORK_NAME'; RequiresPrivateNetworking = $true }
        [pscustomobject]@{ Role = 'container-app-network-security-group'; ResourceId = 'app-container-app-network-security-group'; Type = 'Microsoft.Network/networkSecurityGroups'; EnvironmentVariable = 'EXISTING_CONTAINER_APP_NSG_NAME'; RequiresPrivateNetworking = $true }
        [pscustomobject]@{ Role = 'resource-network-security-group'; ResourceId = 'app-resource-network-security-group'; Type = 'Microsoft.Network/networkSecurityGroups'; EnvironmentVariable = 'EXISTING_RESOURCE_NSG_NAME'; RequiresPrivateNetworking = $true }
        [pscustomobject]@{ Role = 'storage-private-endpoint'; ResourceId = 'app-storage-private-endpoint'; Type = 'Microsoft.Network/privateEndpoints'; EnvironmentVariable = 'EXISTING_STORAGE_PRIVATE_ENDPOINT_NAME'; RequiresPrivateNetworking = $true }
        [pscustomobject]@{ Role = 'key-vault-private-endpoint'; ResourceId = 'app-key-vault-private-endpoint'; Type = 'Microsoft.Network/privateEndpoints'; EnvironmentVariable = 'EXISTING_KEY_VAULT_PRIVATE_ENDPOINT_NAME'; RequiresPrivateNetworking = $true }
        [pscustomobject]@{ Role = 'storage-private-dns-zone'; ResourceId = 'app-storage-private-dns-zone'; Type = 'Microsoft.Network/privateDnsZones'; EnvironmentVariable = 'EXISTING_STORAGE_PRIVATE_DNS_ZONE_NAME'; ExactName = 'privatelink.blob.core.windows.net'; RequiresPrivateNetworking = $true }
        [pscustomobject]@{ Role = 'key-vault-private-dns-zone'; ResourceId = 'app-key-vault-private-dns-zone'; Type = 'Microsoft.Network/privateDnsZones'; EnvironmentVariable = 'EXISTING_KEY_VAULT_PRIVATE_DNS_ZONE_NAME'; ExactName = 'privatelink.vaultcore.azure.net'; RequiresPrivateNetworking = $true }
        [pscustomobject]@{ Role = 'storage-private-dns-zone-link'; ResourceId = 'app-storage-private-dns-zone-link'; Type = 'Microsoft.Network/privateDnsZones/virtualNetworkLinks'; EnvironmentVariable = 'EXISTING_STORAGE_PRIVATE_DNS_ZONE_LINK_NAME'; RequiresPrivateNetworking = $true }
        [pscustomobject]@{ Role = 'key-vault-private-dns-zone-link'; ResourceId = 'app-key-vault-private-dns-zone-link'; Type = 'Microsoft.Network/privateDnsZones/virtualNetworkLinks'; EnvironmentVariable = 'EXISTING_KEY_VAULT_PRIVATE_DNS_ZONE_LINK_NAME'; RequiresPrivateNetworking = $true }
    )
}

function Get-ExistingResources {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [bool]$IncludePrivateNetworking
    )

    $resources = [System.Collections.Generic.List[object]]::new()
    foreach ($resource in @(Invoke-AzureCliJson -Arguments @(
                'resource', 'list', '--resource-group', $ResourceGroupName, '--subscription', $SubscriptionId
            ))) {
        $resources.Add($resource)
    }

    if ($IncludePrivateNetworking) {
        $dnsZones = @(Invoke-AzureCliJson -Arguments @(
                'network', 'private-dns', 'zone', 'list', '--resource-group', $ResourceGroupName, '--subscription', $SubscriptionId
            ))
        foreach ($dnsZone in $dnsZones) {
            $resources.Add($dnsZone)
        }

        $dnsZoneNames = @($dnsZones | ForEach-Object { $_.name })
        foreach ($zoneName in @('privatelink.blob.core.windows.net', 'privatelink.vaultcore.azure.net')) {
            if ($dnsZoneNames -notcontains $zoneName) {
                continue
            }

            foreach ($link in @(Invoke-AzureCliJson -Arguments @(
                        'network', 'private-dns', 'link', 'vnet', 'list', '--resource-group', $ResourceGroupName,
                        '--zone-name', $zoneName, '--subscription', $SubscriptionId
                    ))) {
                $resources.Add($link)
            }
        }
    }

    $uniqueResources = [System.Collections.Generic.List[object]]::new()
    $resourceIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($resource in $resources) {
        $resourceId = [string]$resource.id
        if ([string]::IsNullOrWhiteSpace($resourceId) -or $resourceIds.Add($resourceId)) {
            $uniqueResources.Add($resource)
        }
    }

    return @($uniqueResources)
}

function Get-TaggedResource {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Resources,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ResourceId,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Type
    )

    $matches = @($Resources | Where-Object {
            (Get-ResourceTagValue -Resource $_ -TagKey 'resource-id') -eq $ResourceId -and
            $_.type -eq $Type
        })

    if ($matches.Count -ne 1) {
        return $null
    }

    return $matches[0]
}

function Test-RoleAssignmentExists {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$PrincipalId,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RoleDefinitionName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Scope,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SubscriptionId
    )

    $assignments = @(Invoke-AzureCliJson -Arguments @(
            'role', 'assignment', 'list',
            '--assignee', $PrincipalId,
            '--role', $RoleDefinitionName,
            '--scope', $Scope,
            '--subscription', $SubscriptionId
        ))

    return @($assignments | Where-Object { $_.scope -eq $Scope }).Count -gt 0
}

function Set-RbacAssignmentSkipFlags {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Resources,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SubscriptionId
    )

    $skipKeyVault = $false
    $skipStorage = $false
    $managedIdentity = Get-TaggedResource -Resources $Resources -ResourceId 'app-managed-identity' -Type 'Microsoft.ManagedIdentity/userAssignedIdentities'
    $keyVault = Get-TaggedResource -Resources $Resources -ResourceId 'app-key-vault' -Type 'Microsoft.KeyVault/vaults'
    $storageAccount = Get-TaggedResource -Resources $Resources -ResourceId 'app-storage-account' -Type 'Microsoft.Storage/storageAccounts'

    if ($managedIdentity -and $keyVault -and $storageAccount) {
        $identity = Invoke-AzureCliJson -Arguments @(
            'identity', 'show', '--ids', $managedIdentity.id, '--subscription', $SubscriptionId
        )
        $principalId = [string]$identity.principalId

        if ([string]::IsNullOrWhiteSpace($principalId)) {
            throw "Managed identity '$($managedIdentity.name)' does not have a principal ID."
        }

        $skipKeyVault = Test-RoleAssignmentExists `
            -PrincipalId $principalId `
            -RoleDefinitionName 'Key Vault Secrets Officer' `
            -Scope $keyVault.id `
            -SubscriptionId $SubscriptionId
        $skipStorage = Test-RoleAssignmentExists `
            -PrincipalId $principalId `
            -RoleDefinitionName 'Storage Blob Data Contributor' `
            -Scope $storageAccount.id `
            -SubscriptionId $SubscriptionId
    }

    $skipKeyVaultValue = $skipKeyVault.ToString().ToLowerInvariant()
    $skipStorageValue = $skipStorage.ToString().ToLowerInvariant()
    Set-AzdEnvironmentValue -Name 'SKIP_KEY_VAULT_ROLE_ASSIGNMENT' -Value $skipKeyVaultValue
    Set-AzdEnvironmentValue -Name 'SKIP_STORAGE_ROLE_ASSIGNMENT' -Value $skipStorageValue
    Write-Host "Key Vault RBAC assignment will be $(if ($skipKeyVault) { 'skipped because it exists' } else { 'deployed' })." -ForegroundColor $(if ($skipKeyVault) { 'Green' } else { 'Yellow' })
    Write-Host "Storage RBAC assignment will be $(if ($skipStorage) { 'skipped because it exists' } else { 'deployed' })." -ForegroundColor $(if ($skipStorage) { 'Green' } else { 'Yellow' })
}

function Get-ResourceTagValue {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Resource,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$TagKey
    )

    $tagProperty = if ($Resource.tags) { $Resource.tags.PSObject.Properties[$TagKey] } else { $null }
    if ($tagProperty) {
        return [string]$tagProperty.Value
    }

    return $null
}

function Resolve-TaggedResourceNames {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Resources,

        [Parameter(Mandatory = $true)]
        [object[]]$RoleDefinitions
    )

    foreach ($roleDefinition in $RoleDefinitions) {
        $expectedTagValue = $roleDefinition.ResourceId
        $taggedResources = @($Resources | Where-Object {
                (Get-ResourceTagValue -Resource $_ -TagKey 'resource-id') -eq $expectedTagValue
            })

        if ($taggedResources.Count -eq 0) {
            Set-AzdEnvironmentValue -Name $roleDefinition.EnvironmentVariable -Value ''
            Write-Host "No resource found for '$expectedTagValue'; Bicep will use its generated name." -ForegroundColor Yellow
            continue
        }

        if ($taggedResources.Count -ne 1) {
            throw "Tag '$expectedTagValue' matched $($taggedResources.Count) resources. Each role must have exactly one resource in the target group."
        }

        $resource = $taggedResources[0]
        if ($resource.type -ne $roleDefinition.Type) {
            throw "Tag '$expectedTagValue' is on resource '$($resource.name)' of type '$($resource.type)', not expected type '$($roleDefinition.Type)'."
        }

        $exactNameProperty = $roleDefinition.PSObject.Properties['ExactName']
        if ($exactNameProperty -and $resource.name -ne $exactNameProperty.Value) {
            throw "Tag '$expectedTagValue' is on private DNS zone '$($resource.name)', not required zone '$($exactNameProperty.Value)'."
        }

        Set-AzdEnvironmentValue -Name $roleDefinition.EnvironmentVariable -Value $resource.name
        Write-Host "Resolved '$expectedTagValue' to '$($resource.name)'." -ForegroundColor Green
    }
}

#endregion Functions

#region Main Execution

function Invoke-ResourceNameResolution {
    [CmdletBinding()]
    [OutputType([void])]
    param()

    Test-CommandAvailable -CommandName 'az'
    Test-CommandAvailable -CommandName 'azd'

    $subscriptionId = Get-AzdEnvironmentValue -Name 'AZURE_SUBSCRIPTION_ID'
    if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
        throw 'AZURE_SUBSCRIPTION_ID is required before resolving existing resources.'
    }

    if ($subscriptionId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        throw "AZURE_SUBSCRIPTION_ID '$subscriptionId' must be a GUID."
    }

    $enablePrivateNetworking = Get-EnablePrivateNetworking
    $roleDefinitions = @(Get-RoleDefinitions)
    $activeRoleDefinitions = @($roleDefinitions | Where-Object {
            $enablePrivateNetworking -or -not $_.RequiresPrivateNetworking
        })

    if (-not $enablePrivateNetworking) {
        foreach ($roleDefinition in @($roleDefinitions | Where-Object { $_.RequiresPrivateNetworking })) {
            Set-AzdEnvironmentValue -Name $roleDefinition.EnvironmentVariable -Value ''
        }

        Write-Host 'Private networking is disabled; private resource reuse checks are skipped.' -ForegroundColor Yellow
    }

    $resourceGroupName = Get-AzdEnvironmentValue -Name 'resourceGroupName'
    if ([string]::IsNullOrWhiteSpace($resourceGroupName)) {
        $resourceGroupName = Get-AzdInfrastructureParameter -Name 'resourceGroupName'
        if ([string]::IsNullOrWhiteSpace($resourceGroupName)) {
            throw "resourceGroupName is required. Set it with 'azd env set resourceGroupName <name>' or run Setup.ps1."
        }

        Set-AzdEnvironmentValue -Name 'resourceGroupName' -Value $resourceGroupName
    }

    $resourceGroupExists = Invoke-AzureCliJson -Arguments @(
        'group', 'exists', '--name', $resourceGroupName, '--subscription', $subscriptionId
    )
    if (-not $resourceGroupExists) {
        foreach ($roleDefinition in $roleDefinitions) {
            Set-AzdEnvironmentValue -Name $roleDefinition.EnvironmentVariable -Value ''
        }
        Set-AzdEnvironmentValue -Name 'SKIP_KEY_VAULT_ROLE_ASSIGNMENT' -Value 'false'
        Set-AzdEnvironmentValue -Name 'SKIP_STORAGE_ROLE_ASSIGNMENT' -Value 'false'
        Write-Host "Resource group '$resourceGroupName' does not exist; Bicep will create resources with generated names." -ForegroundColor Yellow
        return
    }

    $resources = @(Get-ExistingResources -ResourceGroupName $resourceGroupName -SubscriptionId $subscriptionId -IncludePrivateNetworking $enablePrivateNetworking)
    Resolve-TaggedResourceNames -Resources $resources -RoleDefinitions $activeRoleDefinitions
    Set-RbacAssignmentSkipFlags -Resources $resources -SubscriptionId $subscriptionId
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-ResourceNameResolution
        exit 0
    }
    catch {
        Write-Error -ErrorAction Continue "Existing resource resolution failed: $($_.Exception.Message)"
        exit 1
    }
}

#endregion Main Execution