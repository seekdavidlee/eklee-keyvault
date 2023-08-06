param prefix string
param kvName string = '${prefix}${uniqueString(resourceGroup().name)}'
param location string = resourceGroup().location
param appInsightsName string = '${prefix}${uniqueString(resourceGroup().name)}'
param appPlanName string = '${prefix}${uniqueString(resourceGroup().name)}'
param appName string = '${prefix}${uniqueString(resourceGroup().name)}'
param sharedKeyVault string
param keyVaultRefUserId string

resource akv 'Microsoft.KeyVault/vaults@2023-02-01' = {
  name: kvName
  location: location
  properties: {
    sku: {
      name: 'standard'
      family: 'A'
    }
    enableRbacAuthorization: true
    softDeleteRetentionInDays: 7
    enableSoftDelete: false
    enablePurgeProtection: true
    tenantId: subscription().tenantId
  }
}

resource appinsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    ImmediatePurgeDataOn30Days: true
    IngestionMode: 'ApplicationInsights'
  }
}

resource appplan 'Microsoft.Web/serverfarms@2022-09-01' = {
  name: appPlanName
  location: location
  sku: {
    name: 'F1'
  }
}

resource appsite 'Microsoft.Web/sites@2022-09-01' = {
  name: appName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${keyVaultRefUserId}': {}
    }
  }
  properties: {
    keyVaultReferenceIdentity: keyVaultRefUserId
    serverFarmId: appplan.id
    httpsOnly: true
    siteConfig: {
      netFrameworkVersion: 'v6.0'
      #disable-next-line BCP037
      metadata: [
        {
          name: 'CURRENT_STACK'
          value: 'dotnet'
        }
      ]
      appSettings: [
        {
          name: 'KeyVaultName'
          value: akv.name
        }
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: appinsights.properties.InstrumentationKey
        }
        {
          name: 'ApplicationInsightsAgent_EXTENSION_VERSION'
          value: '~2'
        }
        {
          name: 'XDT_MicrosoftApplicationInsights_Mode'
          value: 'recommended'
        }
        {
          name: 'DiagnosticServices_EXTENSION_VERSION'
          value: '~3'
        }
        {
          name: 'APPINSIGHTS_PROFILERFEATURE_VERSION'
          value: 'disabled'
        }
        {
          name: 'APPINSIGHTS_SNAPSHOTFEATURE_VERSION'
          value: '1.0.0'
        }
        {
          name: 'InstrumentationEngine_EXTENSION_VERSION'
          value: '~1'
        }
        {
          name: 'SnapshotDebugger_EXTENSION_VERSION'
          value: 'disabled'
        }
        {
          name: 'XDT_MicrosoftApplicationInsights_BaseExtensions'
          value: '~1'
        }
        {
          name: 'ASPNETCORE_ENVIRONMENT'
          value: 'Development'
        }
        {
          name: 'EnableAuth'
          value: 'true'
        }
        {
          name: 'AzureAd:CallbackPath'
          value: '/signin-oidc'
        }
        {
          name: 'AzureAd:Instance'
          value: environment().authentication.loginEndpoint
        }
        {
          name: 'AzureAd:TenantId'
          value: '@Microsoft.KeyVault(VaultName=${sharedKeyVault};SecretName=keyvault-viewer-tenant-id)'
        }
        {
          name: 'AzureAd:Domain'
          value: '@Microsoft.KeyVault(VaultName=${sharedKeyVault};SecretName=keyvault-viewer-domain)'
        }
        {
          name: 'AzureAd:ClientId'
          value: '@Microsoft.KeyVault(VaultName=${sharedKeyVault};SecretName=keyvault-viewer-client-id)'
        }
        {
          name: 'AzureAd:ClientSecret'
          value: '@Microsoft.KeyVault(VaultName=${sharedKeyVault};SecretName=keyvault-viewer-client-secret)'
        }
      ]
    }
  }
}

output appName string = appsite.name
