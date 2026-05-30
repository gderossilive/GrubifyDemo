@description('Azure region for the Key Vault.')
param location string = resourceGroup().location

@description('Key Vault name.')
param name string

@description('Object IDs of principals allowed to read GitHub PAT secrets.')
param secretsUserPrincipalIds array

@description('Tags applied to the Key Vault.')
param tags object = {}

var keyVaultSecretsUserRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: name
  location: location
  tags: union(tags, {
    component: 'sre-agent-github-auth'
  })
  properties: {
    tenantId: tenant().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enabledForTemplateDeployment: false
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Enabled'
  }
}

resource secretsUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for principalId in secretsUserPrincipalIds: if (!empty(principalId)) {
  scope: vault
  name: guid(vault.id, principalId, keyVaultSecretsUserRoleDefinitionId)
  properties: {
    roleDefinitionId: keyVaultSecretsUserRoleDefinitionId
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}]

output name string = vault.name
output id string = vault.id
output vaultUri string = vault.properties.vaultUri
