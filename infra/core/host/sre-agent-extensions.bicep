@description('SRE Agent resource name.')
param agentName string

@description('ARM-supported connector definitions. Each entry must include name and properties.')
param connectors array = []

#disable-next-line BCP081
resource sreAgent 'Microsoft.App/agents@2025-05-01-preview' existing = {
  name: agentName
}

#disable-next-line BCP081
resource connectorResources 'Microsoft.App/agents/connectors@2025-05-01-preview' = [for connector in connectors: {
  parent: sreAgent
  name: connector.name
  properties: connector.?properties ?? {}
}]

output connectorNames array = [for connector in connectors: connector.name]
