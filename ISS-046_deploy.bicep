// ISS-046 Notion Audit Log Connector — Azure Functions Deployment
// =================================================================
// Deploys: Function App (Python 3.11) + Storage Account + App Insights
//          + Key Vault + DCE + DCR + Custom Table (NotionAuditLog_CL)
//
// Usage:
//   az deployment group create \
//     --resource-group <RG> \
//     --template-file ISS-046_deploy.bicep \
//     --parameters sentinelWorkspaceResourceId=<workspace-resource-id>

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Base name prefix for resources')
param baseName string = 'notion-audit'

@description('Resource ID of the existing Log Analytics workspace (Sentinel)')
param sentinelWorkspaceResourceId string

@description('Polling interval in minutes')
param pollingIntervalMinutes int = 5

@description('Management ID tag (ISS-046)')
param mgmtId string = 'ISS-046'

// Common tags
var tags = {
  MgmtID: mgmtId
  Project: '課題ベース対応'
  Purpose: 'Notion Audit Log Sentinel Ingestion PoC'
  CreatedBy: 'Orchestrator'
}

var uniqueSuffix = uniqueString(resourceGroup().id, baseName)
var functionAppName = '${baseName}-func-${uniqueSuffix}'
var storageAccountName = 'st${replace(baseName, '-', '')}${take(uniqueSuffix, 8)}'
var appInsightsName = '${baseName}-ai-${uniqueSuffix}'
var keyVaultName = 'kv-${baseName}-${take(uniqueSuffix, 8)}'
var hostingPlanName = '${baseName}-plan-${uniqueSuffix}'
var dceName = '${baseName}-dce-${uniqueSuffix}'
var dcrName = '${baseName}-dcr-${uniqueSuffix}'
var stateContainerName = 'notion-connector-state'

// ---------- Storage Account ----------
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource stateContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: stateContainerName
}

// ---------- Application Insights ----------
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: sentinelWorkspaceResourceId
  }
}

// ---------- Key Vault ----------
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
  }
}

// ---------- Hosting Plan (Consumption) ----------
resource hostingPlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: hostingPlanName
  location: location
  tags: tags
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  properties: {
    reserved: true // Linux
  }
}

// ---------- Function App ----------
resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: hostingPlan.id
    httpsOnly: true
    siteConfig: {
      pythonVersion: '3.11'
      linuxFxVersion: 'PYTHON|3.11'
      appSettings: [
        { name: 'AzureWebJobsStorage', value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storageAccount.listKeys().keys[0].value}' }
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'python' }
        { name: 'APPINSIGHTS_INSTRUMENTATIONKEY', value: appInsights.properties.InstrumentationKey }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
        { name: 'NOTION_API_BASE_URL', value: 'https://api.notion.com' }
        { name: 'KEY_VAULT_URL', value: keyVault.properties.vaultUri }
        { name: 'NOTION_TOKEN_SECRET_NAME', value: 'NotionIntegrationToken' }
        { name: 'DCE_ENDPOINT', value: dataCollectionEndpoint.properties.logsIngestion.endpoint }
        { name: 'DCR_IMMUTABLE_ID', value: dataCollectionRule.properties.immutableId }
        { name: 'DCR_STREAM_NAME', value: 'Custom-NotionAuditLog_CL' }
        { name: 'STATE_STORAGE_ACCOUNT_NAME', value: storageAccount.name }
        { name: 'STATE_CONTAINER_NAME', value: stateContainerName }
        { name: 'POLLING_INTERVAL_MINUTES', value: string(pollingIntervalMinutes) }
        { name: 'AzureWebJobsFeatureFlags', value: 'EnableWorkerIndexing' }
      ]
    }
  }
}

// ---------- Key Vault RBAC: Function App → Key Vault Secrets User ----------
resource kvRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, functionApp.id, '4633458b-17de-408a-b874-0445c86b69e6')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6') // Key Vault Secrets User
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------- Data Collection Endpoint ----------
resource dataCollectionEndpoint 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: dceName
  location: location
  tags: tags
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

// ---------- Data Collection Rule ----------
resource dataCollectionRule 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dcrName
  location: location
  tags: tags
  properties: {
    dataCollectionEndpointId: dataCollectionEndpoint.id
    streamDeclarations: {
      'Custom-NotionAuditLog_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'EventId', type: 'string' }
          { name: 'WorkspaceId_Notion', type: 'string' }
          { name: 'ActorType', type: 'string' }
          { name: 'ActorId', type: 'string' }
          { name: 'ActorName', type: 'string' }
          { name: 'ActorEmail', type: 'string' }
          { name: 'IpAddress', type: 'string' }
          { name: 'Platform', type: 'string' }
          { name: 'EventType', type: 'string' }
          { name: 'EventCategory', type: 'string' }
          { name: 'TargetType', type: 'string' }
          { name: 'TargetId', type: 'string' }
          { name: 'TargetName', type: 'string' }
          { name: 'RawEvent', type: 'string' }
        ]
      }
    }
    dataSources: {}
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: sentinelWorkspaceResourceId
          name: 'sentinel-workspace'
        }
      ]
    }
    dataFlows: [
      {
        streams: ['Custom-NotionAuditLog_CL']
        destinations: ['sentinel-workspace']
        transformKql: 'source'
        outputStream: 'Custom-NotionAuditLog_CL'
      }
    ]
  }
}

// ---------- Storage RBAC: Function App → Storage Blob Data Contributor ----------
resource storageBlobRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe') // Storage Blob Data Contributor
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------- DCR RBAC: Function App → Monitoring Metrics Publisher ----------
resource dcrRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dataCollectionRule.id, functionApp.id, '3913510d-42f4-4e42-8a64-420c390055eb')
  scope: dataCollectionRule
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb') // Monitoring Metrics Publisher
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------- Outputs ----------
output functionAppName string = functionApp.name
output functionAppPrincipalId string = functionApp.identity.principalId
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
output dceEndpoint string = dataCollectionEndpoint.properties.logsIngestion.endpoint
output dcrImmutableId string = dataCollectionRule.properties.immutableId
output storageAccountName string = storageAccount.name
output appInsightsName string = appInsights.name
