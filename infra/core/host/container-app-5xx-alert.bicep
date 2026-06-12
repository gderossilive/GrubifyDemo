param name string
param location string = resourceGroup().location
param tags object = {}

param targetResourceId string
param targetResourceRegion string = location
param severity int = 2
param threshold int = 5
param evaluationFrequency string = 'PT1M'
param windowSize string = 'PT1M'

resource alert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: name
  location: 'global'
  tags: tags
  properties: {
    description: 'Grubify API HTTP 5xx responses'
    severity: severity
    enabled: true
    scopes: [
      targetResourceId
    ]
    evaluationFrequency: evaluationFrequency
    windowSize: windowSize
    targetResourceType: 'Microsoft.App/containerApps'
    targetResourceRegion: targetResourceRegion
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'http5xx'
          metricNamespace: 'Microsoft.App/containerApps'
          metricName: 'Requests'
          operator: 'GreaterThan'
          threshold: threshold
          timeAggregation: 'Total'
          criterionType: 'StaticThresholdCriterion'
          dimensions: [
            {
              name: 'statuscodecategory'
              operator: 'Include'
              values: [
                '5xx'
              ]
            }
          ]
        }
      ]
    }
    actions: []
  }
}

output id string = alert.id
output name string = alert.name