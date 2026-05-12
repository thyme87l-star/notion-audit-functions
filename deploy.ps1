<#
.SYNOPSIS
    ISS-046 Notion Audit Log → Sentinel: Azure Functions 自動展開スクリプト (v4)

.DESCRIPTION
    params.json に記入されたパラメータを読み取り、以下を自動実行します:
      Step 0: Azure CLI ログイン・権限確認
      Step 1: リソースグループの作成
      Step 2: Bicep でインフラを一括デプロイ（Notion Token は App Settings に直接格納）
      Step 3: Function App コードのデプロイ（方法 A or B を自動選択）
      Step 4: 動作確認（手動トリガー + KQL データ到達チェック）

.PARAMETER ParamsFile
    パラメータファイルのパス（デフォルト: 同フォルダの params.json）

.PARAMETER SkipLogin
    Azure CLI ログイン済みの場合はこのスイッチを指定

.EXAMPLE
    .\deploy.ps1
    .\deploy.ps1 -ParamsFile .\my-params.json
    .\deploy.ps1 -SkipLogin
#>

[CmdletBinding()]
param(
    [string]$ParamsFile = "$PSScriptRoot\params.json",
    [switch]$SkipLogin
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ============================================================
# ユーティリティ関数
# ============================================================
function Write-Step {
    param([string]$StepNum, [string]$Title)
    Write-Host ""
    Write-Host "=" * 60 -ForegroundColor Cyan
    Write-Host "  Step ${StepNum}: $Title" -ForegroundColor Cyan
    Write-Host "=" * 60 -ForegroundColor Cyan
}

function Write-Check {
    param([string]$Message)
    Write-Host "  [CHECK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  [WARN]  $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "  [FAIL]  $Message" -ForegroundColor Red
}

function Confirm-Continue {
    param([string]$Message)
    $response = Read-Host "$Message (y/N)"
    if ($response -ne 'y' -and $response -ne 'Y') {
        Write-Host "中断しました。" -ForegroundColor Yellow
        exit 0
    }
}

# ============================================================
# パラメータ読み込みとバリデーション
# ============================================================
Write-Host ""
Write-Host "ISS-046 Notion Audit Log -> Sentinel: Azure Functions 展開スクリプト" -ForegroundColor White -BackgroundColor DarkBlue
Write-Host ""

if (-not (Test-Path $ParamsFile)) {
    Write-Fail "パラメータファイルが見つかりません: $ParamsFile"
    Write-Host "  params.json を編集してから再実行してください。"
    exit 1
}

Write-Host "パラメータファイル: $ParamsFile" -ForegroundColor Gray
$config = Get-Content $ParamsFile -Raw | ConvertFrom-Json

# 必須パラメータの検証
$errors = @()
if ([string]::IsNullOrWhiteSpace($config.azure.subscriptionId)) {
    $errors += "azure.subscriptionId が未設定です"
}
if ([string]::IsNullOrWhiteSpace($config.sentinel.workspaceResourceId) -or
    $config.sentinel.workspaceResourceId -match '<SUB_ID>') {
    $errors += "sentinel.workspaceResourceId が未設定またはプレースホルダのままです"
}
if ([string]::IsNullOrWhiteSpace($config.notion.integrationToken)) {
    $errors += "notion.integrationToken が未設定です"
}

if ($errors.Count -gt 0) {
    Write-Fail "パラメータエラー:"
    $errors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Write-Host ""
    Write-Host "params.json を編集してから再実行してください。"
    exit 1
}

# パラメータの展開
$subscriptionId     = $config.azure.subscriptionId
$rgName             = $config.azure.resourceGroupName
$location           = $config.azure.location
$workspaceResId     = $config.sentinel.workspaceResourceId
$notionToken        = $config.notion.integrationToken
$baseName           = $config.options.baseName
$pollingInterval    = $config.options.pollingIntervalMinutes
$deployMethod       = $config.options.deployMethod

Write-Host ""
Write-Host "--- 展開パラメータ確認 ---" -ForegroundColor White
Write-Host "  サブスクリプション ID : $subscriptionId"
Write-Host "  リソースグループ     : $rgName"
Write-Host "  リージョン           : $location"
Write-Host "  Sentinel WS          : $workspaceResId"
Write-Host "  Notion Token         : $('*' * 8)...(非表示)"
Write-Host "  ベース名             : $baseName"
Write-Host "  ポーリング間隔       : ${pollingInterval} 分"
Write-Host "  デプロイ方法         : $deployMethod $(if ($deployMethod -eq 'A') {'(func publish)'} else {'(Blob パッケージ)'})"
Write-Host ""
Confirm-Continue "上記の内容で展開を開始しますか？"

# ============================================================
# Step 0: Azure CLI ログイン・権限確認
# ============================================================
if (-not $SkipLogin) {
    Write-Step "0" "Azure CLI ログイン・権限確認"

    # Azure CLI バージョン確認
    try {
        $azVersion = az version --query '\"azure-cli\"' -o tsv 2>$null
        Write-Check "Azure CLI バージョン: $azVersion"
    } catch {
        Write-Fail "Azure CLI がインストールされていません。"
        Write-Host "  インストール: https://learn.microsoft.com/ja-jp/cli/azure/install-azure-cli"
        exit 1
    }

    # Python バージョン確認
    try {
        $pyVersion = python --version 2>&1
        Write-Check "Python: $pyVersion"
    } catch {
        Write-Warn "Python が見つかりません。コードデプロイ時に必要です。"
    }

    # 方法 A の場合、func CLI を確認
    if ($deployMethod -eq 'A') {
        try {
            $funcVersion = func --version 2>$null
            Write-Check "Azure Functions Core Tools: $funcVersion"
        } catch {
            Write-Warn "func CLI が見つかりません。方法 B に切り替えるか、Core Tools をインストールしてください。"
            Write-Host "  https://learn.microsoft.com/ja-jp/azure/azure-functions/functions-run-local"
        }
    }

    Write-Host "  Azure にログインします..."
    az login 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Azure CLI ログインに失敗しました"
        exit 1
    }
    Write-Check "ログイン成功"

    # サブスクリプション設定
    az account set --subscription $subscriptionId 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "サブスクリプション $subscriptionId の設定に失敗しました"
        exit 1
    }
    $accountName = az account show --query name -o tsv
    Write-Check "サブスクリプション: $accountName ($subscriptionId)"

    # 権限確認
    $userId = az ad signed-in-user show --query id -o tsv 2>$null
    if ($userId) {
        $roles = az role assignment list `
            --assignee $userId `
            --scope "/subscriptions/$subscriptionId" `
            --query "[].roleDefinitionName" -o tsv 2>$null
        if ($roles) {
            Write-Check "RBAC ロール: $($roles -join ', ')"
            if ($roles -notmatch 'Owner' -and ($roles -notmatch 'Contributor' -or $roles -notmatch 'User Access Administrator')) {
                Write-Warn "Contributor + User Access Administrator (または Owner) が必要です"
            }
        }
    }
} else {
    Write-Host "  Azure CLI ログインをスキップしました (-SkipLogin)" -ForegroundColor Gray
}

# ============================================================
# Step 1: リソースグループの作成
# ============================================================
Write-Step "1" "リソースグループの作成"

$rgExists = az group exists --name $rgName 2>$null
if ($rgExists -eq 'true') {
    Write-Warn "リソースグループ '$rgName' は既に存在します。既存のリソースグループを使用します。"
} else {
    Write-Host "  リソースグループ '$rgName' を '$location' に作成します..."
    az group create --name $rgName --location $location -o none 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "リソースグループの作成に失敗しました"
        exit 1
    }
}

$rgState = az group show --name $rgName --query properties.provisioningState -o tsv
Write-Check "リソースグループ: $rgName ($location) — $rgState"

# ============================================================
# Step 2: Bicep でインフラを一括デプロイ
# ============================================================
Write-Step "2" "Bicep でインフラを一括デプロイ"

$bicepFile = "$PSScriptRoot\ISS-046_deploy.bicep"
if (-not (Test-Path $bicepFile)) {
    Write-Fail "Bicep ファイルが見つかりません: $bicepFile"
    exit 1
}

Write-Host "  Bicep テンプレートをデプロイ中..."
Write-Host "  （数分かかる場合があります）" -ForegroundColor Gray

$deployOutput = az deployment group create `
    --resource-group $rgName `
    --template-file $bicepFile `
    --parameters `
        sentinelWorkspaceResourceId=$workspaceResId `
        baseName=$baseName `
        pollingIntervalMinutes=$pollingInterval `
        notionToken=$notionToken `
    --query properties.outputs -o json 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Fail "Bicep デプロイに失敗しました"
    Write-Host $deployOutput
    exit 1
}

$outputs = $deployOutput | ConvertFrom-Json
$functionAppName    = $outputs.functionAppName.value
$storageAccountName = $outputs.storageAccountName.value
$dceEndpoint        = $outputs.dceEndpoint.value
$dcrImmutableId     = $outputs.dcrImmutableId.value

Write-Check "デプロイ完了"
Write-Host "  Function App  : $functionAppName"
Write-Host "  Storage       : $storageAccountName"
Write-Host "  DCE Endpoint  : $dceEndpoint"
Write-Host "  DCR ID        : $dcrImmutableId"
Write-Host ""
Write-Host "  ※ Notion Token は App Settings (NOTION_TOKEN_DIRECT) に直接格納されました" -ForegroundColor Gray

# ============================================================
# Step 3: Function App コードのデプロイ
# ============================================================
Write-Step "3" "Function App コードのデプロイ（方法 $deployMethod）"

$funcAppDir = "$PSScriptRoot\ISS-046_function_app"
if (-not (Test-Path $funcAppDir)) {
    Write-Fail "Function App ディレクトリが見つかりません: $funcAppDir"
    exit 1
}

# allowSharedKeyAccess 事前チェック
$sharedKey = az storage account show `
    --name $storageAccountName --resource-group $rgName `
    --query allowSharedKeyAccess -o tsv 2>$null
if ($sharedKey -eq 'false' -and $deployMethod -eq 'A') {
    Write-Warn "allowSharedKeyAccess: false が検出されました。方法 B (Blob パッケージ) に自動切り替えします。"
    $deployMethod = 'B'
}

if ($deployMethod -eq 'A') {
    # --- 方法 A: func publish (remote build) ---
    Write-Host "  方法 A: Azure Functions Core Tools でデプロイします..."

    Push-Location $funcAppDir
    try {
        # func publish は remote build で依存パッケージを自動インストールするため
        # ローカルでの pip install は不要
        Write-Host "  func publish (--build remote) を実行中..."
        func azure functionapp publish $functionAppName --build remote 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "func publish が失敗しました。allowSharedKeyAccess:false ポリシーの可能性があります。"
            Write-Host "  方法 B に切り替えますか？" -ForegroundColor Yellow
            $switchToB = Read-Host "  方法 B で再試行する (y/N)"
            if ($switchToB -eq 'y' -or $switchToB -eq 'Y') {
                $deployMethod = 'B'
            } else {
                Write-Fail "デプロイを中断します"
                exit 1
            }
        } else {
            Write-Check "func publish 完了"
        }
    } finally {
        Pop-Location
    }
}

if ($deployMethod -eq 'B') {
    # --- 方法 B: Blob パッケージデプロイ ---
    Write-Host "  方法 B: Blob パッケージデプロイで実行します..."

    Push-Location $funcAppDir
    try {
        # zip パッケージ作成（Linux x86_64 向けにクロスビルド）
        Write-Host "  zip パッケージを作成中（Linux x86_64 向け）..."
        python -c @"
import zipfile, subprocess, os, sys, shutil, tempfile
build_dir = os.path.join(tempfile.gettempdir(), 'iss046_deploy_build')
if os.path.exists(build_dir):
    shutil.rmtree(build_dir)
os.makedirs(build_dir)
for f in ['function_app.py', 'host.json', 'requirements.txt']:
    shutil.copy2(f, os.path.join(build_dir, f))
req = os.path.join(build_dir, 'requirements.txt')
print('  Installing dependencies for Linux x86_64...')
r = subprocess.run([sys.executable, '-m', 'pip', 'install',
    '--target', build_dir, '--platform', 'manylinux2014_x86_64',
    '--python-version', '3.11', '--only-binary=:all:',
    '-r', req, '--no-cache-dir', '-q'], capture_output=True, text=True)
if r.returncode != 0:
    print(f'  Platform-specific install note: {r.stderr.strip()}')
    print('  Retrying without platform constraints (pure-python fallback)...')
    subprocess.run([sys.executable, '-m', 'pip', 'install',
        '--target', build_dir, '-r', req, '--no-cache-dir', '-q'], check=True)
file_count = 0
with zipfile.ZipFile('release.zip', 'w', zipfile.ZIP_DEFLATED) as zf:
    for root, dirs, files in os.walk(build_dir):
        dirs[:] = [d for d in dirs if d != '__pycache__' and not d.endswith('.dist-info')]
        for fn in files:
            if fn.endswith('.pyc'):
                continue
            full = os.path.join(root, fn)
            arc = os.path.relpath(full, build_dir).replace('\\', '/')
            zf.write(full, arc)
            file_count += 1
size_mb = os.path.getsize('release.zip') / (1024*1024)
print(f'  Created release.zip ({size_mb:.1f} MB, {file_count} files)')
"@ 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-Fail "zip パッケージの作成に失敗しました"
            exit 1
        }

        # Blob コンテナ作成 & アップロード
        Write-Host "  Blob にアップロード中..."
        az storage container create `
            --account-name $storageAccountName `
            --name function-releases `
            --auth-mode login -o none 2>&1

        az storage blob upload `
            --account-name $storageAccountName `
            --container-name function-releases `
            --name release.zip --file release.zip `
            --auth-mode login --overwrite -o none 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-Fail "Blob アップロードに失敗しました"
            exit 1
        }

        # App Settings 更新
        $blobUrl = "https://$storageAccountName.blob.core.windows.net/function-releases/release.zip"
        az functionapp config appsettings set `
            --name $functionAppName `
            --resource-group $rgName `
            --settings "WEBSITE_RUN_FROM_PACKAGE=$blobUrl" `
                "WEBSITE_RUN_FROM_PACKAGE_BLOB_MI_RESOURCE_ID=SystemAssigned" `
            -o none 2>&1

        # 再起動
        az functionapp restart --name $functionAppName --resource-group $rgName -o none 2>&1
        Write-Check "Blob パッケージデプロイ完了"

        # release.zip を削除
        Remove-Item release.zip -ErrorAction SilentlyContinue
    } finally {
        Pop-Location
    }
}

# 関数の確認
Start-Sleep -Seconds 10
$funcList = az functionapp function list `
    --name $functionAppName `
    --resource-group $rgName `
    --query "[].name" -o tsv 2>$null

if ($funcList) {
    Write-Check "認識された関数: $funcList"
} else {
    Write-Warn "関数がまだ認識されていません。数分後に再確認してください。"
}

# ============================================================
# Step 4: 動作確認
# ============================================================
Write-Step "4" "動作確認（手動トリガー）"

Write-Host "  手動トリガーを実行します..."

$masterKey = az functionapp keys list `
    --name $functionAppName `
    --resource-group $rgName `
    --query masterKey -o tsv 2>$null

if ($masterKey) {
    try {
        $triggerUri = "https://$functionAppName.azurewebsites.net/admin/functions/notion_audit_log_timer"
        $response = Invoke-WebRequest `
            -Uri $triggerUri `
            -Method Post `
            -Headers @{ "x-functions-key" = $masterKey; "Content-Type" = "application/json" } `
            -Body '{}' `
            -UseBasicParsing

        if ($response.StatusCode -eq 202) {
            Write-Check "手動トリガー成功 (HTTP 202)"
        } else {
            Write-Warn "手動トリガー応答: HTTP $($response.StatusCode)"
        }
    } catch {
        Write-Warn "手動トリガーに失敗しました: $($_.Exception.Message)"
        Write-Host "  Function App が起動中の場合、数分後に再試行してください。"
    }
} else {
    Write-Warn "マスターキーを取得できませんでした。Azure Portal から手動トリガーしてください。"
}

# ============================================================
# 完了サマリー
# ============================================================
Write-Host ""
Write-Host "=" * 60 -ForegroundColor Green
Write-Host "  展開完了" -ForegroundColor Green
Write-Host "=" * 60 -ForegroundColor Green
Write-Host ""
Write-Host "  リソースグループ  : $rgName"
Write-Host "  Function App      : $functionAppName"
Write-Host "  Storage Account   : $storageAccountName"
Write-Host "  DCE Endpoint      : $dceEndpoint"
Write-Host "  DCR Immutable ID  : $dcrImmutableId"
Write-Host "  デプロイ方法      : $deployMethod"
Write-Host "  Token 格納方式     : App Settings (NOTION_TOKEN_DIRECT)"
Write-Host ""
Write-Host "  データ確認 (KQL):" -ForegroundColor White
Write-Host "    Defender ポータル → Advanced Hunting で以下を実行:"
Write-Host "    NotionAuditLog_CL | where TimeGenerated > ago(1h) | count"
Write-Host ""
Write-Host "  注意: DCE → テーブルへのインジェストには最大 5〜10 分の遅延があります。" -ForegroundColor Yellow
