@description('Name of the virtual network used by the SRE Agent sandbox.')
param vnetName string

@description('Name of the subnet delegated for SRE Agent sandbox integration.')
param subnetName string

@description('Name of the NAT Gateway used for SRE Agent sandbox outbound egress.')
param natGatewayName string

@description('Name of the public IP used by the SRE Agent sandbox NAT Gateway.')
param natPublicIpName string

@description('Azure region for the SRE Agent VNet resources.')
param location string = resourceGroup().location

@description('Address prefix for the SRE Agent virtual network.')
param vnetAddressPrefix string = '10.80.0.0/16'

@description('Address prefix for the delegated SRE Agent subnet.')
param subnetAddressPrefix string = '10.80.0.0/24'

@description('Tags applied to all resources.')
param tags object = {}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  tags: union(tags, {
    component: 'sre-agent-vnet'
  })
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
  }
}

resource natPublicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: natPublicIpName
  location: location
  tags: union(tags, {
    component: 'sre-agent-nat-ip'
  })
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource natGateway 'Microsoft.Network/natGateways@2023-11-01' = {
  name: natGatewayName
  location: location
  tags: union(tags, {
    component: 'sre-agent-nat'
  })
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIpAddresses: [
      {
        id: natPublicIp.id
      }
    ]
  }
}

resource delegatedSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = {
  parent: virtualNetwork
  name: subnetName
  properties: {
    addressPrefix: subnetAddressPrefix
    natGateway: {
      id: natGateway.id
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

output vnetId string = virtualNetwork.id
output vnetName string = virtualNetwork.name
output subnetId string = delegatedSubnet.id
output subnetName string = subnetName
output natGatewayId string = natGateway.id
output natPublicIpAddress string = natPublicIp.properties.ipAddress
