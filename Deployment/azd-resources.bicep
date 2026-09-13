// ============================================================================
// Azure Developer CLI (azd) Infrastructure — Resource Group Module
// ============================================================================
// All resources deployed into the resource group created by azd.bicep.
// ============================================================================

// ============================================================================
// PARAMETERS
// ============================================================================

@description('Required prefix used for naming all Azure resources')
@minLength(3)
@maxLength(10)
param prefix string

@description('The Azure region where resources will be deployed')
param location string

@description('Your Azure AD tenant ID used for authentication')
param tenantId string

@description('The Azure AD app registration client ID used for authentication')
param clientId string

@description('The full container image reference including digest (set by preprovision hook)')
param containerImage string = 'ghcr.io/seekdavidlee/eklee-keyvault:latest'

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

@description('Existing Container App name resolved from its resource-id tag')
param existingContainerAppName string = ''

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
param tags object

// ============================================================================
// VARIABLES
// ============================================================================

var uniqueSuffix = uniqueString(resourceGroup().id, prefix)
var storageAccountName = !empty(existingStorageAccountName) ? existingStorageAccountName : toLower('${prefix}${take(uniqueSuffix, 10)}sa')
var keyVaultName = !empty(existingKeyVaultName) ? existingKeyVaultName : toLower('${prefix}-${take(uniqueSuffix, 6)}-kv')
var containerAppEnvName = !empty(existingContainerAppEnvironmentName) ? existingContainerAppEnvironmentName : '${prefix}-env'
var containerAppName = !empty(existingContainerAppName) ? existingContainerAppName : '${prefix}-app'
var managedIdentityName = !empty(existingManagedIdentityName) ? existingManagedIdentityName : '${prefix}-identity'
var logAnalyticsWorkspaceName = !empty(existingLogAnalyticsWorkspaceName) ? existingLogAnalyticsWorkspaceName : '${prefix}-logs'
var logAnalyticsWorkspaceTags = union(tags, { 'resource-id': 'app-log-analytics-workspace' })
var storageAccountTags = union(tags, { 'resource-id': 'app-storage-account' })
var keyVaultTags = union(tags, { 'resource-id': 'app-key-vault' })
var managedIdentityTags = union(tags, { 'resource-id': 'app-managed-identity' })
var containerAppEnvironmentTags = union(tags, { 'resource-id': 'app-container-app-environment' })
var containerAppTags = union(tags, { 'resource-id': 'app-container-app' })

// Well-known RBAC role definition IDs
var keyVaultSecretsOfficerRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
)
var storageBlobDataContributorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
)

// ============================================================================
// LOG ANALYTICS WORKSPACE
// ============================================================================

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsWorkspaceName
  location: location
  tags: logAnalyticsWorkspaceTags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
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
  tags: storageAccountTags
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
    publicNetworkAccess: enablePrivateNetworking ? 'Disabled' : 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: enablePrivateNetworking ? 'Deny' : 'Allow'
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

// Blob service for creating containers
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2025-01-01' = {
  parent: storageAccount
  name: 'default'
}

// Container used for application configuration data
resource configsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-01-01' = {
  parent: blobService
  name: 'configs'
  properties: {
    publicAccess: 'None'
  }
}

// ============================================================================
// KEY VAULT
// ============================================================================

resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: keyVaultName
  location: location
  tags: keyVaultTags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: tenantId
    enabledForDeployment: false
    enabledForDiskEncryption: false
    enabledForTemplateDeployment: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enableRbacAuthorization: true
    publicNetworkAccess: enablePrivateNetworking ? 'Disabled' : 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: enablePrivateNetworking ? 'Deny' : 'Allow'
    }
  }
}

// ============================================================================
// USER-ASSIGNED MANAGED IDENTITY
// ============================================================================

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: managedIdentityName
  location: location
  tags: managedIdentityTags
}

// ============================================================================
// RBAC ROLE ASSIGNMENTS
// ============================================================================

// Grant the managed identity Key Vault Secrets Officer on the Key Vault
resource keyVaultRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!skipKeyVaultRoleAssignment) {
  name: guid(keyVault.id, managedIdentity.id, keyVaultSecretsOfficerRoleId)
  scope: keyVault
  properties: {
    principalId: managedIdentity.properties.principalId
    roleDefinitionId: keyVaultSecretsOfficerRoleId
    principalType: 'ServicePrincipal'
  }
}

// Grant the managed identity Storage Blob Data Contributor on the Storage Account
resource storageRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!skipStorageRoleAssignment) {
  name: guid(storageAccount.id, managedIdentity.id, storageBlobDataContributorRoleId)
  scope: storageAccount
  properties: {
    principalId: managedIdentity.properties.principalId
    roleDefinitionId: storageBlobDataContributorRoleId
    principalType: 'ServicePrincipal'
  }
}

// ============================================================================
// PRIVATE NETWORKING
// ============================================================================

module networking 'networking.bicep' = if (enablePrivateNetworking) {
  name: 'networking-${uniqueString(deployment().name)}'
  params: {
    location: location
    applicationName: prefix
    environment: 'azd'
    tags: tags
    existingVirtualNetworkName: existingVirtualNetworkName
    existingContainerAppNsgName: existingContainerAppNsgName
    existingResourceNsgName: existingResourceNsgName
    existingStoragePrivateEndpointName: existingStoragePrivateEndpointName
    existingKeyVaultPrivateEndpointName: existingKeyVaultPrivateEndpointName
    existingStoragePrivateDnsZoneName: existingStoragePrivateDnsZoneName
    existingKeyVaultPrivateDnsZoneName: existingKeyVaultPrivateDnsZoneName
    existingStoragePrivateDnsZoneLinkName: existingStoragePrivateDnsZoneLinkName
    existingKeyVaultPrivateDnsZoneLinkName: existingKeyVaultPrivateDnsZoneLinkName
    storageAccountId: storageAccount.id
    storageAccountName: storageAccount.name
    keyVaultId: keyVault.id
    keyVaultName: keyVault.name
  }
}

// ============================================================================
// CONTAINER APPS ENVIRONMENT
// ============================================================================

resource containerAppEnvironment 'Microsoft.App/managedEnvironments@2025-01-01' = {
  name: containerAppEnvName
  location: location
  tags: containerAppEnvironmentTags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsWorkspace.properties.customerId
        sharedKey: logAnalyticsWorkspace.listKeys().primarySharedKey
      }
    }
    vnetConfiguration: enablePrivateNetworking
      ? {
          infrastructureSubnetId: networking!.outputs.containerAppSubnetId
          internal: false
        }
      : null
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
    zoneRedundant: false
  }
}

// ============================================================================
// CONTAINER APP — Eklee KeyVault API + UI
// ============================================================================

resource containerApp 'Microsoft.App/containerApps@2025-01-01' = {
  name: containerAppName
  location: location
  tags: containerAppTags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: containerAppEnvironment.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
        allowInsecure: false
      }
    }
    template: {
      containers: [
        {
          name: 'eklee-keyvault'
          image: containerImage
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            // ASP.NET backend configuration
            {
              name: 'KeyVaultUri'
              value: keyVault.properties.vaultUri
            }
            {
              name: 'StorageUri'
              value: storageAccount.properties.primaryEndpoints.blob
            }
            {
              name: 'StorageContainerName'
              value: 'configs'
            }
            {
              name: 'AuthenticationMode'
              value: 'mi'
            }
            {
              name: 'AZURE_CLIENT_ID'
              value: managedIdentity.properties.clientId
            }
            // Azure AD authentication settings
            {
              name: 'AzureAd__Instance'
              value: environment().authentication.loginEndpoint
            }
            {
              name: 'AzureAd__TenantId'
              value: tenantId
            }
            {
              name: 'AzureAd__ClientId'
              value: clientId
            }
            {
              name: 'AzureAd__Audience'
              value: 'api://${clientId}'
            }
            // React frontend runtime configuration (injected by docker-entrypoint.sh)
            {
              name: 'VITE_AZURE_AD_CLIENT_ID'
              value: clientId
            }
            {
              name: 'VITE_AZURE_AD_AUTHORITY'
              value: '${environment().authentication.loginEndpoint}${tenantId}'
            }
            {
              name: 'VITE_AZURE_AD_REDIRECT_URI'
              value: 'https://${containerAppName}.${containerAppEnvironment.properties.defaultDomain}'
            }
            {
              name: 'VITE_API_BASE_URL'
              value: 'https://${containerAppName}.${containerAppEnvironment.properties.defaultDomain}'
            }
          ]
          probes: [
            {
              type: 'Liveness'
              httpGet: {
                path: '/healthz'
                port: 8080
              }
              initialDelaySeconds: 10
              periodSeconds: 30
            }
            {
              type: 'Readiness'
              httpGet: {
                path: '/healthz'
                port: 8080
              }
              initialDelaySeconds: 5
              periodSeconds: 10
            }
          ]
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 1
      }
    }
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

@description('The name of the user-assigned managed identity')
output managedIdentityName string = managedIdentity.name

@description('The principal ID of the user-assigned managed identity')
output managedIdentityPrincipalId string = managedIdentity.properties.principalId

@description('The client ID of the user-assigned managed identity')
output managedIdentityClientId string = managedIdentity.properties.clientId

@description('The name of the Container App')
output containerAppName string = containerApp.name

@description('The FQDN of the Container App (update VITE_AZURE_AD_REDIRECT_URI and app registration redirect URI with this value)')
output containerAppFqdn string = containerApp.properties.configuration.ingress.fqdn

@description('The full URL of the Container App')
output containerAppUrl string = 'https://${containerApp.properties.configuration.ingress.fqdn}'
