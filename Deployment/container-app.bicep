// ============================================================================
// Container App Module — Eklee KeyVault API + UI
// ============================================================================
// Reusable module for the Container App resource. Called twice by
// azd-resources.bicep when a custom domain is configured:
//   1. Initial deployment with bindingType 'Disabled' to register the hostname
//   2. Final deployment with the managed certificate bound (SniEnabled)
// When no custom domain is set, only the initial deployment runs and the final
// deployment is an idempotent no-op with the same configuration.
// ============================================================================

// ============================================================================
// PARAMETERS
// ============================================================================

@description('Name of the Container App')
param name string

@description('Azure region')
param location string

@description('Tags to apply')
param tags object

@description('Container image reference')
param containerImage string

@description('Resource ID of the Container Apps Environment')
param managedEnvironmentId string

@description('Resource ID of the user-assigned managed identity')
param managedIdentityId string

@description('Client ID of the user-assigned managed identity')
param managedIdentityClientId string

@description('Key Vault URI')
param keyVaultUri string

@description('Storage blob endpoint')
param storageBlobEndpoint string

@description('Storage container name')
param storageContainerName string

@description('Azure AD tenant ID')
param tenantId string

@description('Azure AD client ID for the app registration')
param clientId string

@description('Azure AD login endpoint (e.g. https://login.microsoftonline.com/)')
param loginEndpoint string

@description('Application base URL used for VITE_AZURE_AD_REDIRECT_URI and VITE_API_BASE_URL')
param appBaseUrl string

@description('Custom domain name. Leave empty for no custom domain.')
param customDomainName string = ''

@description('Resource ID of the managed certificate. Leave empty for a disabled binding.')
param customDomainCertificateId string = ''

// ============================================================================
// CONTAINER APP
// ============================================================================

resource containerApp 'Microsoft.App/containerApps@2025-01-01' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentityId}': {}
    }
  }
  properties: {
    managedEnvironmentId: managedEnvironmentId
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
        allowInsecure: false
        // any() bypasses Bicep type checking because the two branches have different shapes
        // (certificateId is absent for the Disabled binding)
        customDomains: any(!empty(customDomainName)
          ? (!empty(customDomainCertificateId)
            ? [
                {
                  name: customDomainName
                  certificateId: customDomainCertificateId
                  bindingType: 'SniEnabled'
                }
              ]
            : [
                {
                  name: customDomainName
                  bindingType: 'Disabled'
                }
              ])
          : [])
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
              value: keyVaultUri
            }
            {
              name: 'StorageUri'
              value: storageBlobEndpoint
            }
            {
              name: 'StorageContainerName'
              value: storageContainerName
            }
            {
              name: 'AuthenticationMode'
              value: 'mi'
            }
            {
              name: 'AZURE_CLIENT_ID'
              value: managedIdentityClientId
            }
            // Azure AD authentication settings
            {
              name: 'AzureAd__Instance'
              value: loginEndpoint
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
              value: '${loginEndpoint}${tenantId}'
            }
            {
              name: 'VITE_AZURE_AD_REDIRECT_URI'
              value: appBaseUrl
            }
            {
              name: 'VITE_API_BASE_URL'
              value: appBaseUrl
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

@description('The name of the Container App')
output containerAppName string = containerApp.name

@description('The FQDN of the Container App')
output containerAppFqdn string = containerApp.properties.configuration.ingress.fqdn

@description('The full HTTPS URL of the Container App')
output containerAppUrl string = 'https://${containerApp.properties.configuration.ingress.fqdn}'
