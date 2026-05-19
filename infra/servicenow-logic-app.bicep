@description('Location for the Logic App.')
param location string = resourceGroup().location

@description('Name of the Logic App workflow.')
param logicAppName string = 'la-grubify-servicenow-handler'

@description('ServiceNow instance base URL, for example https://dev12345.service-now.com.')
param serviceNowInstanceUrl string

@description('ServiceNow username used for the Table API.')
param serviceNowUsername string

@secure()
@description('ServiceNow password used for the Table API.')
param serviceNowPassword string

@description('Optional ServiceNow assignment group sys_id or display value.')
param serviceNowAssignmentGroup string = ''

@description('ServiceNow category for generated incidents.')
param serviceNowCategory string = 'software'

@description('SRE Agent HTTP trigger URL that receives the enriched alert payload.')
@secure()
param sreTriggerUrl string

@description('Tags applied to the Logic App.')
param tags object = {
  app: 'grubify'
  component: 'servicenow-handler'
}

var normalizedInstanceUrl = trim(serviceNowInstanceUrl)
var alertCorrelationId = '@{coalesce(triggerBody()?[\'data\']?[\'essentials\']?[\'originAlertId\'], triggerBody()?[\'data\']?[\'essentials\']?[\'alertId\'], workflow().run.name)}'
var readableAlertShortDescription = '@{concat(\'Grubify: \', coalesce(triggerBody()?[\'data\']?[\'essentials\']?[\'alertRule\'], \'Azure Monitor alert\'))}'
var readableAlertDescription = '@{concat(\'Grubify Azure Monitor Alert\', decodeUriComponent(\'%0A%0A\'), \'Alert rule: \', coalesce(triggerBody()?[\'data\']?[\'essentials\']?[\'alertRule\'], \'n/a\'), decodeUriComponent(\'%0A\'), \'Severity: \', coalesce(triggerBody()?[\'data\']?[\'essentials\']?[\'severity\'], \'n/a\'), decodeUriComponent(\'%0A\'), \'Condition: \', coalesce(triggerBody()?[\'data\']?[\'essentials\']?[\'monitorCondition\'], \'n/a\'), decodeUriComponent(\'%0A\'), \'Signal type: \', coalesce(triggerBody()?[\'data\']?[\'essentials\']?[\'signalType\'], \'n/a\'), decodeUriComponent(\'%0A\'), \'Fired at: \', coalesce(triggerBody()?[\'data\']?[\'essentials\']?[\'firedDateTime\'], \'n/a\'), decodeUriComponent(\'%0A%0A\'), \'Affected resource(s):\', decodeUriComponent(\'%0A- \'), join(coalesce(triggerBody()?[\'data\']?[\'essentials\']?[\'alertTargetIDs\'], createArray(\'n/a\')), decodeUriComponent(\'%0A- \')), decodeUriComponent(\'%0A%0A\'), \'Description:\', decodeUriComponent(\'%0A\'), coalesce(triggerBody()?[\'data\']?[\'essentials\']?[\'description\'], \'No alert description provided.\'))}'
var readableAlertComments = '@{concat(\'Created automatically by the Grubify ServiceNow incident router.\', decodeUriComponent(\'%0A%0A\'), \'Correlation ID: \', coalesce(triggerBody()?[\'data\']?[\'essentials\']?[\'originAlertId\'], triggerBody()?[\'data\']?[\'essentials\']?[\'alertId\'], workflow().run.name), decodeUriComponent(\'%0A\'), \'Azure alert ID: \', coalesce(triggerBody()?[\'data\']?[\'essentials\']?[\'alertId\'], \'n/a\'), decodeUriComponent(\'%0A\'), \'Origin alert ID: \', coalesce(triggerBody()?[\'data\']?[\'essentials\']?[\'originAlertId\'], \'n/a\'), decodeUriComponent(\'%0A\'), \'Investigation link: \', coalesce(triggerBody()?[\'data\']?[\'essentials\']?[\'investigationLink\'], \'n/a\'), decodeUriComponent(\'%0A%0A\'), \'The SRE Agent has been notified and will investigate/remediate autonomously.\')}'
var incidentPayload = empty(serviceNowAssignmentGroup) ? {
  short_description: readableAlertShortDescription
  description: readableAlertDescription
  category: serviceNowCategory
  urgency: '2'
  impact: '2'
  contact_type: 'integration'
  correlation_id: alertCorrelationId
  correlation_display: 'Grubify HTTP 5xx signal'
  comments: readableAlertComments
} : {
  short_description: readableAlertShortDescription
  description: readableAlertDescription
  category: serviceNowCategory
  urgency: '2'
  impact: '2'
  contact_type: 'integration'
  assignment_group: serviceNowAssignmentGroup
  correlation_id: alertCorrelationId
  correlation_display: 'Grubify HTTP 5xx signal'
  comments: readableAlertComments
}

resource serviceNowWorkflow 'Microsoft.Logic/workflows@2019-05-01' = {
  name: logicAppName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    state: 'Enabled'
    parameters: {
      serviceNowInstanceUrl: {
        value: normalizedInstanceUrl
      }
      serviceNowUsername: {
        value: serviceNowUsername
      }
      serviceNowPassword: {
        value: serviceNowPassword
      }
      sreTriggerUrl: {
        value: sreTriggerUrl
      }
    }
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      parameters: {
        serviceNowInstanceUrl: {
          type: 'String'
        }
        serviceNowUsername: {
          type: 'String'
        }
        serviceNowPassword: {
          type: 'SecureString'
        }
        sreTriggerUrl: {
          type: 'SecureString'
        }
      }
      triggers: {
        manual: {
          type: 'Request'
          kind: 'Http'
          inputs: {
            schema: {
              type: 'object'
              additionalProperties: true
            }
          }
        }
      }
      actions: {
        Create_ServiceNow_incident: {
          type: 'Http'
          inputs: {
            method: 'POST'
            uri: '@{concat(parameters(\'serviceNowInstanceUrl\'), \'/api/now/table/incident\')}'
            headers: {
              Accept: 'application/json'
              'Content-Type': 'application/json'
            }
            authentication: {
              type: 'Basic'
              username: '@parameters(\'serviceNowUsername\')'
              password: '@parameters(\'serviceNowPassword\')'
            }
            body: incidentPayload
          }
        }
        Forward_to_SRE_Agent: {
          type: 'Http'
          runAfter: {
            Create_ServiceNow_incident: [
              'Succeeded'
            ]
          }
          inputs: {
            method: 'POST'
            uri: '@parameters(\'sreTriggerUrl\')'
            authentication: {
              type: 'ManagedServiceIdentity'
              audience: 'https://azuresre.ai'
            }
            headers: {
              'Content-Type': 'application/json'
            }
            body: {
              source: 'servicenow-azure-resource-handler'
              workflow: '@{workflow().name}'
              correlationId: alertCorrelationId
              commonAlertSchema: '@triggerBody()'
              serviceNow: {
                sysId: '@{body(\'Create_ServiceNow_incident\')?[\'result\']?[\'sys_id\']}'
                number: '@{body(\'Create_ServiceNow_incident\')?[\'result\']?[\'number\']}'
                state: '@{body(\'Create_ServiceNow_incident\')?[\'result\']?[\'state\']}'
                url: '@{concat(parameters(\'serviceNowInstanceUrl\'), \'/nav_to.do?uri=incident.do?sys_id=\', body(\'Create_ServiceNow_incident\')?[\'result\']?[\'sys_id\'])}'
              }
            }
          }
        }
        Return_summary: {
          type: 'Response'
          runAfter: {
            Forward_to_SRE_Agent: [
              'Succeeded'
            ]
          }
          inputs: {
            statusCode: 202
            body: {
              status: 'accepted'
              serviceNowIncidentNumber: '@{body(\'Create_ServiceNow_incident\')?[\'result\']?[\'number\']}'
              serviceNowSysId: '@{body(\'Create_ServiceNow_incident\')?[\'result\']?[\'sys_id\']}'
            }
          }
        }
      }
      outputs: {}
    }
  }
}

output logicAppName string = serviceNowWorkflow.name
output logicAppId string = serviceNowWorkflow.id
output logicAppPrincipalId string = serviceNowWorkflow.identity.principalId
#disable-next-line outputs-should-not-contain-secrets
output callbackUrl string = listCallbackUrl('${serviceNowWorkflow.id}/triggers/manual', serviceNowWorkflow.apiVersion).value
