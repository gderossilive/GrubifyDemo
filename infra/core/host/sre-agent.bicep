@description('Azure region for the SRE Agent resource.')
param location string = resourceGroup().location

@description('SRE Agent ARM resource name.')
param agentName string

@description('User-assigned managed identity name used by the SRE Agent.')
param identityName string

@description('Target resource IDs registered as SRE Agent managed resources.')
param targetResourceIds array

@description('Application Insights app ID used by SRE Agent internal telemetry.')
param appInsightsAppId string

@description('Application Insights resource ID used by SRE Agent internal telemetry.')
param appInsightsResourceId string

@secure()
@description('Application Insights connection string used by SRE Agent internal telemetry.')
param appInsightsConnectionString string

@allowed([
  'Low'
  'Medium'
  'High'
])
@description('SRE Agent action access level.')
param accessLevel string = 'High'

@allowed([
  'autonomous'
  'copilot'
])
@description('SRE Agent action mode.')
param actionMode string = 'autonomous'

@description('Incident management configuration for the SRE Agent.')
param incidentManagementConfiguration object = {
  type: 'AzMonitor'
  connectionName: 'azmonitor'
}

@description('Monthly SRE Agent unit limit.')
param monthlyAgentUnitLimit int = 10000

@description('Resource ID of the subnet delegated to Microsoft.App/environments for SRE Agent sandbox VNet integration. Leave empty to disable VNet integration.')
param subnetResourceId string = ''

@description('Tags applied to all resources.')
param tags object = {}

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
  tags: union(tags, {
    component: 'sre-agent-identity'
  })
}

#disable-next-line BCP081
resource sreAgent 'Microsoft.App/agents@2025-05-01-preview' = {
  name: agentName
  location: location
  tags: union(tags, {
    component: 'sre-agent'
  })
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: union({
    actionConfiguration: {
      accessLevel: accessLevel
      mode: actionMode
      identity: identity.id
    }
    incidentManagementConfiguration: incidentManagementConfiguration
    knowledgeGraphConfiguration: {
      identity: identity.id
      managedResources: targetResourceIds
    }
    logConfiguration: {
      applicationInsightsConfiguration: {
        appId: appInsightsAppId
        applicationInsightsResourceId: appInsightsResourceId
        connectionString: appInsightsConnectionString
      }
    }
    monthlyAgentUnitLimit: monthlyAgentUnitLimit
    upgradeChannel: 'Preview'
    experimentalSettings: {
      EnableSandboxGroup: true
      EnableWorkspaceTools: true
      EnableV2AgentLoop: true
    }
  }, !empty(subnetResourceId) ? {
    vnetConfiguration: {
      subnetResourceId: subnetResourceId
    }
  } : {})
}

output agentName string = sreAgent.name
output agentId string = sreAgent.id
#disable-next-line BCP053
output agentEndpoint string = sreAgent.properties.agentEndpoint
output agentPrincipalId string = sreAgent.identity.principalId
output identityId string = identity.id
output identityName string = identity.name
output identityPrincipalId string = identity.properties.principalId
