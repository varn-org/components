#!/usr/bin/env python3
"""Fetch a varn release and run the component tests against it."""

from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import time
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CACHE = ROOT / ".varn"

# tests that need nothing beyond the varn binary
LOCAL_TESTS = (
    "ai/tests/mock_test.lua",
    "ai/tests/adapters_test.lua",
    "env/tests/integration.lua",
    "pool/tests/integration.lua",
    "retry/tests/integration.lua",
    "test/tests/integration.lua",
    "validate/tests/integration.lua",
    "vdo/tests/dsn_test.lua",
    "vdo/tests/sql_test.lua",
)

# tests that need the docker backends from tests/docker-compose.yml
BACKEND_TESTS = (
    "redis/tests/integration.lua",
    "scheduler/tests/scheduler_test.lua",
    "vdo/tests/integration.lua",
)

# the real-api ai smoke, opt-in because each provider needs its own key
LIVE_TEST = "ai/tests/live_test.lua"

COMPOSE = ["docker", "compose", "-f", "tests/docker-compose.yml"]
BACKEND_SERVICES = ("redis", "mysql", "postgres")
BACKEND_ENV = {
    "VARN_REDIS_HOST": "127.0.0.1",
    "VARN_REDIS_PORT": "6379",
    "VARN_MYSQL_HOST": "127.0.0.1",
    "VARN_MYSQL_PORT": "3306",
    "VARN_MYSQL_USER": "root",
    "VARN_MYSQL_PASS": "varnpass",
    "VARN_MYSQL_DB": "varntest",
    "VDO_MYSQL_DSN": "mysql:host=127.0.0.1;port=3306;dbname=varntest",
    "VDO_MYSQL_USER": "root",
    "VDO_MYSQL_PASS": "varnpass",
    "VDO_PGSQL_DSN": "pgsql:host=127.0.0.1;port=5432;dbname=varntest",
    "VDO_PGSQL_USER": "varn",
    "VDO_PGSQL_PASS": "varnpass",
}


def asset_name() -> str:
    system = platform.system()
    machine = platform.machine().lower()

    if system == "Linux":
        return "varn-linux-x86_64.tar.gz"
    if system == "Darwin":
        return "varn-macos-arm64.tar.gz" if machine in ("arm64", "aarch64") else "varn-macos-x86_64.tar.gz"
    if system == "Windows":
        return "varn-windows-x86_64.zip"

    raise SystemExit(f"no varn release asset for {system}/{machine}")


def download(version: str) -> Path:
    """Return the varn binary for `version`, downloading the release asset once."""
    binary = CACHE / version / ("varn.exe" if platform.system() == "Windows" else "varn")
    if binary.exists():
        return binary

    name = asset_name()
    tag = "latest/download" if version == "latest" else f"download/{version}"
    url = f"https://github.com/varn-org/varn/releases/{tag}/{name}"

    target = CACHE / version
    target.mkdir(parents=True, exist_ok=True)
    archive = target / name

    print(f"> fetching {url}")
    try:
        urllib.request.urlretrieve(url, archive)
    except Exception as error:
        raise SystemExit(f"could not download {url}: {error}")

    if name.endswith(".zip"):
        with zipfile.ZipFile(archive) as zf:
            zf.extractall(target)
    else:
        with tarfile.open(archive) as tf:
            tf.extractall(target)

    # the archive carries a single directory holding the binary next to the license
    found = next((p for p in target.rglob("varn") if p.is_file()), None) or next(
        (p for p in target.rglob("varn.exe") if p.is_file()), None
    )
    if found is None:
        raise SystemExit(f"{name} did not contain a varn binary")

    shutil.move(str(found), str(binary))
    binary.chmod(0o755)
    archive.unlink()
    return binary


def run_suite(binary: Path, tests: tuple[str, ...], extra_env: dict[str, str] | None = None) -> list[str]:
    scratch = ROOT / ".scratch"
    passed = 0
    failed: list[str] = []

    for relative in tests:
        path = ROOT / relative
        if not path.exists():
            print(f"test not found: {relative}")
            raise SystemExit(1)

        if scratch.exists():
            shutil.rmtree(scratch)
        scratch.mkdir(parents=True)

        env = {**os.environ, "VARN_TEST_DIR": str(scratch), **(extra_env or {})}
        result = subprocess.run([str(binary), str(path)], cwd=str(ROOT), capture_output=True, text=True, env=env)

        if result.returncode == 0:
            print(f"PASS  {relative}")
            passed += 1
            continue

        print(f"FAIL  {relative}  [exit {result.returncode}]")
        for line in (result.stdout + result.stderr).strip().splitlines()[-40:]:
            print(f"      {line}")
        failed.append(relative)

    if scratch.exists():
        shutil.rmtree(scratch)

    print(f"\n{passed} passed, {len(failed)} failed")
    return failed


def backend_health() -> dict[str, str]:
    """Health per service, asked of compose itself so no container name is assumed here."""
    probe = subprocess.run(COMPOSE + ["ps", "--format", "json"], cwd=str(ROOT), capture_output=True, text=True)
    text = probe.stdout.strip()
    if not text:
        return {}

    # compose emits either one object per line or a single array, depending on its version
    try:
        rows = json.loads(text)
        if isinstance(rows, dict):
            rows = [rows]
    except json.JSONDecodeError:
        rows = [json.loads(line) for line in text.splitlines() if line.strip()]

    return {row.get("Service", "?"): (row.get("Health") or row.get("State") or "?") for row in rows}


def wait_for_backends(attempts: int = 60) -> bool:
    health: dict[str, str] = {}
    for _ in range(attempts):
        health = backend_health()
        if all(health.get(service) == "healthy" for service in BACKEND_SERVICES):
            return True
        time.sleep(2)

    # say which service is holding things up rather than only that the wait ran out
    print("backends never became healthy:")
    for service in BACKEND_SERVICES:
        print(f"  {service}: {health.get(service, 'not running')}")
    return False


def main() -> None:
    # ci captures a pipe rather than a tty, and block buffering would print these lines out of order against a subprocess failure
    sys.stdout.reconfigure(line_buffering=True)

    parser = argparse.ArgumentParser(description="run the component tests against a varn release")
    parser.add_argument("--varn-version", default=os.environ.get("VARN_VERSION", "v1.0.0"),
                        help="release tag to test against, or 'latest' (default: v1.0.0)")
    parser.add_argument("--backends", action="store_true", help="also run the tests that need redis, mysql and postgres")
    parser.add_argument("--ai-live", action="store_true", help="also run the real-api ai smoke test")
    parser.add_argument("--down", action="store_true", help="stop the docker backends and exit")
    args = parser.parse_args()

    if args.down:
        subprocess.run(COMPOSE + ["down", "-v"], cwd=str(ROOT))
        return

    binary = download(args.varn_version)
    print(f"> varn {args.varn_version} at {binary}\n")

    failed = run_suite(binary, LOCAL_TESTS)

    if args.backends or args.ai_live:
        print("\n> starting the docker backends")
        subprocess.run(COMPOSE + ["up", "-d"], cwd=str(ROOT), check=True)
        if not wait_for_backends():
            subprocess.run(COMPOSE + ["down", "-v"], cwd=str(ROOT))
            raise SystemExit("the docker backends did not become healthy")

        suite = BACKEND_TESTS + ((LIVE_TEST,) if args.ai_live else ())
        failed += run_suite(binary, suite, BACKEND_ENV)
        subprocess.run(COMPOSE + ["down", "-v"], cwd=str(ROOT))

    if failed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
