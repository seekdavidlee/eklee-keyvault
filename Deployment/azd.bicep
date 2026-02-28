// ============================================================================
// Azure Developer CLI (azd) Infrastructure for Eklee KeyVault
// ============================================================================
// Subscription-scoped entry point that creates a resource group based on the
// prefix and deploys all resources into it via the azd-resources module.
//
// No private networking. No Azure Container Registry.
// ============================================================================

targetScope = 'subscription'

// ============================================================================
// PARAMETERS
// ============================================================================

@description('Required prefix used for naming all Azure resources and the resource group')
@minLength(3)
@maxLength(10)
param prefix string

@description('The Azure region where resources will be deployed')
param location string = deployment().location

@description('Your Azure AD tenant ID used for authentication')
param tenantId string

@description('The Azure AD app registration client ID used for authentication')
param clientId string

@description('Tags to apply to all resources')
param tags object = {
  Application: 'Eklee-KeyVault'
  ManagedBy: 'azd-Bicep'
}

// ============================================================================
// VARIABLES
// ============================================================================

var resourceGroupName = '${prefix}-rg'

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
