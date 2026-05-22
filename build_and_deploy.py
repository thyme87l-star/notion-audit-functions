"""
Blob Package Deploy Script
========================================
SharedKey 無効化環境向けの Function App デプロイスクリプト。
zip パッケージを作成し、MI 認証で Blob にアップロード後、
Function App の WEBSITE_RUN_FROM_PACKAGE を設定する。

Usage:
  python build_and_deploy.py \
    --resource-group <RG> \
    --function-app <FUNC_NAME> \
    --storage-account <STORAGE_ACCOUNT>

Prerequisites:
  - az login 済み（デプロイ実行ユーザーが Storage Blob Data Contributor 以上）
  - Python 3.11
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path


def run_cmd(cmd: list[str], check: bool = True) -> subprocess.CompletedProcess:
    """Run a shell command and return the result."""
    print(f"  > {' '.join(cmd)}")
    # shell=True required on Windows where az is a .cmd file
    result = subprocess.run(
        cmd, capture_output=True, text=True, check=check, shell=True
    )
    if result.returncode != 0 and not check:
        print(f"  [WARN] Exit code {result.returncode}: {result.stderr.strip()}")
    return result


def build_zip(function_app_dir: Path, output_path: Path) -> None:
    """Build the deployment zip package.

    Uses a temp directory to avoid Windows MAX_PATH (260 char) issues
    when the workspace path is deeply nested.
    """
    print("\n[1/4] Building zip package...")

    # Use short temp path to avoid MAX_PATH issues on Windows
    with tempfile.TemporaryDirectory(prefix="func_build_") as tmp:
        tmp_path = Path(tmp)
        pkg_dir = tmp_path / "site-packages"
        pkg_dir.mkdir()

        requirements = function_app_dir / "requirements.txt"
        # Install packages for the target platform (Linux Python 3.11)
        # to ensure binary compatibility with Azure Functions runtime
        run_cmd([
            sys.executable, "-m", "pip", "install",
            "-r", str(requirements),
            "--target", str(pkg_dir),
            "--implementation", "cp",
            "--python-version", "3.11",
            "--platform", "manylinux2014_x86_64",
            "--only-binary=:all:",
            "--upgrade", "-q",
        ])

        # Create zip
        with zipfile.ZipFile(output_path, "w", zipfile.ZIP_DEFLATED) as zf:
            # Add function code files
            for fname in ["function_app.py", "host.json", "requirements.txt"]:
                fpath = function_app_dir / fname
                if fpath.exists():
                    zf.write(fpath, fname)

            # Add installed packages under .python_packages/lib/site-packages/
            # This is the path Azure Functions Python worker expects
            pkg_prefix = ".python_packages/lib/site-packages"
            for root, _dirs, files in os.walk(pkg_dir):
                for fn in files:
                    full_path = Path(root) / fn
                    rel = full_path.relative_to(pkg_dir).as_posix()
                    arc_name = f"{pkg_prefix}/{rel}"
                    zf.write(full_path, arc_name)

    size_mb = output_path.stat().st_size / (1024 * 1024)
    print(f"  Created: {output_path} ({size_mb:.1f} MB)")


def upload_blob(storage_account: str, container: str, blob_name: str, file_path: Path) -> str:
    """Upload zip to Blob Storage using Entra ID auth."""
    print("\n[2/4] Uploading to Blob Storage (--auth-mode login)...")

    # Ensure container exists
    run_cmd([
        "az", "storage", "container", "create",
        "--account-name", storage_account,
        "--name", container,
        "--auth-mode", "login",
    ], check=False)

    # Upload blob
    run_cmd([
        "az", "storage", "blob", "upload",
        "--account-name", storage_account,
        "--container-name", container,
        "--name", blob_name,
        "--file", str(file_path),
        "--auth-mode", "login",
        "--overwrite",
    ])

    blob_url = f"https://{storage_account}.blob.core.windows.net/{container}/{blob_name}"
    print(f"  Uploaded: {blob_url}")
    return blob_url


def configure_function_app(resource_group: str, function_app: str, blob_url: str) -> None:
    """Set WEBSITE_RUN_FROM_PACKAGE to use MI-authenticated Blob."""
    print("\n[3/4] Configuring Function App for Blob package deploy...")

    run_cmd([
        "az", "functionapp", "config", "appsettings", "set",
        "--name", function_app,
        "--resource-group", resource_group,
        "--settings",
        f"WEBSITE_RUN_FROM_PACKAGE={blob_url}",
        "WEBSITE_RUN_FROM_PACKAGE_BLOB_MI_RESOURCE_ID=SystemAssigned",
    ])

    print("  App Settings updated.")


def restart_function_app(resource_group: str, function_app: str) -> None:
    """Restart Function App to apply new package."""
    print("\n[4/4] Restarting Function App...")

    run_cmd([
        "az", "functionapp", "restart",
        "--name", function_app,
        "--resource-group", resource_group,
    ])

    print("  Function App restarted. Deployment complete.")


def main():
    parser = argparse.ArgumentParser(description="Blob Package Deploy for SharedKey-disabled environments")
    parser.add_argument("--resource-group", "-g", required=True, help="Resource group name")
    parser.add_argument("--function-app", "-f", required=True, help="Function App name")
    parser.add_argument("--storage-account", "-s", required=True, help="Storage account name")
    parser.add_argument("--container", default="function-releases", help="Blob container name")
    parser.add_argument("--blob-name", default="release.zip", help="Blob name for the package")
    parser.add_argument(
        "--function-app-dir",
        default=str(Path(__file__).parent / "function_app"),
        help="Path to function_app/ directory",
    )
    args = parser.parse_args()

    function_app_dir = Path(args.function_app_dir)
    if not function_app_dir.exists():
        print(f"ERROR: function_app directory not found: {function_app_dir}")
        sys.exit(1)

    output_zip = function_app_dir / "release.zip"

    print("=" * 60)
    print("Blob Package Deploy (SharedKey-disabled)")
    print("=" * 60)
    print(f"  Resource Group:  {args.resource_group}")
    print(f"  Function App:    {args.function_app}")
    print(f"  Storage Account: {args.storage_account}")
    print(f"  Container:       {args.container}")
    print(f"  Source:          {function_app_dir}")

    # Step 1: Build zip
    build_zip(function_app_dir, output_zip)

    # Step 2: Upload to Blob
    blob_url = upload_blob(args.storage_account, args.container, args.blob_name, output_zip)

    # Step 3: Configure Function App
    configure_function_app(args.resource_group, args.function_app, blob_url)

    # Step 4: Restart
    restart_function_app(args.resource_group, args.function_app)

    # Cleanup local zip
    output_zip.unlink(missing_ok=True)

    print("\n" + "=" * 60)
    print("DONE. Verify with:")
    print(f"  az functionapp show --name {args.function_app} --resource-group {args.resource_group} --query state")
    print("=" * 60)


if __name__ == "__main__":
    main()
