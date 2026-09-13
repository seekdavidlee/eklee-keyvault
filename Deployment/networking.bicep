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

var virtualNetworkName = !empty(existingVirtualNetworkName) ? existingVirtualNetworkName : '${applicationName}-${environment}-vnet'
var containerAppSubnetName = 'containerapp'
var resourceSubnetName = 'resource'
var containerAppNsgName = !empty(existingContainerAppNsgName) ? existingContainerAppNsgName : '${applicationName}-${environment}-containerapp-nsg'
var resourceNsgName = !empty(existingResourceNsgName) ? existingResourceNsgName : '${applicationName}-${environment}-resource-nsg'
var storageDnsZoneName = !empty(existingStoragePrivateDnsZoneName) ? existingStoragePrivateDnsZoneName : 'privatelink.blob.${az.environment().suffixes.storage}'
var keyVaultDnsZoneName = !empty(existingKeyVaultPrivateDnsZoneName) ? existingKeyVaultPrivateDnsZoneName : 'privatelink.vaultcore.azure.net'
var storageDnsZoneLinkName = !empty(existingStoragePrivateDnsZoneLinkName) ? existingStoragePrivateDnsZoneLinkName : '${virtualNetworkName}-blob-link'
var keyVaultDnsZoneLinkName = !empty(existingKeyVaultPrivateDnsZoneLinkName) ? existingKeyVaultPrivateDnsZoneLinkName : '${virtualNetworkName}-vault-link'
var storagePrivateEndpointName = !empty(existingStoragePrivateEndpointName) ? existingStoragePrivateEndpointName : '${storageAccountName}-blob-pe'
var keyVaultPrivateEndpointName = !empty(existingKeyVaultPrivateEndpointName) ? existingKeyVaultPrivateEndpointName : '${keyVaultName}-vault-pe'
var virtualNetworkTags = union(tags, { 'resource-id': 'app-virtual-network' })
var containerAppNsgTags = union(tags, { 'resource-id': 'app-container-app-network-security-group' })
var resourceNsgTags = union(tags, { 'resource-id': 'app-resource-network-security-group' })
var storageDnsZoneTags = union(tags, { 'resource-id': 'app-storage-private-dns-zone' })
var keyVaultDnsZoneTags = union(tags, { 'resource-id': 'app-key-vault-private-dns-zone' })
var storageDnsZoneLinkTags = union(tags, { 'resource-id': 'app-storage-private-dns-zone-link' })
var keyVaultDnsZoneLinkTags = union(tags, { 'resource-id': 'app-key-vault-private-dns-zone-link' })
var storagePrivateEndpointTags = union(tags, { 'resource-id': 'app-storage-private-endpoint' })
var keyVaultPrivateEndpointTags = union(tags, { 'resource-id': 'app-key-vault-private-endpoint' })

// ============================================================================
// NETWORK SECURITY GROUPS
// ============================================================================

// Network Security Group for the Container Apps subnet
resource containerAppNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: containerAppNsgName
  location: location
  tags: containerAppNsgTags
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
  tags: resourceNsgTags
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
  tags: virtualNetworkTags
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
  name: storageDnsZoneName
  location: 'global'
  tags: storageDnsZoneTags
}

// Private DNS zone for Azure Key Vault
resource keyVaultDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: keyVaultDnsZoneName
  location: 'global'
  tags: keyVaultDnsZoneTags
}

// Link storage DNS zone to the virtual network
resource storageDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: storageDnsZone
  name: storageDnsZoneLinkName
  location: 'global'
  tags: storageDnsZoneLinkTags
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
  name: keyVaultDnsZoneLinkName
  location: 'global'
  tags: keyVaultDnsZoneLinkTags
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
  name: storagePrivateEndpointName
  location: location
  tags: storagePrivateEndpointTags
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
  name: keyVaultPrivateEndpointName
  location: location
  tags: keyVaultPrivateEndpointTags
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

@description('The name of the Virtual Network')
output virtualNetworkName string = virtualNetwork.name
