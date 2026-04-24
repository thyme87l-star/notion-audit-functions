"""
ISS-046 Build and Deploy Script
Builds the Azure Functions deployment zip with correct structure for Linux Consumption.
Packages dependencies flat at the root level (alongside function_app.py).
Uses Python zipfile to ensure forward slashes in zip entries.
"""
import os
import sys
import shutil
import subprocess
import zipfile
import tempfile

FUNC_DIR = os.path.dirname(os.path.abspath(__file__))
FUNC_APP_DIR = os.path.join(FUNC_DIR, "ISS-046_function_app")
BUILD_DIR = os.path.join(tempfile.gettempdir(), "iss046_func_build_v3")
ZIP_PATH = os.path.join(tempfile.gettempdir(), "iss046_release_v3.zip")

STORAGE_ACCOUNT = "stnotionauditdrj4uph6"
CONTAINER = "function-releases"
BLOB_NAME = "release.zip"
FUNC_NAME = "notion-audit-func-drj4uph6hbohg"
RG = "ISS-046-Functions-RG"


def step_1_prepare_build():
    """Clean and prepare build directory with function files."""
    print("=== Step 1: Prepare build directory ===")
    if os.path.exists(BUILD_DIR):
        shutil.rmtree(BUILD_DIR)
    os.makedirs(BUILD_DIR)

    for f in ["function_app.py", "host.json", "requirements.txt"]:
        src = os.path.join(FUNC_APP_DIR, f)
        dst = os.path.join(BUILD_DIR, f)
        shutil.copy2(src, dst)
        print(f"  Copied {f}")

    print(f"  Build dir: {BUILD_DIR}")


def step_2_install_deps():
    """Install dependencies flat at the root level."""
    print("\n=== Step 2: Install dependencies (flat at root) ===")
    req_file = os.path.join(BUILD_DIR, "requirements.txt")

    with open(req_file) as f:
        print(f"  Requirements:\n{f.read()}")

    # Install for Linux x86_64 Python 3.11
    cmd = [
        sys.executable, "-m", "pip", "install",
        "--target", BUILD_DIR,
        "--platform", "manylinux2014_x86_64",
        "--python-version", "3.11",
        "--only-binary=:all:",
        "-r", req_file,
        "--no-cache-dir",
        "--quiet"
    ]
    print(f"  Running: {' '.join(cmd)}")
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"  WARNING: pip returned {result.returncode}")
        print(f"  stderr: {result.stderr}")
        # Try without platform constraints for pure-python packages
        print("  Retrying without platform constraints...")
        cmd2 = [
            sys.executable, "-m", "pip", "install",
            "--target", BUILD_DIR,
            "-r", req_file,
            "--no-cache-dir",
            "--quiet"
        ]
        result2 = subprocess.run(cmd2, capture_output=True, text=True)
        if result2.returncode != 0:
            print(f"  ERROR: pip failed: {result2.stderr}")
            return False
    
    # Verify critical packages exist
    critical = ["requests", "azure", "certifi", "urllib3", "charset_normalizer"]
    for pkg in critical:
        pkg_path = os.path.join(BUILD_DIR, pkg)
        if os.path.isdir(pkg_path):
            print(f"  OK: {pkg}/ exists")
        else:
            print(f"  MISSING: {pkg}/")
    
    return True


def step_3_create_zip():
    """Create zip with forward slashes (Linux-compatible)."""
    print(f"\n=== Step 3: Create zip with forward slashes ===")
    if os.path.exists(ZIP_PATH):
        os.remove(ZIP_PATH)

    file_count = 0
    with zipfile.ZipFile(ZIP_PATH, 'w', zipfile.ZIP_DEFLATED) as zf:
        for root, dirs, files in os.walk(BUILD_DIR):
            # Skip __pycache__ and .dist-info directories
            dirs[:] = [d for d in dirs if d != '__pycache__' and not d.endswith('.dist-info')]
            for file in files:
                if file.endswith('.pyc'):
                    continue
                full_path = os.path.join(root, file)
                # Use forward slashes for zip entry name
                arc_name = os.path.relpath(full_path, BUILD_DIR).replace('\\', '/')
                zf.write(full_path, arc_name)
                file_count += 1

    size_mb = os.path.getsize(ZIP_PATH) / (1024 * 1024)
    print(f"  Zip created: {ZIP_PATH}")
    print(f"  Size: {size_mb:.2f} MB")
    print(f"  Files: {file_count}")

    # Verify key entries
    with zipfile.ZipFile(ZIP_PATH, 'r') as zf:
        entries = zf.namelist()
        checks = [
            "function_app.py",
            "host.json",
            "requests/__init__.py",
            "azure/__init__.py",
            "azure/functions/__init__.py",
            "azure/identity/__init__.py",
        ]
        print("\n  Key entries check:")
        for check in checks:
            found = check in entries
            print(f"    {'OK' if found else 'MISSING'}: {check}")
        
        # Show first 20 root-level entries
        root_entries = sorted(set(e.split('/')[0] for e in entries))
        print(f"\n  Root-level items ({len(root_entries)}):")
        for e in root_entries[:25]:
            print(f"    {e}")


def step_4_upload():
    """Upload zip to blob storage."""
    print(f"\n=== Step 4: Upload to blob storage ===")
    env = os.environ.copy()
    env["AZURE_CONFIG_DIR"] = os.path.join(os.environ["USERPROFILE"], ".azure-iceteanow")
    
    cmd = [
        "az", "storage", "blob", "upload",
        "--account-name", STORAGE_ACCOUNT,
        "--container-name", CONTAINER,
        "--name", BLOB_NAME,
        "--file", ZIP_PATH,
        "--overwrite",
        "--auth-mode", "login",
        "-o", "none"
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, env=env, shell=True)
    if result.returncode != 0:
        print(f"  ERROR: {result.stderr}")
        return False
    print("  Upload complete.")
    return True


def step_5_restart():
    """Restart Function App."""
    print(f"\n=== Step 5: Restart Function App ===")
    env = os.environ.copy()
    env["AZURE_CONFIG_DIR"] = os.path.join(os.environ["USERPROFILE"], ".azure-iceteanow")
    
    cmd = [
        "az", "functionapp", "restart",
        "--name", FUNC_NAME,
        "--resource-group", RG,
        "-o", "none"
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, env=env, shell=True)
    if result.returncode != 0:
        print(f"  ERROR: {result.stderr}")
        return False
    print("  Restart complete.")
    return True


if __name__ == "__main__":
    step_1_prepare_build()
    if not step_2_install_deps():
        sys.exit(1)
    step_3_create_zip()
    step_4_upload()
    step_5_restart()
    print("\n=== DONE. Wait 30s then check function discovery. ===")
