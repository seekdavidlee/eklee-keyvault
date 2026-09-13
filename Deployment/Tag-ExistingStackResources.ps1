#!/usr/bin/env pwsh
# Copyright (c) 2026 Microsoft Corporation. All rights reserved.
# SPDX-License-Identifier: MIT
#Requires -Version 7.4

<#
.SYNOPSIS
    Tags the existing Eklee KeyVault stack resources by their logical role.
.DESCRIPTION
    Reads one resource group inventory and infers the resources managed by the
    active azd Bicep templates. The script reports its complete mapping by
    default. Tag updates require -Apply and are authorized individually by
    PowerShell's ShouldProcess support.

    The tag key is resource-id. Values are stable logical identifiers such as
    app-key-vault, and remain the same across resource groups and deployments.
.PARAMETER ResourceGroupName
    Name of the resource group containing the existing stack.
.PARAMETER Apply
    Writes the proposed tags. Omit this switch to produce a report only.
.PARAMETER Force
    Replaces a conflicting resource-id tag only after the full role map has
    passed preflight and the resource is the unique expected candidate.
.EXAMPLE
    ./Deployment/Tag-ExistingStackResources.ps1 -ResourceGroupName eklee-keyvault-viewer-dev

    Reports the tags that would adopt the existing development stack.
.EXAMPLE
    ./Deployment/Tag-ExistingStackResources.ps1 -ResourceGroupName eklee-keyvault-viewer-dev -Apply

    Adds missing resource-id tags after preflight succeeds.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [switch]$Apply,

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

#region Functions

function Test-AzureCliAvailable {
    [CmdletBinding()]
    [OutputType([void])]
    param()

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI (az) was not found on PATH.'
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

function Get-ExistingResources {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ResourceGroupName
    )

    $resources = [System.Collections.Generic.List[object]]::new()
    $resourceArguments = @('resource', 'list', '--resource-group', $ResourceGroupName)

    foreach ($resource in @(Invoke-AzureCliJson -Arguments $resourceArguments)) {
        $resources.Add($resource)
    }

    $dnsZoneArguments = @('network', 'private-dns', 'zone', 'list', '--resource-group', $ResourceGroupName)

    $dnsZones = @(Invoke-AzureCliJson -Arguments $dnsZoneArguments)
    foreach ($dnsZone in $dnsZones) {
        $resources.Add($dnsZone)
    }

    $managedDnsZones = @(
        'privatelink.blob.core.windows.net'
        'privatelink.vaultcore.azure.net'
    )
    foreach ($zoneName in $managedDnsZones) {
        if ($dnsZones.name -notcontains $zoneName) {
            continue
        }

        $linkArguments = @(
            'network', 'private-dns', 'link', 'vnet', 'list',
            '--resource-group', $ResourceGroupName,
            '--zone-name', $zoneName
        )

        foreach ($link in @(Invoke-AzureCliJson -Arguments $linkArguments)) {
            $resources.Add($link)
        }
    }

    return @($resources)
}

function Get-RoleDefinitions {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    return @(
        [pscustomobject]@{ Role = 'storage-account'; ResourceId = 'app-storage-account'; Type = 'Microsoft.Storage/storageAccounts'; NameSuffix = $null; ExactName = $null }
        [pscustomobject]@{ Role = 'key-vault'; ResourceId = 'app-key-vault'; Type = 'Microsoft.KeyVault/vaults'; NameSuffix = $null; ExactName = $null }
        [pscustomobject]@{ Role = 'log-analytics-workspace'; ResourceId = 'app-log-analytics-workspace'; Type = 'Microsoft.OperationalInsights/workspaces'; NameSuffix = $null; ExactName = $null }
        [pscustomobject]@{ Role = 'managed-identity'; ResourceId = 'app-managed-identity'; Type = 'Microsoft.ManagedIdentity/userAssignedIdentities'; NameSuffix = $null; ExactName = $null }
        [pscustomobject]@{ Role = 'container-app-environment'; ResourceId = 'app-container-app-environment'; Type = 'Microsoft.App/managedEnvironments'; NameSuffix = $null; ExactName = $null }
        [pscustomobject]@{ Role = 'container-app'; ResourceId = 'app-container-app'; Type = 'Microsoft.App/containerApps'; NameSuffix = $null; ExactName = $null }
        [pscustomobject]@{ Role = 'virtual-network'; ResourceId = 'app-virtual-network'; Type = 'Microsoft.Network/virtualNetworks'; NameSuffix = $null; ExactName = $null }
        [pscustomobject]@{ Role = 'container-app-network-security-group'; ResourceId = 'app-container-app-network-security-group'; Type = 'Microsoft.Network/networkSecurityGroups'; NameSuffix = '-containerapp-nsg'; ExactName = $null }
        [pscustomobject]@{ Role = 'resource-network-security-group'; ResourceId = 'app-resource-network-security-group'; Type = 'Microsoft.Network/networkSecurityGroups'; NameSuffix = '-resource-nsg'; ExactName = $null }
        [pscustomobject]@{ Role = 'storage-private-endpoint'; ResourceId = 'app-storage-private-endpoint'; Type = 'Microsoft.Network/privateEndpoints'; NameSuffix = '-blob-pe'; ExactName = $null }
        [pscustomobject]@{ Role = 'key-vault-private-endpoint'; ResourceId = 'app-key-vault-private-endpoint'; Type = 'Microsoft.Network/privateEndpoints'; NameSuffix = '-vault-pe'; ExactName = $null }
        [pscustomobject]@{ Role = 'storage-private-dns-zone'; ResourceId = 'app-storage-private-dns-zone'; Type = 'Microsoft.Network/privateDnsZones'; NameSuffix = $null; ExactName = 'privatelink.blob.core.windows.net' }
        [pscustomobject]@{ Role = 'key-vault-private-dns-zone'; ResourceId = 'app-key-vault-private-dns-zone'; Type = 'Microsoft.Network/privateDnsZones'; NameSuffix = $null; ExactName = 'privatelink.vaultcore.azure.net' }
        [pscustomobject]@{ Role = 'storage-private-dns-zone-link'; ResourceId = 'app-storage-private-dns-zone-link'; Type = 'Microsoft.Network/privateDnsZones/virtualNetworkLinks'; NameSuffix = '-blob-link'; ExactName = $null }
        [pscustomobject]@{ Role = 'key-vault-private-dns-zone-link'; ResourceId = 'app-key-vault-private-dns-zone-link'; Type = 'Microsoft.Network/privateDnsZones/virtualNetworkLinks'; NameSuffix = '-vault-link'; ExactName = $null }
    )
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

function Get-RoleCandidates {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Resources,

        [Parameter(Mandatory = $true)]
        [object]$RoleDefinition
    )

    $candidates = @($Resources | Where-Object { $_.type -eq $RoleDefinition.Type })
    if ($RoleDefinition.ExactName) {
        return @($candidates | Where-Object { $_.name -eq $RoleDefinition.ExactName })
    }

    if ($RoleDefinition.NameSuffix) {
        return @($candidates | Where-Object { $_.name -like "*$($RoleDefinition.NameSuffix)" })
    }

    return $candidates
}

function New-RolePlan {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Resources,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$TagKey,

        [Parameter(Mandatory = $true)]
        [bool]$AllowForce
    )

    $rolePlans = foreach ($roleDefinition in Get-RoleDefinitions) {
        $candidates = @(Get-RoleCandidates -Resources $Resources -RoleDefinition $roleDefinition)
        $expectedTagValue = $roleDefinition.ResourceId
        $resourcesWithExpectedTag = @($Resources | Where-Object {
            (Get-ResourceTagValue -Resource $_ -TagKey $TagKey) -eq $expectedTagValue
            })
        $status = 'Ready'
        $reason = 'Missing resource-id tag.'
        $resource = $null

        if ($candidates.Count -eq 0) {
            $status = 'Missing'
            $reason = "No resource of type '$($roleDefinition.Type)' matched this role."
        }
        elseif ($candidates.Count -gt 1) {
            $status = 'Ambiguous'
            $reason = "Multiple resources of type '$($roleDefinition.Type)' matched this role."
        }
        else {
            $resource = $candidates[0]
            $currentTagValue = Get-ResourceTagValue -Resource $resource -TagKey $TagKey
            if ($resourcesWithExpectedTag.Count -gt 1 -or
                ($resourcesWithExpectedTag.Count -eq 1 -and $resourcesWithExpectedTag[0].id -ne $resource.id)) {
                $status = 'Conflict'
                $reason = "Resource-id tag '$expectedTagValue' is already assigned to a different resource."
            }
            elseif ($currentTagValue -eq $expectedTagValue) {
                $status = 'AlreadyTagged'
                $reason = 'Resource-id tag already has the expected value.'
            }
            elseif (-not [string]::IsNullOrWhiteSpace($currentTagValue)) {
                if ($AllowForce) {
                    $status = 'ForceUpdate'
                    $reason = "Resource-id tag currently has '$currentTagValue' and will be replaced by -Force."
                }
                else {
                    $status = 'Conflict'
                    $reason = "Resource-id tag currently has '$currentTagValue'. Use -Force only after verifying the report."
                }
            }
        }

        [pscustomobject]@{
            Role = $roleDefinition.Role
            ExpectedType = $roleDefinition.Type
            ExpectedTagValue = $expectedTagValue
            Status = $status
            Reason = $reason
            ResourceName = if ($resource) { $resource.name } else { $null }
            ResourceId = if ($resource) { $resource.id } else { $null }
        }
    }

    return @($rolePlans)
}

function Write-RolePlan {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$RolePlans
    )

    $RolePlans |
        Select-Object Role, Status, ResourceName, ExpectedTagValue, Reason |
        Format-Table -AutoSize | Out-Host
}

function Set-ResourceRoleTags {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$RolePlans,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$TagKey
    )

    $blockedPlans = @($RolePlans | Where-Object { $_.Status -in @('Missing', 'Ambiguous', 'Conflict') })
    if ($blockedPlans.Count -gt 0) {
        $blockedRoles = $blockedPlans.Role -join ', '
        throw "Preflight failed for: $blockedRoles. No tags were changed."
    }

    foreach ($rolePlan in $RolePlans | Where-Object { $_.Status -in @('Ready', 'ForceUpdate') }) {
        if ($PSCmdlet.ShouldProcess($rolePlan.ResourceId, "Set $TagKey=$($rolePlan.ExpectedTagValue)")) {
            $tagArguments = @(
                'tag', 'update',
                '--resource-id', $rolePlan.ResourceId,
                '--operation', 'merge',
                '--tags', "$TagKey=$($rolePlan.ExpectedTagValue)"
            )
            Invoke-AzureCliJson -Arguments $tagArguments | Out-Null
            Write-Host "Tagged '$($rolePlan.ResourceName)' as '$($rolePlan.ExpectedTagValue)'." -ForegroundColor Green
        }
    }
}
#endregion Functions

#region Main Execution
if ($MyInvocation.InvocationName -ne '.') {
    try {
        Test-AzureCliAvailable

        $resources = Get-ExistingResources -ResourceGroupName $ResourceGroupName
        $rolePlans = New-RolePlan -Resources $resources -TagKey 'resource-id' -AllowForce $Force

        Write-Host "Resource-id tag plan for '$ResourceGroupName':" -ForegroundColor Cyan
        Write-RolePlan -RolePlans $rolePlans

        if (-not $Apply) {
            Write-Host 'Report only. Re-run with -Apply to write the preflight-approved tags.' -ForegroundColor Yellow
            exit 0
        }

        Set-ResourceRoleTags -RolePlans $rolePlans -TagKey 'resource-id'
        Write-Host 'All preflight-approved resource-id tags were applied.' -ForegroundColor Green
        exit 0
    }
    catch {
        Write-Error -ErrorAction Continue "Existing resource tagging failed: $($_.Exception.Message)"
        exit 1
    }
}
#endregion Main Execution