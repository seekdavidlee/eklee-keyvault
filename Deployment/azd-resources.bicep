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

@description('Optional custom domain name (e.g. myapp.example.com). When set, used for VITE redirect and API base URLs instead of the default Container App FQDN.')
param customDomainName string = ''

@description('Tags to apply to all resources')
param tags object

// ============================================================================
// VARIABLES
// ============================================================================

var uniqueSuffix = uniqueString(resourceGroup().id, prefix)
var storageAccountName = toLower('${prefix}${take(uniqueSuffix, 10)}sa')
var keyVaultName = toLower('${prefix}-${take(uniqueSuffix, 6)}-kv')
var containerAppEnvName = '${prefix}-env'
var containerAppName = '${prefix}-app'
var managedIdentityName = '${prefix}-identity'
var logAnalyticsWorkspaceName = '${prefix}-logs'

// Resolve application base URL: use custom domain when provided, otherwise fall back to the default Container App FQDN
var appBaseUrl = !empty(customDomainName)
  ? 'https://${customDomainName}'
  : 'https://${containerAppName}.${containerAppEnvironment.properties.defaultDomain}'

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
  tags: tags
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
    publicNetworkAccess: 'Enabled'
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
  tags: tags
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
// RBAC ROLE ASSIGNMENTS
// ============================================================================

// Grant the managed identity Key Vault Secrets Officer on the Key Vault
resource keyVaultRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, managedIdentity.id, keyVaultSecretsOfficerRoleId)
  scope: keyVault
  properties: {
    principalId: managedIdentity.properties.principalId
    roleDefinitionId: keyVaultSecretsOfficerRoleId
    principalType: 'ServicePrincipal'
  }
}

// Grant the managed identity Storage Blob Data Contributor on the Storage Account
resource storageRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, managedIdentity.id, storageBlobDataContributorRoleId)
  scope: storageAccount
  properties: {
    principalId: managedIdentity.properties.principalId
    roleDefinitionId: storageBlobDataContributorRoleId
    principalType: 'ServicePrincipal'
  }
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
// CONTAINER APP — Phase 1: Deploy with custom domain hostname (binding disabled)
// ============================================================================
// When a custom domain is configured, the hostname must be registered on the
// Container App BEFORE Azure will provision a managed certificate. Phase 1
// deploys (or updates) the app with bindingType 'Disabled' so the hostname
// exists. When no custom domain is set, this is the only deployment needed.

module containerAppPhase1 'container-app.bicep' = {
  name: 'container-app-phase1-${uniqueString(deployment().name)}'
  params: {
    name: containerAppName
    location: location
    tags: tags
    containerImage: containerImage
    managedEnvironmentId: containerAppEnvironment.id
    managedIdentityId: managedIdentity.id
    managedIdentityClientId: managedIdentity.properties.clientId
    keyVaultUri: keyVault.properties.vaultUri
    storageBlobEndpoint: storageAccount.properties.primaryEndpoints.blob
    storageContainerName: 'configs'
    tenantId: tenantId
    clientId: clientId
    loginEndpoint: environment().authentication.loginEndpoint
    appBaseUrl: appBaseUrl
    customDomainName: customDomainName
    // No certificate yet — the binding is Disabled so Azure accepts the hostname
  }
}

// ============================================================================
// MANAGED CERTIFICATE — provisioned only when a custom domain is configured
// ============================================================================
// Prerequisites: CNAME and TXT DNS records must be configured BEFORE deployment.
// Certificate provisioning may take several minutes while Azure validates the domain.
// The hostname must already be registered on a Container App (phase 1 above).

resource managedCertificate 'Microsoft.App/managedEnvironments/managedCertificates@2025-01-01' = if (!empty(customDomainName)) {
  parent: containerAppEnvironment
  name: 'cert-${replace(customDomainName, '.', '-')}'
  location: location
  tags: tags
  properties: {
    subjectName: customDomainName
    domainControlValidation: 'CNAME'
  }
  dependsOn: [
    containerAppPhase1
  ]
}

// ============================================================================
// CONTAINER APP — Phase 2: Bind the managed certificate (SniEnabled)
// ============================================================================
// Once the certificate is provisioned, redeploy the Container App with the
// certificate bound. When no custom domain is set, this is an idempotent
// deployment identical to phase 1.

module containerAppPhase2 'container-app.bicep' = {
  name: 'container-app-phase2-${uniqueString(deployment().name)}'
  params: {
    name: containerAppName
    location: location
    tags: tags
    containerImage: containerImage
    managedEnvironmentId: containerAppEnvironment.id
    managedIdentityId: managedIdentity.id
    managedIdentityClientId: managedIdentity.properties.clientId
    keyVaultUri: keyVault.properties.vaultUri
    storageBlobEndpoint: storageAccount.properties.primaryEndpoints.blob
    storageContainerName: 'configs'
    tenantId: tenantId
    clientId: clientId
    loginEndpoint: environment().authentication.loginEndpoint
    appBaseUrl: appBaseUrl
    customDomainName: customDomainName
    customDomainCertificateId: !empty(customDomainName) ? managedCertificate.id : ''
  }
  dependsOn: [
    containerAppPhase1
  ]
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
output containerAppName string = containerAppPhase2.outputs.containerAppName

@description('The FQDN of the Container App (update VITE_AZURE_AD_REDIRECT_URI and app registration redirect URI with this value)')
output containerAppFqdn string = containerAppPhase2.outputs.containerAppFqdn

@description('The full URL of the Container App')
output containerAppUrl string = containerAppPhase2.outputs.containerAppUrl
