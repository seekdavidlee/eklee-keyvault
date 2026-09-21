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
param tags object

// ============================================================================
// VARIABLES
// ============================================================================

var uniqueSuffix = uniqueString(resourceGroup().id, prefix)
var storageAccountName = !empty(existingStorageAccountName) ? existingStorageAccountName : toLower('${prefix}${take(uniqueSuffix, 10)}sa')
var keyVaultName = !empty(existingKeyVaultName) ? existingKeyVaultName : toLower('${prefix}-${take(uniqueSuffix, 6)}-kv')
var containerAppEnvName = !empty(existingContainerAppEnvironmentName) ? existingContainerAppEnvironmentName : '${prefix}-env'
var mainContainerAppName = !empty(existingDevContainerAppName) ? existingDevContainerAppName : '${prefix}-app'
var managedIdentityName = !empty(existingManagedIdentityName) ? existingManagedIdentityName : '${prefix}-identity'
var logAnalyticsWorkspaceName = !empty(existingLogAnalyticsWorkspaceName) ? existingLogAnalyticsWorkspaceName : '${prefix}-logs'
var logAnalyticsWorkspaceTags = union(tags, { 'resource-id': 'app-log-analytics-workspace' })
var storageAccountTags = union(tags, { 'resource-id': 'app-storage-account' })
var keyVaultTags = union(tags, { 'resource-id': 'app-key-vault' })
var managedIdentityTags = union(tags, { 'resource-id': 'app-managed-identity' })
var containerAppEnvironmentTags = union(tags, { 'resource-id': 'app-container-app-environment' })
var resolvedContainerImage = contains(containerImage, '@sha256:')
  ? containerImage
  : fail('containerImage must use an immutable sha256 digest.')
var resolvedMiseSidecarImage = enableMiseSidecar
  ? (contains(miseSidecarImage, '@sha256:')
      ? miseSidecarImage
      : fail('miseSidecarImage must use an immutable sha256 digest when enableMiseSidecar is true.'))
  : ''
var permanentTargetsEnabled = !empty(customDevDomainName) && !empty(customReleaseDomainName) && !empty(customBranchDomainName)
var mainContainerAppUrl = permanentTargetsEnabled
  ? 'https://${customDevDomainName}'
  : 'https://${mainContainerAppName}.${containerAppEnvironment.properties.defaultDomain}'
var releaseContainerAppName = !empty(existingReleaseContainerAppName) ? existingReleaseContainerAppName : '${mainContainerAppName}-release'
var branchContainerAppName = !empty(existingBranchContainerAppName) ? existingBranchContainerAppName : '${mainContainerAppName}-branch'
var containerAppTargets = [
  {
    name: mainContainerAppName
    target: 'main'
    resourceId: 'app-container-app'
    customDomainName: customDevDomainName
    enabled: true
  }
  {
    name: releaseContainerAppName
    target: 'release'
    resourceId: 'app-container-app-release'
    customDomainName: customReleaseDomainName
    enabled: permanentTargetsEnabled
  }
  {
    name: branchContainerAppName
    target: 'branch'
    resourceId: 'app-container-app-branch'
    customDomainName: customBranchDomainName
    enabled: permanentTargetsEnabled
  }
]

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
// CONTAINER APPS — Eklee KeyVault API + UI
// ============================================================================

resource containerApps 'Microsoft.App/containerApps@2025-01-01' = [for target in containerAppTargets: if (target.enabled) {
  name: target.name
  location: location
  tags: union(tags, { 'resource-id': target.resourceId, DeploymentTarget: target.target })
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
      containers: concat([
        {
          name: 'eklee-keyvault'
          image: resolvedContainerImage
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
            {
              name: 'Mise__Enabled'
              value: enableMiseSidecar ? 'true' : 'false'
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
              value: !empty(target.customDomainName)
                ? 'https://${target.customDomainName}'
                : 'https://${target.name}.${containerAppEnvironment.properties.defaultDomain}'
            }
            {
              name: 'VITE_API_BASE_URL'
              value: !empty(target.customDomainName)
                ? 'https://${target.customDomainName}'
                : 'https://${target.name}.${containerAppEnvironment.properties.defaultDomain}'
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
      ], enableMiseSidecar ? [
        {
          name: 'mise-sidecar'
          image: resolvedMiseSidecarImage
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: [
            {
              name: 'ASPNETCORE_URLS'
              value: 'http://+:5000'
            }
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
              value: clientId
            }
          ]
          probes: [
            {
              type: 'Startup'
              tcpSocket: {
                port: 5000
              }
              initialDelaySeconds: 5
              periodSeconds: 10
              failureThreshold: 30
            }
            {
              type: 'Liveness'
              tcpSocket: {
                port: 5000
              }
              initialDelaySeconds: 10
              periodSeconds: 30
            }
            {
              type: 'Readiness'
              tcpSocket: {
                port: 5000
              }
              initialDelaySeconds: 5
              periodSeconds: 10
            }
          ]
        }
      ] : [])
      scale: {
        minReplicas: permanentTargetsEnabled ? 1 : 0
        maxReplicas: 1
      }
    }
  }
}]

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

@description('The name of the stable main development Container App')
output devContainerAppName string = containerApps[0]!.name

@description('The FQDN of the stable main development Container App')
output devContainerAppFqdn string = containerApps[0]!.properties.configuration.ingress.fqdn

@description('The custom HTTPS URL of the stable main development Container App')
output devContainerAppUrl string = mainContainerAppUrl

@description('The name of the stable release Container App')
output releaseContainerAppName string = releaseContainerAppName

@description('The custom HTTPS URL of the stable release Container App')
output releaseContainerAppUrl string = permanentTargetsEnabled ? 'https://${customReleaseDomainName}' : ''

@description('The name of the stable branch Container App')
output branchContainerAppName string = branchContainerAppName

@description('The custom HTTPS URL of the stable branch Container App')
output branchContainerAppUrl string = permanentTargetsEnabled ? 'https://${customBranchDomainName}' : ''

@description('The name of the main Container App retained for existing azd consumers')
output containerAppName string = containerApps[0]!.name

@description('The FQDN of the main Container App retained for existing azd consumers')
output containerAppFqdn string = containerApps[0]!.properties.configuration.ingress.fqdn

@description('The URL of the main Container App retained for existing azd consumers')
output containerAppUrl string = mainContainerAppUrl
