// ============================================================================
// Private Networking Module
// ============================================================================
// Deploys VNET, NSGs, private DNS zones, and private endpoints for secure
// connectivity to Azure Storage and Azure Key Vault.
// ============================================================================

// ============================================================================
// PARAMETERS
// ============================================================================

@description('The Azure region where resources will be deployed')
param location string

@description('Application name prefix for resource naming')
param applicationName string

@description('Environment name for resource naming')
param environment string

@description('Tags to apply to all resources')
param tags object

@description('Resource ID of the Storage Account for the private endpoint')
param storageAccountId string

@description('Name of the Storage Account for private endpoint naming')
param storageAccountName string

@description('Resource ID of the Key Vault for the private endpoint')
param keyVaultId string

@description('Name of the Key Vault for private endpoint naming')
param keyVaultName string

// ============================================================================
// VARIABLES
// ============================================================================

var virtualNetworkName = '${applicationName}-${environment}-vnet'
var containerAppSubnetName = 'containerapp'
var resourceSubnetName = 'resource'
var containerAppNsgName = '${applicationName}-${environment}-containerapp-nsg'
var resourceNsgName = '${applicationName}-${environment}-resource-nsg'

// ============================================================================
// NETWORK SECURITY GROUPS
// ============================================================================

// Network Security Group for the Container Apps subnet
resource containerAppNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: containerAppNsgName
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowVnetInbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
      {
        name: 'AllowVnetOutbound'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
      {
        name: 'AllowInternetOutbound'
        properties: {
          priority: 110
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: 'Internet'
        }
      }
    ]
  }
}

// Network Security Group for the resource (private endpoints) subnet
resource resourceNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: resourceNsgName
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowVnetHttpsInbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
      {
        name: 'DenyInternetInbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// ============================================================================
// VIRTUAL NETWORK
// ============================================================================

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: virtualNetworkName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: containerAppSubnetName
        properties: {
          addressPrefix: '10.0.0.0/23'
          networkSecurityGroup: {
            id: containerAppNsg.id
          }
          delegations: [
            {
              name: 'Microsoft.App.environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
      {
        name: resourceSubnetName
        properties: {
          addressPrefix: '10.0.2.0/24'
          networkSecurityGroup: {
            id: resourceNsg.id
          }
        }
      }
    ]
  }
}

// Named subnet references for safe non-positional access
resource containerAppSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: virtualNetwork
  name: containerAppSubnetName
}

resource resourceSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: virtualNetwork
  name: resourceSubnetName
}

// ============================================================================
// PRIVATE DNS ZONES
// ============================================================================

// Private DNS zone for Azure Blob Storage
resource storageDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.blob.${az.environment().suffixes.storage}'
  location: 'global'
  tags: tags
}

// Private DNS zone for Azure Key Vault
resource keyVaultDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.vaultcore.azure.net'
  location: 'global'
  tags: tags
}

// Link storage DNS zone to the virtual network
resource storageDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: storageDnsZone
  name: '${virtualNetworkName}-blob-link'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetwork.id
    }
  }
}

// Link Key Vault DNS zone to the virtual network
resource keyVaultDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: keyVaultDnsZone
  name: '${virtualNetworkName}-vault-link'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetwork.id
    }
  }
}

// ============================================================================
// PRIVATE ENDPOINTS
// ============================================================================

// Private endpoint for Azure Storage Account (blob)
resource storagePrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${storageAccountName}-blob-pe'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: resourceSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: '${storageAccountName}-blob-connection'
        properties: {
          privateLinkServiceId: storageAccountId
          groupIds: [
            'blob'
          ]
        }
      }
    ]
  }
}

// DNS zone group for storage private endpoint
resource storagePrivateEndpointDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: storagePrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob-dns-config'
        properties: {
          privateDnsZoneId: storageDnsZone.id
        }
      }
    ]
  }
}

// Private endpoint for Azure Key Vault
resource keyVaultPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${keyVaultName}-vault-pe'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: resourceSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: '${keyVaultName}-vault-connection'
        properties: {
          privateLinkServiceId: keyVaultId
          groupIds: [
            'vault'
          ]
        }
      }
    ]
  }
}

// DNS zone group for Key Vault private endpoint
resource keyVaultPrivateEndpointDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: keyVaultPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'vault-dns-config'
        properties: {
          privateDnsZoneId: keyVaultDnsZone.id
        }
      }
    ]
  }
}

// ============================================================================
// OUTPUTS
// ============================================================================

@description('The resource ID of the Container Apps subnet for VNET integration')
output containerAppSubnetId string = containerAppSubnet.id

@description('The resource ID of the resource subnet for private endpoints')
output resourceSubnetId string = resourceSubnet.id

@description('The name of the Virtual Network')
output virtualNetworkName string = virtualNetwork.name
