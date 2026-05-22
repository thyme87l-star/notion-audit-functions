// Notion Audit Log Connector — Azure Functions Deployment (Security Hardened)
// =======================================================================================
// セキュリティ設計:
//   - Key Vault Reference による Token 管理
//   - System Assigned MI による全リソースアクセス
//   - Storage SharedKey 無効化 + MI 認証
//   - Key Vault FW: Allow + RBAC 保護 (Consumption Plan 制限)
//   - Function Access Restrictions: AzureCloud のみ許可
//   - Blob パッケージデプロイ対応
//   - RBAC: KV Secrets User / Storage Blob Data Owner / Queue Contributor / Table Contributor / Metrics Publisher
//
// Usage:
//   az deployment group create \
//     --resource-group <RG> \
//     --template-file deploy.bicep \
//     --parameters sentinelWorkspaceResourceId=<workspace-resource-id>

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Base name prefix for resources')
param baseName string = 'notion-audit'

@description('Resource ID of the existing Log Analytics workspace (Sentinel)')
param sentinelWorkspaceResourceId string

@description('Polling interval in minutes')
param pollingIntervalMinutes int = 5

@description('Optional tag value for resource tracking')
param tagValue string = ''

// Common tags
var tags = {
  Purpose: 'Notion Audit Log Sentinel Ingestion'
}

var uniqueSuffix = uniqueString(resourceGroup().id, baseName)
var functionAppName = '${baseName}-func-${uniqueSuffix}'
var storageAccountName = 'st${replace(baseName, '-', '')}${take(uniqueSuffix, 8)}'
var appInsightsName = '${baseName}-ai-${uniqueSuffix}'
var hostingPlanName = '${baseName}-plan-${uniqueSuffix}'
var keyVaultName = 'kv-${baseName}-${take(uniqueSuffix, 6)}'
var dceName = '${baseName}-dce-${uniqueSuffix}'
var dcrName = '${baseName}-dcr-${uniqueSuffix}'
var stateContainerName = 'notion-connector-state'
var deployContainerName = 'function-releases'

// ======================== Storage Account ========================
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
    // セキュリティ設計 #3: SharedKey 無効化（MI 認証のみ許可）
    allowSharedKeyAccess: false
    networkAcls: {
      // Consumption プランでは Storage FW Deny は不可のため Allow を維持
      // SharedKey 無効化で接続文字列による不正アクセスを防止
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
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

resource deployContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: deployContainerName
}

// ======================== Key Vault ========================
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    // セキュリティ設計 #4: Key Vault FW
    // 注意: Consumption Y1 プランでは Key Vault Reference が KV FW Deny を通過できない
    // （MS 公式制約: Consumption plan requires key vault without network restrictions）
    // セキュリティは RBAC (Key Vault Secrets User) で担保する
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
    publicNetworkAccess: 'Enabled'
  }
}

// ======================== Application Insights ========================
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

// ======================== Hosting Plan (Consumption Y1) ========================
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

// ======================== Function App ========================
resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    // セキュリティ設計 #2: System Assigned MI
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: hostingPlan.id
    httpsOnly: true
    siteConfig: {
      pythonVersion: '3.11'
      linuxFxVersion: 'PYTHON|3.11'
      appSettings: [
        // セキュリティ設計 #3: MI ベースの Storage 接続（接続文字列を使用しない）
        { name: 'AzureWebJobsStorage__accountName', value: storageAccount.name }
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'python' }
        { name: 'APPINSIGHTS_INSTRUMENTATIONKEY', value: appInsights.properties.InstrumentationKey }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
        // セキュリティ設計 #1: Key Vault Reference（Token を直接格納しない）
        { name: 'NOTION_TOKEN', value: '@Microsoft.KeyVault(SecretUri=https://${keyVault.name}${environment().suffixes.keyvaultDns}/secrets/NotionIntegrationToken/)' }
        { name: 'NOTION_API_BASE_URL', value: 'https://api.notion.com' }
        { name: 'DCE_ENDPOINT', value: dataCollectionEndpoint.properties.logsIngestion.endpoint }
        { name: 'DCR_IMMUTABLE_ID', value: dataCollectionRule.properties.immutableId }
        { name: 'DCR_STREAM_NAME', value: 'Custom-NotionAuditLog_CL' }
        { name: 'STATE_STORAGE_ACCOUNT_NAME', value: storageAccount.name }
        { name: 'STATE_CONTAINER_NAME', value: stateContainerName }
        { name: 'POLLING_INTERVAL_MINUTES', value: string(pollingIntervalMinutes) }
        { name: 'AzureWebJobsFeatureFlags', value: 'EnableWorkerIndexing' }
      ]
      // セキュリティ設計 #4: Function Access Restrictions
      ipSecurityRestrictions: [
        {
          name: 'AllowAzureCloud'
          priority: 100
          action: 'Allow'
          tag: 'ServiceTag'
          ipAddress: 'AzureCloud'
        }
        {
          name: 'DenyAll'
          priority: 200
          action: 'Deny'
          ipAddress: 'Any'
        }
      ]
      ipSecurityRestrictionsDefaultAction: 'Deny'
      scmIpSecurityRestrictions: [
        {
          name: 'AllowAzureCloud'
          priority: 100
          action: 'Allow'
          tag: 'ServiceTag'
          ipAddress: 'AzureCloud'
        }
        {
          name: 'DenyAll'
          priority: 200
          action: 'Deny'
          ipAddress: 'Any'
        }
      ]
      scmIpSecurityRestrictionsDefaultAction: 'Deny'
    }
  }
}

// ======================== Data Collection Endpoint ========================
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

// ======================== Data Collection Rule ========================
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

// ======================== RBAC Assignments ========================

// Role Definition IDs
var kvSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'       // Key Vault Secrets User
var storageBlobDataOwnerRoleId = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b' // Storage Blob Data Owner
var storageQueueContributorRoleId = '974c5e8b-45b9-4653-ba55-5f855dd0fb88' // Storage Queue Data Contributor
var storageTableContributorRoleId = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3' // Storage Table Data Contributor
var monitoringMetricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb' // Monitoring Metrics Publisher

// #1: Key Vault Secrets User (Function MI → Key Vault)
resource kvSecretsUserRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, functionApp.id, kvSecretsUserRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvSecretsUserRoleId)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// #2: Storage Blob Data Owner (Function MI → Storage)
// Owner が必要: Functions ランタイムが Blob Lease 操作を行うため
resource storageBlobOwnerRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, storageBlobDataOwnerRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataOwnerRoleId)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// #3: Storage Queue Data Contributor (Function MI → Storage)
// Functions ランタイムがキューを使用するため
resource storageQueueRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, storageQueueContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageQueueContributorRoleId)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// #4: Storage Table Data Contributor (Function MI → Storage)
// Functions ランタイムがテーブルを使用するため
resource storageTableRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, storageTableContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageTableContributorRoleId)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// #5: Monitoring Metrics Publisher (Function MI → DCR)
resource dcrRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dataCollectionRule.id, functionApp.id, monitoringMetricsPublisherRoleId)
  scope: dataCollectionRule
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisherRoleId)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ======================== Outputs ========================
output functionAppName string = functionApp.name
output functionAppPrincipalId string = functionApp.identity.principalId
output keyVaultName string = keyVault.name
output storageAccountName string = storageAccount.name
output dceEndpoint string = dataCollectionEndpoint.properties.logsIngestion.endpoint
output dcrImmutableId string = dataCollectionRule.properties.immutableId
output appInsightsName string = appInsights.name
