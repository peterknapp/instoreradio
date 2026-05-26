#!/usr/bin/env python3
"""
Monthly fallback sync for info-beamer setups.

Workflow:
1) Download latest fallback MP3 from remote producer via SCP.
2) Upload file to info-beamer assets.
3) Find all setups using the configured package.
4) Replace each matching node's "playlist" with exactly that one uploaded file.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional
from urllib.parse import urlencode
from urllib.request import Request, urlopen


API_BASE = "https://info-beamer.com/api/v1"


def _load_env_file(path: Path) -> None:
    if not path.exists():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = value


def _required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise SystemExit(f"Missing required environment variable: {name}")
    return value


def _http_json(
    method: str,
    path: str,
    api_key: str,
    query: Optional[Dict[str, str]] = None,
    form: Optional[Dict[str, str]] = None,
) -> Dict[str, Any]:
    url = f"{API_BASE}{path}"
    if query:
        url = f"{url}?{urlencode(query)}"
    data = None
    headers = {"Authorization": f"Bearer {api_key}"}
    if form is not None:
        data = urlencode(form).encode("utf-8")
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    req = Request(url=url, method=method, headers=headers, data=data)
    with urlopen(req, timeout=60) as resp:
        raw = resp.read().decode("utf-8")
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Invalid JSON response from {path}: {raw[:500]}") from exc


def _run(cmd: List[str]) -> None:
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(
            "Command failed:\n"
            + " ".join(cmd)
            + f"\nSTDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}"
        )


def _scp_download_latest(
    ssh_key: str,
    ssh_user: str,
    ssh_host: str,
    remote_dir: str,
    remote_pattern: str,
    local_dir: Path,
) -> Path:
    remote_glob = f"{ssh_user}@{ssh_host}:{remote_dir.rstrip('/')}/{remote_pattern}"
    _run(["scp", "-i", ssh_key, remote_glob, str(local_dir)])
    matches = list(local_dir.glob("*"))
    if not matches:
        raise RuntimeError(f"No files downloaded from remote pattern: {remote_glob}")
    matches.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    latest = matches[0]
    if latest.stat().st_size <= 0:
        raise RuntimeError(f"Downloaded file is empty: {latest}")
    return latest


def _upload_asset(api_key: str, file_path: Path) -> Dict[str, Any]:
    # Use curl for multipart upload to avoid external Python deps.
    cmd = [
        "curl",
        "-sS",
        "-u",
        f":{api_key}",
        "-F",
        f"file=@{file_path}",
        f"{API_BASE}/asset/upload",
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"asset/upload failed: {proc.stderr.strip()}")
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"asset/upload returned invalid JSON: {proc.stdout[:500]}") from exc
    if not data.get("ok"):
        raise RuntimeError(f"asset/upload returned non-ok response: {data}")
    return data


def _setup_ids_for_package(api_key: str, package_id: str) -> List[int]:
    data = _http_json(
        "GET",
        "/setup/list",
        api_key,
        query={"filter:package_id": package_id},
    )
    setups = data.get("setups", [])
    return [int(s["id"]) for s in setups if "id" in s]


def _find_target_nodes(detail: Dict[str, Any], package_id: int) -> List[str]:
    instances = detail.get("instances", {})
    nodes = detail.get("nodes", {})
    target_instance_ids = set()
    for _, inst in instances.items():
        try:
            if int(inst.get("package", {}).get("id")) == package_id:
                target_instance_ids.add(int(inst.get("id")))
        except Exception:
            continue

    target_keys: List[str] = []
    for node_path, node_info in nodes.items():
        try:
            if int(node_info.get("instance_id")) not in target_instance_ids:
                continue
        except Exception:
            continue
        config_key = node_path.lstrip("/")  # API config uses node path without leading "/"
        if config_key == "":
            config_key = ""
        cfg = detail.get("config", {}).get(config_key, {})
        # Restrict to in-store-radio-like node config.
        if isinstance(cfg, dict) and "playlist" in cfg and "stream" in cfg and "min_fallback" in cfg:
            target_keys.append(config_key)
    return target_keys


def _new_playlist_item(asset_upload: Dict[str, Any], fallback_filename: str) -> Dict[str, Any]:
    asset_id = str(asset_upload["asset_id"])
    info = asset_upload.get("info", {})
    filename = info.get("filename", fallback_filename)
    # This structure matches what config.json in this package expects.
    return {
        "file": {
            "asset_id": asset_id,
            "asset_name": asset_id,
            "filename": filename,
        }
    }


@dataclass
class UpdateResult:
    setup_id: int
    updated: bool
    reason: str


def _update_setup_playlist(
    api_key: str,
    setup_id: int,
    package_id: int,
    playlist_item: Dict[str, Any],
    dry_run: bool,
) -> List[UpdateResult]:
    detail = _http_json("GET", f"/setup/{setup_id}", api_key)
    target_nodes = _find_target_nodes(detail, package_id)
    if not target_nodes:
        return [UpdateResult(setup_id, False, "no matching package node with playlist found")]

    results: List[UpdateResult] = []
    for node_key in target_nodes:
        payload = {node_key: {"playlist": [playlist_item]}}
        if dry_run:
            results.append(UpdateResult(setup_id, True, f"dry-run update node '{node_key}'"))
            continue
        resp = _http_json(
            "POST",
            f"/setup/{setup_id}",
            api_key,
            form={
                "mode": "update",
                "config": json.dumps(payload, separators=(",", ":")),
            },
        )
        if resp.get("ok"):
            results.append(UpdateResult(setup_id, True, f"updated node '{node_key}'"))
        else:
            results.append(UpdateResult(setup_id, False, f"update failed for node '{node_key}': {resp}"))
    return results


def main() -> int:
    parser = argparse.ArgumentParser(description="Sync monthly fallback file to all in-store-radio setups.")
    parser.add_argument(
        "--env-file",
        default=str(Path(__file__).with_name("fallback_sync.env")),
        help="Path to env file (default: tools/fallback_sync.env)",
    )
    parser.add_argument("--dry-run", action="store_true", help="Do not perform setup updates")
    args = parser.parse_args()

    _load_env_file(Path(args.env_file))

    api_key = _required("IB_API_KEY")
    package_id = _required("IB_PACKAGE_ID")
    ssh_key = _required("SRC_SSH_KEY")
    ssh_user = _required("SRC_SSH_USER")
    ssh_host = _required("SRC_SSH_HOST")
    remote_dir = _required("SRC_REMOTE_DIR")
    remote_pattern = _required("SRC_REMOTE_PATTERN")

    with tempfile.TemporaryDirectory(prefix="ib_fallback_sync_") as tmp:
        tmp_dir = Path(tmp)
        local_mp3 = _scp_download_latest(
            ssh_key=ssh_key,
            ssh_user=ssh_user,
            ssh_host=ssh_host,
            remote_dir=remote_dir,
            remote_pattern=remote_pattern,
            local_dir=tmp_dir,
        )
        print(f"[ok] downloaded: {local_mp3.name} ({local_mp3.stat().st_size} bytes)")

        upload = _upload_asset(api_key, local_mp3)
        asset_id = upload["asset_id"]
        print(f"[ok] uploaded asset: id={asset_id}")

        setup_ids = _setup_ids_for_package(api_key, package_id)
        print(f"[ok] setups using package {package_id}: {len(setup_ids)}")
        if not setup_ids:
            print("[done] no setups to update")
            return 0

        playlist_item = _new_playlist_item(upload, local_mp3.name)
        updated = 0
        skipped = 0
        failed = 0
        for sid in setup_ids:
            for result in _update_setup_playlist(
                api_key=api_key,
                setup_id=sid,
                package_id=int(package_id),
                playlist_item=playlist_item,
                dry_run=args.dry_run,
            ):
                if result.updated:
                    updated += 1
                    print(f"[ok] setup {result.setup_id}: {result.reason}")
                else:
                    if "no matching" in result.reason:
                        skipped += 1
                        print(f"[skip] setup {result.setup_id}: {result.reason}")
                    else:
                        failed += 1
                        print(f"[fail] setup {result.setup_id}: {result.reason}")

        print(
            f"[done] nodes updated={updated}, skipped={skipped}, failed={failed}, "
            f"dry_run={'yes' if args.dry_run else 'no'}"
        )
        return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
