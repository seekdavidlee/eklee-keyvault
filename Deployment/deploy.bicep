param prefix string
param kvName string = ''
param strName string = ''
param apimName string = ''
param appName string = ''
param location string = resourceGroup().location
param scriptVersion string = utcNow()
param publisherEmail string
param publisherName string
param customDomainName string = ''

var kvNameStr = empty(kvName) ? '${prefix}${uniqueString(resourceGroup().name)}' : kvName
var strNameStr = empty(strName) ? '${prefix}${uniqueString(resourceGroup().name)}' : strName
var apimNameStr = empty(apimName) ? '${prefix}${uniqueString(resourceGroup().name)}' : apimName
var appNameStr = empty(appName) ? '${prefix}${uniqueString(resourceGroup().name)}' : appName

resource akv 'Microsoft.KeyVault/vaults@2024-04-01-preview' = {
  name: kvNameStr
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

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: strNameStr
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
  }
}

resource storageContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  name: 'configs'
  parent: storageAccountBlobServices
  properties: {
    publicAccess: 'None'
  }
}
var defaultHostname = empty(customDomainName)
  ? 'https://${staticwebapp.properties.defaultHostname}'
  : 'https://${customDomainName}'

resource storageAccountBlobServices 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    cors: {
      corsRules: [
        {
          allowedOrigins: [defaultHostname]
          allowedMethods: [
            'POST'
            'GET'
            'OPTIONS'
            'HEAD'
            'PUT'
            'MERGE'
            'DELETE'
          ]
          maxAgeInSeconds: 120
          exposedHeaders: [
            '*'
          ]
          allowedHeaders: [
            '*'
          ]
        }
      ]
    }
  }
}

resource apim 'Microsoft.ApiManagement/service@2023-09-01-preview' = {
  name: apimNameStr
  location: location
  sku: {
    name: 'Consumption'
    capacity: 0
  }
  tags: {
    update_time: scriptVersion
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
  }
}

resource apimpolicy 'Microsoft.ApiManagement/service/policies@2023-09-01-preview' = {
  parent: apim
  name: 'policy'
  properties: {
    value: loadTextContent('apim-policy.xml')
    format: 'xml'
  }
}

var serviceUrl = 'https://${kvNameStr}${environment().suffixes.keyvaultDns}/'

resource apis 'Microsoft.ApiManagement/service/apis@2023-09-01-preview' = {
  parent: apim
  name: 'keyvault-api'
  properties: {
    displayName: 'Keyvault API proxy'
    apiRevision: '1'
    subscriptionRequired: true
    serviceUrl: serviceUrl
    path: 'keyvault'
    protocols: [
      'https'
    ]
  }
}

resource apispolicy 'Microsoft.ApiManagement/service/apis/policies@2023-09-01-preview' = {
  parent: apis
  name: 'policy'
  properties: {
    value: replace(loadTextContent('apim-apis-policy.xml'), '%EDGEURL%', defaultHostname)
    format: 'xml'
  }
}

resource apigetallsecrets 'Microsoft.ApiManagement/service/apis/operations@2023-09-01-preview' = {
  parent: apis
  name: 'all'
  properties: {
    displayName: 'all-secrets'
    method: 'GET'
    urlTemplate: '/secrets'
  }
}

resource apigetallsecretspolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2023-09-01-preview' = {
  parent: apigetallsecrets
  name: 'policy'
  properties: {
    value: replace(loadTextContent('all-secrets-policy.xml'), '%KEYVAULTNAME%', kvNameStr)
    format: 'xml'
  }
}

resource apigetsecret 'Microsoft.ApiManagement/service/apis/operations@2023-09-01-preview' = {
  parent: apis
  name: 'get-secret'
  properties: {
    displayName: 'get-secret'
    method: 'GET'
    urlTemplate: '/secret'
  }
}

resource apigetsecretpolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2023-09-01-preview' = {
  parent: apigetsecret
  name: 'policy'
  properties: {
    value: replace(loadTextContent('get-secret-policy.xml'), '%KEYVAULTNAME%', kvNameStr)
    format: 'xml'
  }
}

resource staticwebapp 'Microsoft.Web/staticSites@2022-09-01' = {
  name: appNameStr
  location: location
  sku: {
    tier: 'Free'
    name: 'Free'
  }
  properties: {}
}

resource customDomain 'Microsoft.Web/staticSites/customDomains@2022-09-01' = if (!empty(customDomainName)) {
  name: customDomainName
  parent: staticwebapp
}
