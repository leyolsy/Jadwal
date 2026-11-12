#!/usr/bin/env python3
import hashlib
import json
import os
import subprocess
import sys
import urllib.request
import urllib.error

def get_token():
    env_token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if env_token:
        return env_token
    res = subprocess.run(["git", "remote", "get-url", "origin"], capture_output=True, text=True, check=True)
    url = res.stdout.strip()
    # format: https://<token>@github.com/...
    if "@" in url and "://" in url:
        part = url.split("://", 1)[1]
        user_or_token = part.split("@", 1)[0]
        if ":" in user_or_token:
            return user_or_token.split(":", 1)[1]
        return user_or_token
    raise ValueError("Could not extract token from GITHUB_TOKEN env or git remote origin")

def main():
    token = get_token()
    owner = "leyolsy"
    repo = "Jadwal"
    tag = "v2.10.8"
    release_name = "v2.10.8 — Exact Alarms, Resilient Timezones & Robust Notification Delivery"
    release_body = """## What's new in v2.10.8

### ⏰ Exact Alarms & Background Reliability
- **Added `USE_EXACT_ALARM` Permission**: Declared `android.permission.USE_EXACT_ALARM` in `AndroidManifest.xml` to prevent Android Doze mode and aggressive OEM battery savers from deferring daytime class notifications and batch-dumping them at night.
- **Race Condition Prevention**: Notification scheduling is now strictly serialized via a dedicated asynchronous queue (`_scheduleQueue`), ensuring concurrent timetable imports and app-resume events do not cancel or corrupt active alarms.

### 🌐 Resilient Timezone Resolution
- **Native Android Timezone Fallback**: Implemented a platform channel method `getTimeZoneId` in `MainActivity.kt` providing direct access to `java.util.TimeZone.getDefault().id` when standard platform lookup fails.
- **Geographic Timezone Aliasing**: Added canonical geographic timezone mappings (e.g. `Asia/Calcutta` → `Asia/Kolkata`, `US/Eastern` → `America/New_York`) to reliably resolve device timezone identifiers.
- **12-Month DST & Offset Matching**: Timezone offset matching now samples 12 months across the year to properly identify regions with seasonal shifts without defaulting to UTC.

### ⏱️ Flexible Period Time Parsing
- **Extended Time Formats**: Expanded period time parsing to seamlessly accept `h:mm AM/PM`, `h:mmAM/PM` (no space), lowercase `am/pm`, and standard 24-hour formats (`14:00`).
- **Clean Notification Error Feedback**: Gracefully handles malformed timetable entries and invalid period times without generating false system permission warnings.

---

### 📦 Downloads & Architecture

| File | Architecture | Target Devices | Size | SHA256 |
|---|---|---|---|---|
| `jadwal-v2.10.8-67-release.apk` | **arm64-v8a** (64-bit) | Modern Android phones & tablets (recommended) | 24.33 MB | `065c90bc41cd07ae5038fafbf3681755fa043b6ce609e148cb9c7adf95445914` |

> *Note: For older 32-bit devices, download `jadwal-v2.10.7-66-arm32-release.apk` from the [v2.10.7 release assets](https://github.com/leyolsy/Jadwal/releases/tag/v2.10.7).*
"""

    headers = {
        "Authorization": f"token {token}",
        "Accept": "application/vnd.github+json",
        "User-Agent": "Jadwal-Release-Script"
    }

    # 1. Create or get existing release
    print(f"Creating release {tag}...")
    create_url = f"https://api.github.com/repos/{owner}/{repo}/releases"
    payload = json.dumps({
        "tag_name": tag,
        "name": release_name,
        "body": release_body,
        "draft": False,
        "prerelease": False
    }).encode("utf-8")

    req = urllib.request.Request(create_url, data=payload, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            release_id = data["id"]
            upload_url = data["upload_url"].split("{")[0]
            print(f"Created release ID: {release_id}")
    except urllib.error.HTTPError as e:
        if e.code == 422:
            print("Release already exists, fetching existing release...")
            get_req = urllib.request.Request(f"https://api.github.com/repos/{owner}/{repo}/releases/tags/{tag}", headers=headers)
            with urllib.request.urlopen(get_req) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                release_id = data["id"]
                upload_url = data["upload_url"].split("{")[0]
                print(f"Found existing release ID: {release_id}")
        else:
            raise

    # Assets to upload
    assets = [
        ("Apk files/jadwal-v2.10.8-67-release.apk", "jadwal-v2.10.8-67-release.apk"),
    ]

    for local_path, asset_name in assets:
        if not os.path.exists(local_path):
            print(f"Error: {local_path} not found!")
            sys.exit(1)
        file_size = os.path.getsize(local_path)
        print(f"Uploading {asset_name} ({file_size / (1024*1024):.2f} MB)...")
        upload_endpoint = f"https://uploads.github.com/repos/{owner}/{repo}/releases/{release_id}/assets?name={asset_name}"
        
        with open(local_path, "rb") as f:
            file_data = f.read()

        # If asset already exists on this release, verify size and digest before skipping duplicate upload
        existing_assets = data.get("assets", [])
        matched_existing = None
        for ea in existing_assets:
            if ea.get("name") == asset_name:
                matched_existing = ea
                break

        if matched_existing:
            local_sha256 = hashlib.sha256(file_data).hexdigest().lower()
            existing_digest = (matched_existing.get("digest") or "").lower()
            published_body = (data.get("body") or "").lower()

            if existing_digest:
                if not existing_digest.endswith(local_sha256):
                    print(f"Error: Asset {asset_name} digest ({existing_digest}) differs from local SHA-256 ({local_sha256})! Refusing mismatched replacement.")
                    sys.exit(1)
            else:
                download_url = matched_existing.get("browser_download_url")
                if download_url:
                    try:
                        dl_req = urllib.request.Request(download_url, headers={"User-Agent": "Jadwal-Release-Script"})
                        with urllib.request.urlopen(dl_req) as dl_resp:
                            dl_sha256 = hashlib.sha256(dl_resp.read()).hexdigest().lower()
                        if dl_sha256 != local_sha256:
                            print(f"Error: Downloaded asset {asset_name} SHA-256 ({dl_sha256}) differs from local ({local_sha256})! Refusing mismatched replacement.")
                            sys.exit(1)
                    except Exception as dl_err:
                        print(f"Error: Could not verify existing asset {asset_name} without digest: {dl_err}")
                        sys.exit(1)

            if matched_existing.get("size") != file_size:
                print(f"Error: Asset {asset_name} size ({matched_existing.get('size')} bytes) differs from local file ({file_size} bytes)! Refusing mismatched replacement.")
                sys.exit(1)
            elif local_sha256 not in published_body:
                print(f"Error: Local SHA-256 ({local_sha256}) for {asset_name} is not recorded in the published release body! Refusing mismatched replacement.")
                sys.exit(1)
            else:
                print(f"Asset {asset_name} is already attached to release with matching digest and size ({file_size} bytes), skipping duplicate upload.")
                continue

        upload_headers = {
            "Authorization": f"token {token}",
            "Content-Type": "application/vnd.android.package-archive",
            "Content-Length": str(file_size),
            "User-Agent": "Jadwal-Release-Script"
        }

        up_req = urllib.request.Request(upload_endpoint, data=file_data, headers=upload_headers, method="POST")
        with urllib.request.urlopen(up_req) as up_resp:
            up_data = json.loads(up_resp.read().decode("utf-8"))
            print(f"Uploaded {asset_name} successfully -> {up_data.get('browser_download_url')}")

    print("\nAll assets uploaded and release published successfully!")

if __name__ == "__main__":
    main()
