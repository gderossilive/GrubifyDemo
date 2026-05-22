@description('Azure region for SRE observability resources.')
param location string = resourceGroup().location

@description('Log Analytics workspace name.')
param logAnalyticsWorkspaceName string

@description('Application Insights component name.')
param applicationInsightsName string

@description('Tags applied to all resources.')
param tags object = {}

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsWorkspaceName
  location: location
  tags: union(tags, {
    component: 'sre-agent-logs'
  })
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

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: applicationInsightsName
  location: location
  tags: union(tags, {
    component: 'sre-agent-appinsights'
  })
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
  }
}

output logAnalyticsWorkspaceId string = workspace.id
output logAnalyticsCustomerId string = workspace.properties.customerId
output applicationInsightsId string = appInsights.id
output applicationInsightsAppId string = appInsights.properties.AppId
output applicationInsightsConnectionString string = appInsights.properties.ConnectionString
