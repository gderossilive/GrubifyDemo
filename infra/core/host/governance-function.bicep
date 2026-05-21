// Governance Function Module - AGT Hook Policy Service

@description('Azure region for resources.')
param location string = resourceGroup().location

@description('Governance Function App name.')
param functionAppName string

@description('Storage account name for the Function App runtime.')
param storageAccountName string

@description('App Service plan name for the Function App.')
param planName string

@description('Optional Application Insights connection string for telemetry.')
@secure()
param appInsightsConnectionString string = ''

@description('Tags applied to all resources.')
param tags object = {}

var storageBlobDataOwnerRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
var storageQueueDataContributorRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
var storageAccountContributorRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '17d1049b-9a84-46fb-8f53-869881c3d3ab')

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: union(tags, {
    component: 'agt-governance-storage'
  })
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource queueService 'Microsoft.Storage/storageAccounts/queueServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

var blobServiceUri = 'https://${storage.name}.blob.${environment().suffixes.storage}'
var queueServiceUri = 'https://${storage.name}.queue.${environment().suffixes.storage}'

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  tags: union(tags, {
    component: 'agt-governance-plan'
  })
  kind: 'linux'
  sku: {
    name: 'B1'
    tier: 'Basic'
    capacity: 1
  }
  properties: {
    reserved: true
  }
}

var baseAppSettings = [
  {
    name: 'AzureWebJobsStorage__accountName'
    value: storage.name
  }
  {
    name: 'AzureWebJobsStorage__credential'
    value: 'managedidentity'
  }
  {
    name: 'AzureWebJobsStorage__blobServiceUri'
    value: blobServiceUri
  }
  {
    name: 'AzureWebJobsStorage__queueServiceUri'
    value: queueServiceUri
  }
  {
    name: 'FUNCTIONS_EXTENSION_VERSION'
    value: '~4'
  }
  {
    name: 'FUNCTIONS_WORKER_RUNTIME'
    value: 'python'
  }
  {
    name: 'AzureWebJobsFeatureFlags'
    value: 'EnableWorkerIndexing'
  }
  {
    name: 'AGT_POLICY_PATH'
    value: 'policies/grubify-sre-agent-policy-agt.yaml'
  }
  {
    name: 'AGT_MODE'
    value: 'agt-policy'
  }
  {
    name: 'AGT_AUDIT_STDOUT'
    value: 'true'
  }
  {
    name: 'SCM_DO_BUILD_DURING_DEPLOYMENT'
    value: 'true'
  }
  {
    name: 'ENABLE_ORYX_BUILD'
    value: 'true'
  }
]

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  tags: union(tags, {
    component: 'agt-governance'
    'azd-service-name': 'governance'
  })
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'Python|3.11'
      alwaysOn: true
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      appSettings: empty(appInsightsConnectionString) ? baseAppSettings : concat(baseAppSettings, [
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsightsConnectionString
        }
      ])
    }
  }
}

resource blobDataOwnerRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, functionApp.id, storageBlobDataOwnerRoleDefinitionId)
  properties: {
    roleDefinitionId: storageBlobDataOwnerRoleDefinitionId
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource queueDataContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, functionApp.id, storageQueueDataContributorRoleDefinitionId)
  properties: {
    roleDefinitionId: storageQueueDataContributorRoleDefinitionId
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource storageAccountContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, functionApp.id, storageAccountContributorRoleDefinitionId)
  properties: {
    roleDefinitionId: storageAccountContributorRoleDefinitionId
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output functionAppName string = functionApp.name
output functionAppUrl string = 'https://${functionApp.properties.defaultHostName}'
output functionAppPrincipalId string = functionApp.identity.principalId
