// ============================================================================
// Azure Developer CLI (azd) Infrastructure for Eklee KeyVault
// ============================================================================
// Subscription-scoped entry point that creates a resource group based on the
// prefix and deploys all resources into it via the azd-resources module.
//
// No private networking. Container images are supplied from public GHCR.
// ============================================================================

targetScope = 'subscription'

// ============================================================================
// PARAMETERS
// ============================================================================

@description('Required prefix used for naming Azure resources')
@minLength(3)
@maxLength(10)
param prefix string

@description('Name of the resource group to create or reuse')
@minLength(1)
@maxLength(90)
param resourceGroupName string

@description('The Azure region where resources will be deployed')
param location string

@description('Your Azure AD tenant ID used for authentication (set by preprovision hook)')
param tenantId string = tenant().tenantId

@description('The Azure AD app registration client ID used for authentication (set by preprovision hook)')
param clientId string = ''

@description('The full container image reference including digest (set by preprovision hook)')
param containerImage string

@description('Custom HTTPS domain for the stable main development target')
param customDevDomainName string = ''

@description('Custom HTTPS domain for the stable release target')
param customReleaseDomainName string = ''

@description('Custom HTTPS domain for the stable branch target')
param customBranchDomainName string = ''

@description('The full immutable Microsoft Entra ID Auth SDK sidecar image reference')
param miseSidecarImage string = ''

@description('Enable the Microsoft Entra ID Auth SDK sidecar for API token validation')
param enableMiseSidecar bool = false

@description('Enable private networking with a virtual network and private endpoints')
param enablePrivateNetworking bool = false

@description('Existing storage account name resolved from its resource-id tag')
param existingStorageAccountName string = ''

@description('Existing Key Vault name resolved from its resource-id tag')
param existingKeyVaultName string = ''

@description('Existing Log Analytics workspace name resolved from its resource-id tag')
param existingLogAnalyticsWorkspaceName string = ''

@description('Existing user-assigned managed identity name resolved from its resource-id tag')
param existingManagedIdentityName string = ''

@description('Existing Container Apps environment name resolved from its resource-id tag')
param existingContainerAppEnvironmentName string = ''

@description('Existing main development Container App name resolved from its resource-id tag')
param existingDevContainerAppName string = ''

@description('Existing release Container App name resolved from its resource-id tag')
param existingReleaseContainerAppName string = ''

@description('Existing branch Container App name resolved from its resource-id tag')
param existingBranchContainerAppName string = ''

@description('Existing virtual network name resolved from its resource-id tag')
param existingVirtualNetworkName string = ''

@description('Existing Container Apps network security group name resolved from its resource-id tag')
param existingContainerAppNsgName string = ''

@description('Existing private-endpoint network security group name resolved from its resource-id tag')
param existingResourceNsgName string = ''

@description('Existing storage private endpoint name resolved from its resource-id tag')
param existingStoragePrivateEndpointName string = ''

@description('Existing Key Vault private endpoint name resolved from its resource-id tag')
param existingKeyVaultPrivateEndpointName string = ''

@description('Existing storage private DNS zone name resolved from its resource-id tag')
param existingStoragePrivateDnsZoneName string = ''

@description('Existing Key Vault private DNS zone name resolved from its resource-id tag')
param existingKeyVaultPrivateDnsZoneName string = ''

@description('Existing storage private DNS zone virtual network link name resolved from its resource-id tag')
param existingStoragePrivateDnsZoneLinkName string = ''

@description('Existing Key Vault private DNS zone virtual network link name resolved from its resource-id tag')
param existingKeyVaultPrivateDnsZoneLinkName string = ''

@description('Skip the Key Vault RBAC assignment when preprovision confirms it already exists')
param skipKeyVaultRoleAssignment bool = false

@description('Skip the Storage RBAC assignment when preprovision confirms it already exists')
param skipStorageRoleAssignment bool = false

@description('Tags to apply to all resources')
param tags object = {
  Application: 'Eklee-KeyVault'
  ManagedBy: 'azd-Bicep'
}

// ============================================================================
// VARIABLES
// ============================================================================

// ============================================================================
// RESOURCE GROUP
// ============================================================================

resource resourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

// ============================================================================
// RESOURCES MODULE — deployed into the new resource group
// ============================================================================

module resources 'azd-resources.bicep' = {
  name: 'azd-resources-${uniqueString(deployment().name)}'
  scope: resourceGroup
  params: {
    prefix: prefix
    location: location
    tenantId: tenantId
    clientId: clientId
    containerImage: containerImage
    customDevDomainName: customDevDomainName
    customReleaseDomainName: customReleaseDomainName
    customBranchDomainName: customBranchDomainName
    miseSidecarImage: miseSidecarImage
    enableMiseSidecar: enableMiseSidecar
    enablePrivateNetworking: enablePrivateNetworking
    existingStorageAccountName: existingStorageAccountName
    existingKeyVaultName: existingKeyVaultName
    existingLogAnalyticsWorkspaceName: existingLogAnalyticsWorkspaceName
    existingManagedIdentityName: existingManagedIdentityName
    existingContainerAppEnvironmentName: existingContainerAppEnvironmentName
    existingDevContainerAppName: existingDevContainerAppName
    existingReleaseContainerAppName: existingReleaseContainerAppName
    existingBranchContainerAppName: existingBranchContainerAppName
    existingVirtualNetworkName: existingVirtualNetworkName
    existingContainerAppNsgName: existingContainerAppNsgName
    existingResourceNsgName: existingResourceNsgName
    existingStoragePrivateEndpointName: existingStoragePrivateEndpointName
    existingKeyVaultPrivateEndpointName: existingKeyVaultPrivateEndpointName
    existingStoragePrivateDnsZoneName: existingStoragePrivateDnsZoneName
    existingKeyVaultPrivateDnsZoneName: existingKeyVaultPrivateDnsZoneName
    existingStoragePrivateDnsZoneLinkName: existingStoragePrivateDnsZoneLinkName
    existingKeyVaultPrivateDnsZoneLinkName: existingKeyVaultPrivateDnsZoneLinkName
    skipKeyVaultRoleAssignment: skipKeyVaultRoleAssignment
    skipStorageRoleAssignment: skipStorageRoleAssignment
    tags: tags
  }
}

// ============================================================================
// OUTPUTS
// ============================================================================

@description('The name of the resource group')
output resourceGroupName string = resourceGroup.name

@description('The name of the Storage Account')
output storageAccountName string = resources.outputs.storageAccountName

@description('The name of the Key Vault')
output keyVaultName string = resources.outputs.keyVaultName

@description('The URI of the Key Vault')
output keyVaultUri string = resources.outputs.keyVaultUri

@description('The name of the Container Apps Environment')
output containerAppEnvironmentName string = resources.outputs.containerAppEnvironmentName

@description('The name of the user-assigned managed identity')
output managedIdentityName string = resources.outputs.managedIdentityName

@description('The principal ID of the user-assigned managed identity')
output managedIdentityPrincipalId string = resources.outputs.managedIdentityPrincipalId

@description('The client ID of the user-assigned managed identity')
output managedIdentityClientId string = resources.outputs.managedIdentityClientId

@description('The name of the Container App')
output containerAppName string = resources.outputs.containerAppName

@description('The FQDN of the Container App (update VITE_AZURE_AD_REDIRECT_URI and app registration redirect URI with this value)')
output containerAppFqdn string = resources.outputs.containerAppFqdn

@description('The full URL of the Container App')
output containerAppUrl string = resources.outputs.containerAppUrl

@description('The name of the stable main development Container App')
output devContainerAppName string = resources.outputs.devContainerAppName

@description('The full URL of the stable main development Container App')
output devContainerAppUrl string = resources.outputs.devContainerAppUrl

@description('The name of the stable release Container App')
output releaseContainerAppName string = resources.outputs.releaseContainerAppName

@description('The full URL of the stable release Container App')
output releaseContainerAppUrl string = resources.outputs.releaseContainerAppUrl

@description('The name of the stable branch Container App')
output branchContainerAppName string = resources.outputs.branchContainerAppName

@description('The full URL of the stable branch Container App')
output branchContainerAppUrl string = resources.outputs.branchContainerAppUrl
