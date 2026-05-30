targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the the environment which is used to generate a short unique hash used in all resources.')
param environmentName string

@minLength(1)
@description('Primary location for all resources')
param location string

@description('Name of the resource group')
param resourceGroupName string = ''

@minLength(5)
@maxLength(5)
@description('Five-character lowercase alphanumeric token used to make a Grubify deployment unique.')
param resourceToken string = take(toLower(uniqueString(environmentName)), 5)

@description('API container image')
param apiImage string = ''

@description('Frontend container image')
param frontendImage string = ''

@description('Resource ID of an existing Container Apps Environment to reuse. Leave empty to provision a new one.')
param existingContainerAppsEnvironmentId string = ''

@description('Name of the resource group for SRE Agent resources.')
param sreResourceGroupName string = ''

@description('SRE Agent ARM resource name.')
param sreAgentName string = 'sre-agent-grubify'

@description('SRE Agent user-assigned managed identity name.')
param sreIdentityName string = 'id-sre-grubify'

@description('SRE Agent Log Analytics workspace name.')
param sreLogAnalyticsWorkspaceName string = 'law-sre-grubify'

@description('SRE Agent Application Insights component name.')
param sreApplicationInsightsName string = 'appi-sre-grubify'

@description('Name of the Key Vault in the SRE Agent resource group that stores the GitHub PAT secret used for workflow dispatch fallback.')
param sreGithubPatKeyVaultName string = 'kv-sre-grubify-${resourceToken}'

@description('Name of the Key Vault secret containing the GitHub PAT used by deployment-manager fallback workflow dispatch.')
param sreGithubPatSecretName string = 'GH-PAT'

@allowed([
  'Low'
  'Medium'
  'High'
])
@description('SRE Agent action access level.')
param sreAccessLevel string = 'High'

@allowed([
  'autonomous'
  'copilot'
])
@description('SRE Agent action mode.')
param sreActionMode string = 'autonomous'

@description('Additional resource IDs registered as SRE Agent managed resources.')
param sreTargetResourceIds array = []

@description('ARM-supported SRE Agent connector definitions.')
param sreConnectors array = []

@description('Incident management configuration for the SRE Agent.')
param sreIncidentManagementConfiguration object = {
  type: 'AzMonitor'
  connectionName: 'azmonitor'
}

@description('Resource ID of an existing subnet delegated to Microsoft.App/environments for SRE Agent sandbox VNet integration. Leave empty to provision a new VNet and subnet.')
param sreAgentExistingSubnetResourceId string = ''

@description('Enable SRE Agent sandbox VNet integration. Leave disabled until the Microsoft.App/agents preview data plane supports the configured VNet shape without returning 404 for the agent site.')
param enableSreAgentVnetIntegration bool = false

@description('Name of the virtual network provisioned for SRE Agent sandbox VNet integration.')
param sreAgentVnetName string = 'vnet-sre-agent-${resourceToken}'

@description('Name of the subnet delegated for SRE Agent sandbox VNet integration.')
param sreAgentSubnetName string = 'snet-sre-agent-${resourceToken}'

@description('Name of the NAT Gateway used by SRE Agent sandbox VNet integration.')
param sreAgentNatGatewayName string = 'nat-sre-agent-${resourceToken}'

@description('Name of the public IP used by the SRE Agent sandbox NAT Gateway.')
param sreAgentNatPublicIpName string = 'pip-sre-agent-nat-${resourceToken}'

@description('Address prefix for the SRE Agent virtual network.')
param sreAgentVnetAddressPrefix string = '10.80.0.0/16'

@description('Address prefix for the delegated SRE Agent subnet.')
param sreAgentSubnetAddressPrefix string = '10.80.0.0/24'

var abbrs = loadJsonContent('abbreviations.json')
var tags = { 'azd-env-name': environmentName }
var useExistingEnv = !empty(existingContainerAppsEnvironmentId)
var useSreAgentVnetIntegration = enableSreAgentVnetIntegration
var useExistingSreAgentSubnet = useSreAgentVnetIntegration && !empty(sreAgentExistingSubnetResourceId)
var existingEnvRg = useExistingEnv ? split(existingContainerAppsEnvironmentId, '/')[4] : 'placeholder'
var existingEnvName = useExistingEnv ? last(split(existingContainerAppsEnvironmentId, '/')) : 'placeholder'
var governanceFunctionName = 'func-agt-grubify-${resourceToken}'
var governanceStorageName = 'stagtgrubify${resourceToken}'
var governancePlanName = 'plan-agt-grubify-${resourceToken}'
var monitoringReaderRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '43d0d8ad-25c7-4714-9337-8ba259a9fe05')
var contributorRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')

// Organize resources in a resource group
resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: !empty(resourceGroupName) ? resourceGroupName : 'rg-grubify-app-${resourceToken}'
  location: location
  tags: tags
}

resource sreRg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: !empty(sreResourceGroupName) ? sreResourceGroupName : 'rg-grubify-sre-${resourceToken}'
  location: location
  tags: tags
}

// Container registry
module containerRegistry 'core/host/container-registry.bicep' = {
  name: 'container-registry'
  scope: rg
  params: {
    name: '${abbrs.containerRegistryRegistries}${resourceToken}'
    location: location
    tags: tags
  }
}

// Container Apps Environment — provision new or look up existing
module containerAppsEnvironment 'core/host/container-apps-environment.bicep' = if (!useExistingEnv) {
  name: 'container-apps-environment'
  scope: rg
  params: {
    name: '${abbrs.appManagedEnvironments}${resourceToken}'
    location: location
    tags: tags
  }
}

// Look up properties of an existing Container Apps Environment (cross-RG)
module existingEnvLookup 'core/host/container-apps-environment-existing.bicep' = if (useExistingEnv) {
  name: 'existing-env-lookup'
  scope: resourceGroup(existingEnvRg)
  params: {
    name: existingEnvName
  }
}

var envId = useExistingEnv ? existingContainerAppsEnvironmentId : containerAppsEnvironment!.outputs.id
var envDefaultDomain = useExistingEnv ? existingEnvLookup!.outputs.defaultDomain : containerAppsEnvironment!.outputs.defaultDomain

// Container app for the API
module api 'core/host/container-app.bicep' = {
  name: 'api'
  scope: rg
  params: {
    name: 'ca-grubify-api-${resourceToken}'
    location: location
    tags: union(tags, { 'azd-service-name': 'api' })
    containerAppsEnvironmentId: envId
    containerRegistryName: containerRegistry.outputs.name
    containerName: 'grubify-api'
    containerImage: !empty(apiImage) ? apiImage : 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
    targetPort: 8080
    external: true
    minReplicas: 1  // Always keep 1 instance running
    maxReplicas: 1  // No autoscaling - single instance only
    env: [
      {
        name: 'ASPNETCORE_ENVIRONMENT'
        value: 'Production'
      }
      {
        name: 'AllowedOrigins__0'
        value: 'https://ca-grubify-frontend-${resourceToken}.${envDefaultDomain}'
      }
    ]
  }
}

// Container app for the frontend
module frontend 'core/host/container-app.bicep' = {
  name: 'frontend'
  scope: rg
  params: {
    name: 'ca-grubify-frontend-${resourceToken}'
    location: location
    tags: union(tags, { 'azd-service-name': 'frontend' })
    containerAppsEnvironmentId: envId
    containerRegistryName: containerRegistry.outputs.name
    containerName: 'grubify-frontend'
    containerImage: !empty(frontendImage) ? frontendImage : 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
    targetPort: 80
    external: true
    minReplicas: 1  // Always keep 1 instance running
    maxReplicas: 1  // No autoscaling - single instance only
    env: [
      {
        name: 'REACT_APP_API_BASE_URL'
        value: 'https://${api.outputs.fqdn}/api'
      }
    ]
  }
}

// AGT governance Function App for SRE Agent hook policy evaluation
module governanceFunction 'core/host/governance-function.bicep' = {
  name: 'governance-function'
  scope: rg
  params: {
    location: location
    functionAppName: governanceFunctionName
    storageAccountName: governanceStorageName
    planName: governancePlanName
    tags: union(tags, { 'azd-service-name': 'governance' })
  }
}

// SRE Agent monitoring resources
module sreObservability 'core/host/sre-observability.bicep' = {
  name: 'sre-observability'
  scope: sreRg
  params: {
    location: location
    logAnalyticsWorkspaceName: sreLogAnalyticsWorkspaceName
    applicationInsightsName: sreApplicationInsightsName
    tags: tags
  }
}

// SRE Agent sandbox VNet integration subnet
module sreAgentVnet 'core/host/sre-agent-vnet.bicep' = if (useSreAgentVnetIntegration && !useExistingSreAgentSubnet) {
  name: 'sre-agent-vnet'
  scope: sreRg
  params: {
    vnetName: sreAgentVnetName
    subnetName: sreAgentSubnetName
    natGatewayName: sreAgentNatGatewayName
    natPublicIpName: sreAgentNatPublicIpName
    location: location
    vnetAddressPrefix: sreAgentVnetAddressPrefix
    subnetAddressPrefix: sreAgentSubnetAddressPrefix
    tags: tags
  }
}

var sreAgentSubnetResourceId = useSreAgentVnetIntegration ? (useExistingSreAgentSubnet ? sreAgentExistingSubnetResourceId : sreAgentVnet!.outputs.subnetId) : ''

// SRE Agent ARM resource and managed identity
module sreAgent 'core/host/sre-agent.bicep' = {
  name: 'sre-agent'
  scope: sreRg
  params: {
    location: location
    agentName: sreAgentName
    identityName: sreIdentityName
    targetResourceIds: union([
      rg.id
    ], sreTargetResourceIds)
    appInsightsAppId: sreObservability.outputs.applicationInsightsAppId
    appInsightsResourceId: sreObservability.outputs.applicationInsightsId
    appInsightsConnectionString: sreObservability.outputs.applicationInsightsConnectionString
    accessLevel: sreAccessLevel
    actionMode: sreActionMode
    incidentManagementConfiguration: sreIncidentManagementConfiguration
    subnetResourceId: sreAgentSubnetResourceId
    tags: tags
  }
}

module sreIdentityAppMonitoringReader 'core/host/role-assignment.bicep' = {
  name: 'sre-identity-app-monitoring-reader'
  scope: rg
  params: {
    name: guid(rg.id, sreIdentityName, monitoringReaderRoleDefinitionId)
    roleDefinitionId: monitoringReaderRoleDefinitionId
    principalId: sreAgent.outputs.identityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

module sreIdentityAppContributor 'core/host/role-assignment.bicep' = {
  name: 'sre-identity-app-contributor'
  scope: rg
  params: {
    name: guid(rg.id, sreIdentityName, contributorRoleDefinitionId)
    roleDefinitionId: contributorRoleDefinitionId
    principalId: sreAgent.outputs.identityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

module sreIdentitySreMonitoringReader 'core/host/role-assignment.bicep' = {
  name: 'sre-identity-sre-monitoring-reader'
  scope: sreRg
  params: {
    name: guid(sreRg.id, sreIdentityName, monitoringReaderRoleDefinitionId)
    roleDefinitionId: monitoringReaderRoleDefinitionId
    principalId: sreAgent.outputs.identityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

module sreGithubPatKeyVault 'core/host/key-vault.bicep' = {
  name: 'sre-github-pat-key-vault'
  scope: sreRg
  params: {
    location: location
    name: sreGithubPatKeyVaultName
    secretsUserPrincipalIds: [
      sreAgent.outputs.identityPrincipalId
      sreAgent.outputs.agentPrincipalId
    ]
    tags: tags
  }
}

// ARM-supported SRE Agent connector child resources
module sreAgentExtensions 'core/host/sre-agent-extensions.bicep' = if (!empty(sreConnectors)) {
  name: 'sre-agent-extensions'
  scope: sreRg
  params: {
    agentName: sreAgent.outputs.agentName
    connectors: sreConnectors
  }
}

// App outputs
output AZURE_LOCATION string = location
output AZURE_TENANT_ID string = tenant().tenantId
output AZURE_RESOURCE_GROUP string = rg.name
output RESOURCE_GROUP_ID string = rg.id
output SRE_AGENT_RESOURCE_GROUP string = sreRg.name

output AZURE_CONTAINER_REGISTRY_ENDPOINT string = containerRegistry.outputs.loginServer
output AZURE_CONTAINER_REGISTRY_NAME string = containerRegistry.outputs.name

output API_BASE_URL string = 'https://${api.outputs.fqdn}'
output FRONTEND_URL string = 'https://${frontend.outputs.fqdn}'
output AGT_FUNCTION_URL string = governanceFunction.outputs.functionAppUrl
output AGT_FUNCTION_NAME string = governanceFunction.outputs.functionAppName
output AGT_FUNCTION_PRINCIPAL_ID string = governanceFunction.outputs.functionAppPrincipalId
output SERVICE_GOVERNANCE_NAME string = governanceFunction.outputs.functionAppName
output SRE_AGENT_NAME string = sreAgent.outputs.agentName
output SRE_AGENT_ID string = sreAgent.outputs.agentId
output SRE_AGENT_ENDPOINT string = sreAgent.outputs.agentEndpoint
output SRE_AGENT_PRINCIPAL_ID string = sreAgent.outputs.agentPrincipalId
output SRE_AGENT_IDENTITY_ID string = sreAgent.outputs.identityId
output SRE_AGENT_IDENTITY_NAME string = sreAgent.outputs.identityName
output SRE_AGENT_IDENTITY_PRINCIPAL_ID string = sreAgent.outputs.identityPrincipalId
output SRE_GITHUB_PAT_KEY_VAULT_NAME string = sreGithubPatKeyVault.outputs.name
output SRE_GITHUB_PAT_KEY_VAULT_URI string = sreGithubPatKeyVault.outputs.vaultUri
output SRE_GITHUB_PAT_SECRET_NAME string = sreGithubPatSecretName
output SRE_AGENT_SUBNET_RESOURCE_ID string = sreAgentSubnetResourceId
output SRE_AGENT_NAT_PUBLIC_IP string = !useSreAgentVnetIntegration || useExistingSreAgentSubnet ? '' : sreAgentVnet!.outputs.natPublicIpAddress
output SRE_LOG_ANALYTICS_WORKSPACE_ID string = sreObservability.outputs.logAnalyticsWorkspaceId
output SRE_APP_INSIGHTS_RESOURCE_ID string = sreObservability.outputs.applicationInsightsId
output SRE_APP_INSIGHTS_APP_ID string = sreObservability.outputs.applicationInsightsAppId
