@description('Deterministic role assignment name.')
param name string

@description('Role definition resource ID.')
param roleDefinitionId string

@description('Principal object ID receiving the role assignment.')
param principalId string

@description('Principal type receiving the role assignment.')
param principalType string = 'ServicePrincipal'

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: name
  properties: {
    roleDefinitionId: roleDefinitionId
    principalId: principalId
    principalType: principalType
  }
}

output id string = roleAssignment.id
