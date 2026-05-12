"""
ISS-046 Notion Audit Log Connector — Azure Functions (Timer Trigger)
=====================================================================
Notion Audit Log API からイベントを定期取得し、Logs Ingestion API 経由で
Log Analytics カスタムテーブル (NotionAuditLog_CL) に送信する。

環境変数:
  NOTION_API_BASE_URL       — Notion API ベース URL（本番: https://api.notion.com、モック: http://localhost:5000）
  NOTION_API_VERSION        — Notion API バージョン（デフォルト: 2022-06-28）
  NOTION_TOKEN_DIRECT       — Notion Integration Token（App Settings に直接格納、推奨）
  KEY_VAULT_URL             — Key Vault URL（後方互換用。未設定時は NOTION_TOKEN_DIRECT を使用）
  NOTION_TOKEN_SECRET_NAME  — Key Vault 内のシークレット名（KEY_VAULT_URL 設定時のみ使用）
  DCE_ENDPOINT              — Data Collection Endpoint URL
  DCR_IMMUTABLE_ID          — Data Collection Rule の Immutable ID
  DCR_STREAM_NAME           — DCR ストリーム名（デフォルト: Custom-NotionAuditLog_CL）
  STATE_STORAGE_ACCOUNT_NAME — Blob Storage アカウント名（ステート管理用、MSI認証）
  STATE_CONTAINER_NAME      — Blob コンテナ名（デフォルト: notion-connector-state）
  POLLING_INTERVAL_MINUTES  — ポーリング間隔（デフォルト: 5）
"""

import os
import json
import time
import logging
from datetime import datetime, timezone

import azure.functions as func
import requests
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient
from azure.monitor.ingestion import LogsIngestionClient
from azure.storage.blob import BlobServiceClient

app = func.FunctionApp()

# --- Configuration ---
NOTION_API_BASE_URL = os.environ.get("NOTION_API_BASE_URL", "https://api.notion.com")
NOTION_API_VERSION = os.environ.get("NOTION_API_VERSION", "2022-06-28")
KEY_VAULT_URL = os.environ.get("KEY_VAULT_URL", "")
NOTION_TOKEN_SECRET_NAME = os.environ.get("NOTION_TOKEN_SECRET_NAME", "NotionIntegrationToken")
DCE_ENDPOINT = os.environ.get("DCE_ENDPOINT", "")
DCR_IMMUTABLE_ID = os.environ.get("DCR_IMMUTABLE_ID", "")
DCR_STREAM_NAME = os.environ.get("DCR_STREAM_NAME", "Custom-NotionAuditLog_CL")
STATE_STORAGE_ACCOUNT_NAME = os.environ.get("STATE_STORAGE_ACCOUNT_NAME", "")
STATE_CONTAINER_NAME = os.environ.get("STATE_CONTAINER_NAME", "notion-connector-state")
STATE_BLOB_NAME = "last_poll_timestamp.json"

RATE_LIMIT_SLEEP = 0.35  # 1/3 sec to stay under 3 req/sec
MAX_RETRIES = 3


class StateManager:
    """Manages last poll timestamp in Azure Blob Storage (MSI auth)."""

    def __init__(self, account_name: str, container_name: str, blob_name: str, credential):
        account_url = f"https://{account_name}.blob.core.windows.net"
        self._blob_client = (
            BlobServiceClient(account_url=account_url, credential=credential)
            .get_blob_client(container=container_name, blob=blob_name)
        )

    def get_last_timestamp(self) -> str | None:
        """Get the last poll timestamp from blob storage."""
        try:
            data = self._blob_client.download_blob().readall()
            state = json.loads(data)
            return state.get("last_timestamp")
        except Exception:
            return None

    def save_last_timestamp(self, timestamp: str) -> None:
        """Save the last poll timestamp to blob storage."""
        state = {
            "last_timestamp": timestamp,
            "updated_at": datetime.now(timezone.utc).isoformat(),
        }
        self._blob_client.upload_blob(
            json.dumps(state), overwrite=True, content_type="application/json"
        )


def _get_notion_token(credential: DefaultAzureCredential) -> str:
    """Retrieve Notion Integration Token.

    優先順位:
      1. NOTION_TOKEN_DIRECT 環境変数（App Settings 直接格納、v4 デフォルト）
      2. KEY_VAULT_URL が設定されている場合は Key Vault から取得（後方互換）
    """
    if not KEY_VAULT_URL:
        token = os.environ.get("NOTION_TOKEN_DIRECT", "")
        if token:
            return token
        raise ValueError("KEY_VAULT_URL is not set and NOTION_TOKEN_DIRECT is empty")

    secret_client = SecretClient(vault_url=KEY_VAULT_URL, credential=credential)
    secret = secret_client.get_secret(NOTION_TOKEN_SECRET_NAME)
    return secret.value


def _fetch_audit_logs(token: str, start_timestamp: str | None = None) -> list[dict]:
    """
    Fetch all audit log events from Notion API with cursor-based pagination.
    Handles rate limiting (429 + Retry-After) and retries.
    """
    all_events: list[dict] = []
    has_more = True
    next_cursor: str | None = None

    headers = {
        "Authorization": f"Bearer {token}",
        "Notion-Version": NOTION_API_VERSION,
        "Content-Type": "application/json",
    }

    while has_more:
        params: dict[str, str] = {"page_size": "100"}
        if next_cursor:
            params["start_cursor"] = next_cursor
        if start_timestamp:
            params["start_date"] = start_timestamp

        url = f"{NOTION_API_BASE_URL}/v1/audit_log"

        for attempt in range(MAX_RETRIES):
            try:
                response = requests.get(url, headers=headers, params=params, timeout=30)

                if response.status_code == 429:
                    retry_after = int(response.headers.get("Retry-After", "2"))
                    logging.warning(
                        f"Rate limited (429). Retry-After: {retry_after}s. Attempt {attempt + 1}/{MAX_RETRIES}"
                    )
                    time.sleep(retry_after)
                    continue

                if response.status_code == 401:
                    raise PermissionError("Notion API returned 401: Invalid token")

                if response.status_code == 403:
                    raise PermissionError(
                        "Notion API returned 403: Audit Log requires Enterprise Plan"
                    )

                response.raise_for_status()
                data = response.json()

                events = data.get("results", [])
                all_events.extend(events)

                has_more = data.get("has_more", False)
                next_cursor = data.get("next_cursor")

                logging.info(
                    f"Fetched {len(events)} events (total: {len(all_events)}, has_more: {has_more})"
                )

                # Rate limit: sleep between requests
                time.sleep(RATE_LIMIT_SLEEP)
                break

            except requests.exceptions.RequestException as e:
                if attempt < MAX_RETRIES - 1:
                    wait = 2 ** (attempt + 1)
                    logging.warning(f"Request error: {e}. Retrying in {wait}s...")
                    time.sleep(wait)
                else:
                    logging.error(f"Max retries reached. Last error: {e}")
                    raise

    return all_events


def _transform_events(events: list[dict]) -> list[dict]:
    """
    Transform Notion audit log events to Log Analytics schema.
    Maps Notion fields to NotionAuditLog_CL columns.
    """
    transformed = []
    for event in events:
        actor = event.get("actor", {})
        person = actor.get("person", {})
        event_info = event.get("event", {})
        target = event.get("target", {})

        record = {
            "TimeGenerated": event.get("timestamp", datetime.now(timezone.utc).isoformat()),
            "EventId": event.get("id", ""),
            "WorkspaceId_Notion": event.get("workspace_id", ""),
            "ActorType": actor.get("type", ""),
            "ActorId": actor.get("id", ""),
            "ActorName": person.get("name", ""),
            "ActorEmail": person.get("email", ""),
            "IpAddress": event.get("ip_address", ""),
            "Platform": event.get("platform", ""),
            "EventType": event_info.get("type", ""),
            "EventCategory": event_info.get("category", ""),
            "TargetType": target.get("type", ""),
            "TargetId": target.get("id", ""),
            "TargetName": target.get("name", ""),
            "RawEvent": json.dumps(event),
        }
        transformed.append(record)

    return transformed


def _send_to_log_analytics(
    credential: DefaultAzureCredential, events: list[dict]
) -> None:
    """Send transformed events to Log Analytics via Logs Ingestion API."""
    if not events:
        logging.info("No events to send.")
        return

    client = LogsIngestionClient(endpoint=DCE_ENDPOINT, credential=credential)
    # SDK handles automatic batching (max 1MB per request), retries, and auth
    client.upload(rule_id=DCR_IMMUTABLE_ID, stream_name=DCR_STREAM_NAME, logs=events)
    logging.info(f"Successfully sent {len(events)} events to Log Analytics.")


@app.timer_trigger(
    schedule=f"0 */{os.environ.get('POLLING_INTERVAL_MINUTES', '5')} * * * *",
    arg_name="timer",
    run_on_startup=False,
)
def notion_audit_log_timer(timer: func.TimerRequest) -> None:
    """Timer trigger: fetch Notion audit logs and send to Sentinel."""
    logging.info("Notion Audit Log connector triggered.")

    if timer.past_due:
        logging.warning("Timer is past due. Running immediately.")

    try:
        credential = DefaultAzureCredential()

        # 1. Get Notion token
        token = _get_notion_token(credential)

        # 2. Get last poll timestamp
        state_manager = None
        last_timestamp = None
        if STATE_STORAGE_ACCOUNT_NAME:
            state_manager = StateManager(
                STATE_STORAGE_ACCOUNT_NAME, STATE_CONTAINER_NAME, STATE_BLOB_NAME,
                credential=credential,
            )
            last_timestamp = state_manager.get_last_timestamp()
            logging.info(f"Last poll timestamp: {last_timestamp or 'None (first run)'}")

        # 3. Fetch audit logs
        events = _fetch_audit_logs(token, start_timestamp=last_timestamp)
        logging.info(f"Fetched {len(events)} events from Notion API.")

        if not events:
            logging.info("No new events. Exiting.")
            return

        # 4. Transform events
        transformed = _transform_events(events)

        # 5. Send to Log Analytics
        _send_to_log_analytics(credential, transformed)

        # 6. Update state
        if state_manager and events:
            newest_timestamp = events[0].get("timestamp", "")
            if newest_timestamp:
                state_manager.save_last_timestamp(newest_timestamp)
                logging.info(f"Updated last poll timestamp to: {newest_timestamp}")

    except PermissionError as e:
        logging.error(f"Authentication/Authorization error: {e}")
        raise
    except Exception as e:
        logging.error(f"Unexpected error: {e}")
        raise
