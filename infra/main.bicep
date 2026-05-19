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

var abbrs = loadJsonContent('abbreviations.json')
var tags = { 'azd-env-name': environmentName }
var useExistingEnv = !empty(existingContainerAppsEnvironmentId)
var existingEnvRg = useExistingEnv ? split(existingContainerAppsEnvironmentId, '/')[4] : 'placeholder'
var existingEnvName = useExistingEnv ? last(split(existingContainerAppsEnvironmentId, '/')) : 'placeholder'

// Organize resources in a resource group
resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: !empty(resourceGroupName) ? resourceGroupName : 'rg-grubify-app-${resourceToken}'
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

var envId = useExistingEnv ? existingContainerAppsEnvironmentId : containerAppsEnvironment.outputs.id
var envDefaultDomain = useExistingEnv ? existingEnvLookup.outputs.defaultDomain : containerAppsEnvironment.outputs.defaultDomain

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

// App outputs
output AZURE_LOCATION string = location
output AZURE_TENANT_ID string = tenant().tenantId
output AZURE_RESOURCE_GROUP string = rg.name
output RESOURCE_GROUP_ID string = rg.id

output AZURE_CONTAINER_REGISTRY_ENDPOINT string = containerRegistry.outputs.loginServer
output AZURE_CONTAINER_REGISTRY_NAME string = containerRegistry.outputs.name

output API_BASE_URL string = 'https://${api.outputs.fqdn}'
output FRONTEND_URL string = 'https://${frontend.outputs.fqdn}'
