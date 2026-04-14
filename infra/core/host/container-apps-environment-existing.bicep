param name string

resource env 'Microsoft.App/managedEnvironments@2023-05-01' existing = {
  name: name
}

output id string = env.id
output name string = env.name
output defaultDomain string = env.properties.defaultDomain
