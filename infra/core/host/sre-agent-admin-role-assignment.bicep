@description('SRE Agent resource name.')
param agentName string

@description('SRE Agent Administrator role definition resource ID.')
param roleDefinitionId string

@description('Principal object ID receiving SRE Agent Administrator on the agent.')
param principalId string

#disable-next-line BCP081
resource sreAgent 'Microsoft.App/agents@2025-05-01-preview' existing = {
  name: agentName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sreAgent.id, principalId, roleDefinitionId)
  scope: sreAgent
  properties: {
    roleDefinitionId: roleDefinitionId
    principalId: principalId
  }
}

output id string = roleAssignment.id
