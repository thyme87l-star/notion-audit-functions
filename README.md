# ISS-046 Notion Audit Log -> Microsoft Sentinel (Azure Functions)

Azure Functions (Python 3.11, Timer Trigger) を使用して Notion Audit Log を Microsoft Sentinel に取り込むための展開ファイル一式です。

## ファイル構成

| ファイル | 用途 |
|---|---|
| `ISS-046_deploy.bicep` | インフラ一括デプロイ（Function App + Storage + AI + KV + DCE/DCR + RBAC） |
| `ISS-046_build_and_deploy.py` | zip パッケージ -> Blob アップロード自動化（方法 B 用） |
| `ISS-046_function_app/function_app.py` | Timer Trigger: Notion API -> Logs Ingestion API |
| `ISS-046_function_app/requirements.txt` | Python 依存パッケージ |
| `ISS-046_function_app/host.json` | Functions ランタイム設定 |

## 使い方

展開手順の詳細は ISS-046 Azure Functions 展開ガイドを参照してください。
