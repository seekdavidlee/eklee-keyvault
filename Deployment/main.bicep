// ============================================================================
// Azure Container App Infrastructure for KeyVault API
// ============================================================================
// This Bicep template deploys:
// - Azure Container Apps Environment
// - User-Assigned Managed Identity (for future Container App)
// - Azure Storage Account (for application data)
// - Azure Key Vault (for secrets management)
//
// NOTE: RBAC role assignments are handled separately via assign-rbac.ps1
// ============================================================================

// ============================================================================
// PARAMETERS
// ============================================================================

@description('The Azure region where resources will be deployed')
param location string = resourceGroup().location

@description('Environment name: main branch deploys as prod, all other branches deploy as dev')
@allowed([
  'dev'
  'prod'
])
param environment string = 'dev'

@description('Name of the Azure Container Registry (without .azurecr.io)')
@minLength(5)
@maxLength(50)
param containerRegistryName string

@description('Resource group name where the Azure Container Registry is located')
param containerRegistryResourceGroup string

@description('Application name prefix for resource naming')
@minLength(3)
@maxLength(10)
param applicationName string = 'ekleekv'

@description('Your Azure AD tenant ID for Key Vault access policies')
param tenantId string = tenant().tenantId

@description('Tags to apply to all resources')
param tags object = {
  Application: 'Eklee-KeyVault'
  Environment: environment
  ManagedBy: 'Bicep'
}

// ============================================================================
// VARIABLES
// ============================================================================

var uniqueSuffix = uniqueString(resourceGroup().id, applicationName, environment)
var storageAccountName = toLower('${applicationName}${environment}${take(uniqueSuffix, 8)}')
var keyVaultName = toLower('${applicationName}-${environment}-${take(uniqueSuffix, 6)}')
var containerAppEnvName = '${applicationName}-${environment}-env'
var managedIdentityName = '${applicationName}-${environment}-identity'
var logAnalyticsWorkspaceName = '${applicationName}-${environment}-logs'

// ============================================================================
// EXISTING RESOURCES
// ============================================================================

// Reference to existing Azure Container Registry
resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' existing = {
  name: containerRegistryName
  scope: resourceGroup(containerRegistryResourceGroup)
}

// ============================================================================
// LOG ANALYTICS WORKSPACE
// ============================================================================

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsWorkspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: environment == 'prod' ? 90 : 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

// ============================================================================
// STORAGE ACCOUNT
// ============================================================================

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    defaultToOAuthAuthentication: true
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
    encryption: {
      services: {
        blob: {
          enabled: true
          keyType: 'Account'
        }
        file: {
          enabled: true
          keyType: 'Account'
        }
      }
      keySource: 'Microsoft.Storage'
    }
  }
}

// ============================================================================
// KEY VAULT
// ============================================================================

resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: environment == 'prod' ? 'premium' : 'standard'
    }
    tenantId: tenantId
    enabledForDeployment: false
    enabledForDiskEncryption: false
    enabledForTemplateDeployment: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enableRbacAuthorization: true
    enablePurgeProtection: environment == 'prod' ? true : null
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }
}

// ============================================================================
// USER-ASSIGNED MANAGED IDENTITY
// ============================================================================

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: managedIdentityName
  location: location
  tags: tags
}

// ============================================================================
// CONTAINER APPS ENVIRONMENT
// ============================================================================

resource containerAppEnvironment 'Microsoft.App/managedEnvironments@2025-01-01' = {
  name: containerAppEnvName
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsWorkspace.properties.customerId
        sharedKey: logAnalyticsWorkspace.listKeys().primarySharedKey
      }
    }
    zoneRedundant: false
  }
}

// ============================================================================
// OUTPUTS
// ============================================================================

@description('The name of the Storage Account')
output storageAccountName string = storageAccount.name

@description('The name of the Key Vault')
output keyVaultName string = keyVault.name

@description('The URI of the Key Vault')
output keyVaultUri string = keyVault.properties.vaultUri

@description('The name of the Container Apps Environment')
output containerAppEnvironmentName string = containerAppEnvironment.name

@description('The resource ID of the Container Apps Environment')
output containerAppEnvironmentId string = containerAppEnvironment.id

@description('The name of the user-assigned managed identity')
output managedIdentityName string = managedIdentity.name

@description('The principal ID of the user-assigned managed identity')
output managedIdentityPrincipalId string = managedIdentity.properties.principalId

@description('The client ID of the user-assigned managed identity')
output managedIdentityClientId string = managedIdentity.properties.clientId

@description('The resource ID of the user-assigned managed identity')
output managedIdentityId string = managedIdentity.id
