param prefix string
param kvName string = ''
param strName string = ''
param apimName string = ''
param appName string = ''
param location string = resourceGroup().location
param managedUserId string
param scriptVersion string = utcNow()
param publisherEmail string
param publisherName string

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

resource staticWebsiteSetup 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: appNameStr
  kind: 'AzurePowerShell'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedUserId}': {}
    }
  }
  properties: {
    forceUpdateTag: scriptVersion
    azPowerShellVersion: '5.0'
    retentionInterval: 'PT1H'
    arguments: '-StorageAccountName ${storageAccount.name} -ResourceGroupName ${resourceGroup().name}'
    scriptContent: loadTextContent('deploywebsite.ps1')
    storageAccountSettings: {
      storageAccountName: appNameStr
      storageAccountKey: storageAccount.listKeys().keys[0].value
    }
  }
}

resource storageAccountBlobServices 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    cors: {
      corsRules: [
        {
          allowedOrigins: [
            staticWebsiteSetup.properties.outputs.endpoint
          ]
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
        {
          allowedOrigins: [
            edgeUrl
          ]
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

resource dns 'Microsoft.Cdn/profiles@2024-06-01-preview' = {
  name: appNameStr
  location: location
  sku: {
    name: 'Standard_Microsoft'
  }
}

var edgeUrl = 'https://${appNameStr}.azureedge.net'

var websiteUrl = replace(replace(staticWebsiteSetup.properties.outputs.endpoint, 'https://', ''), '/', '')
resource dnsEndpoint 'Microsoft.Cdn/profiles/endpoints@2024-06-01-preview' = {
  name: appNameStr
  parent: dns
  location: 'global'
  properties: {
    originHostHeader: websiteUrl
    isCompressionEnabled: true
    contentTypesToCompress: [
      'application/eot'
      'application/font'
      'application/font-sfnt'
      'application/javascript'
      'application/json'
      'application/opentype'
      'application/otf'
      'application/pkcs7-mime'
      'application/truetype'
      'application/ttf'
      'application/vnd.ms-fontobject'
      'application/xhtml+xml'
      'application/xml'
      'application/xml+rss'
      'application/x-font-opentype'
      'application/x-font-truetype'
      'application/x-font-ttf'
      'application/x-httpd-cgi'
      'application/x-javascript'
      'application/x-mpegurl'
      'application/x-opentype'
      'application/x-otf'
      'application/x-perl'
      'application/x-ttf'
      'font/eot'
      'font/ttf'
      'font/otf'
      'font/opentype'
      'image/svg+xml'
      'text/css'
      'text/csv'
      'text/html'
      'text/javascript'
      'text/js'
      'text/plain'
      'text/richtext'
      'text/tab-separated-values'
      'text/xml'
      'text/x-script'
      'text/x-component'
      'text/x-java-source'
    ]
    origins: [
      {
        name: replace(websiteUrl, '.', '-')
        properties: {
          hostName: websiteUrl
          httpPort: 80
          httpsPort: 443
          originHostHeader: websiteUrl
          priority: 1
          weight: 1000
          enabled: true
        }
      }
    ]
    deliveryPolicy: {
      rules: [
        {
          name: 'Global'
          order: 0
          actions: [
            {
              name: 'ModifyResponseHeader'
              parameters: {
                typeName: 'DeliveryRuleHeaderActionParameters'
                headerAction: 'Append'
                headerName: 'X-Frame-Options'
                value: 'SAMEORIGIN'
              }
            }
            {
              name: 'ModifyResponseHeader'
              parameters: {
                typeName: 'DeliveryRuleHeaderActionParameters'
                headerAction: 'Append'
                headerName: 'X-Content-Type-Options'
                value: 'nosniff'
              }
            }
            {
              name: 'ModifyResponseHeader'
              parameters: {
                typeName: 'DeliveryRuleHeaderActionParameters'
                headerAction: 'Append'
                headerName: 'Strict-Transport-Security'
                value: 'max-age=31536000; includeSubDomains'
              }
            }
            {
              name: 'ModifyResponseHeader'
              parameters: {
                typeName: 'DeliveryRuleHeaderActionParameters'
                headerAction: 'Append'
                headerName: 'Referrer-Policy'
                value: 'same-origin'
              }
            }
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

resource apis 'Microsoft.ApiManagement/service/apis@2023-09-01-preview' = {
  parent: apim
  name: 'keyvault-api'
  properties: {
    displayName: 'Keyvault API proxy'
    apiRevision: '1'
    subscriptionRequired: true
    serviceUrl: 'https://${kvNameStr}.${environment().suffixes.keyvaultDns}/'
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
    value: replace(loadTextContent('apim-apis-policy.xml'), '@KEYVAULTNAME@', kvNameStr)
    format: 'xml'
  }
}

resource apigetallsecrets 'Microsoft.ApiManagement/service/apis/operations@2023-09-01-preview' = {
  parent: apis
  name: 'all'
  properties: {
    displayName: 'all-secrets'
    method: 'GET'
    urlTemplate: '/all-secrets'
  }
}
