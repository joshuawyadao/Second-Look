#!/usr/bin/env python3
"""Actual localhost Auth/Postgres/Swift HTTP tests, using generated synthetic accounts only."""
from __future__ import annotations
import argparse
import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]
CLI = ["npx", "--yes", "supabase@2.119.0"]
PROJECT = "secondlook-m2-local"
NETWORK = "secondlook_m2_local"
EXCLUDED = "realtime,storage-api,imgproxy,mailpit,postgres-meta,studio,edge-runtime,logflare,vector,supavisor"


def run(command, **kwargs):
    return subprocess.run(command, cwd=ROOT, check=True, **kwargs)


def request(url, payload=None, key=None, token=None):
    headers = {"Content-Type": "application/json"}
    if key:
        headers["apikey"] = key
    if token:
        headers["Authorization"] = "Bearer " + token
    data = None if payload is None else json.dumps(payload).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data, headers), timeout=15) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        # Auth responses can contain credentials; report the status only.
        raise RuntimeError(f"Local provider HTTP {error.code}") from None


def wait_server(process, url):
    for _ in range(120):
        if process.poll() is not None:
            raise RuntimeError("Local Swift server exited; private build/runtime log retained.")
        try:
            with urllib.request.urlopen(url + "/health", timeout=1) as response:
                if response.status == 200:
                    return
        except (urllib.error.URLError, TimeoutError):
            time.sleep(0.25)
    raise RuntimeError("Local Swift server did not become ready.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true", help="Also run paired and fresh-pairing iPhone simulator acceptance (macOS/Xcode).")
    parser.add_argument("--modern-keys", action="store_true", help="Use this localhost stack's modern publishable/secret keys instead of legacy JWT API keys.")
    args = parser.parse_args()
    os.umask(0o077)
    directory = Path(tempfile.mkdtemp(prefix="secondlook-m2-"))
    env = dict(os.environ, SUPABASE_TELEMETRY_DISABLED="1")
    # The custom network binds published ports to loopback, including database ports.
    inspected = subprocess.run(["docker", "network", "inspect", NETWORK], capture_output=True)
    if inspected.returncode:
        run(["docker", "network", "create", "--opt",
             "com.docker.network.bridge.host_binding_ipv4=127.0.0.1", NETWORK], stdout=subprocess.DEVNULL)
    else:
        options = json.loads(inspected.stdout)[0]["Options"]
        if options.get("com.docker.network.bridge.host_binding_ipv4") != "127.0.0.1":
            raise RuntimeError("Local test network is not bound to loopback.")
    print("Starting isolated localhost Supabase services; output stays in a private temporary directory.", flush=True)
    with (directory / "stack.private.log").open("w") as log:
        run(["python3", "scripts/local-docker-binding.py"] + CLI + ["start", "--network-id", NETWORK, "--exclude", EXCLUDED], env=env,
            stdout=log, stderr=subprocess.STDOUT)
    bindings = json.loads(run(["docker", "inspect", f"supabase_db_{PROJECT}", f"supabase_kong_{PROJECT}"],
                              capture_output=True).stdout)
    for container in bindings:
        for ports in container["NetworkSettings"]["Ports"].values():
            for binding in ports or []:
                if binding["HostIp"] not in ("127.0.0.1", "::1"):
                    run(CLI + ["stop"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    raise RuntimeError("A local test service was exposed beyond loopback; synthetic stack stopped.")
    status = json.loads(run(CLI + ["status", "-o", "json"], env=env, capture_output=True).stdout)
    provider = status["API_URL"]
    if args.modern_keys:
        public_key = status.get("PUBLISHABLE_KEY", "")
        service_key = status.get("SECRET_KEY", "")
        if not public_key.startswith("sb_publishable_") or not service_key.startswith("sb_secret_"):
            raise RuntimeError("The local stack did not supply modern API keys.")
    else:
        public_key = status["ANON_KEY"]
        service_key = status["SERVICE_ROLE_KEY"]
    # Refuse to reset anything other than this named localhost-only synthetic project.
    if provider != "http://127.0.0.1:56321":
        raise RuntimeError("Unexpected integration provider URL.")
    run(["docker", "exec", f"supabase_db_{PROJECT}", "psql", "-U", "postgres", "-d", "postgres",
         "-v", "ON_ERROR_STOP=1", "-c",
         "truncate secondlook_private.command_receipts, secondlook_private.spaces;"], stdout=subprocess.DEVNULL)
    with (ROOT / "supabase/tests/private_space.sql").open("rb") as sql:
        run(["docker", "exec", "-i", f"supabase_db_{PROJECT}", "psql", "-U", "postgres", "-d", "postgres",
             "-v", "ON_ERROR_STOP=1"], stdin=sql, stdout=subprocess.DEVNULL)
    print("Database expiry, rotation, privilege and receipt transaction checks passed.", flush=True)
    accounts = []
    for role in ("owner", "peer", "outsider"):
        email = f"m2-{role}-{uuid.uuid4().hex}@example.test"
        password = secrets.token_urlsafe(32)
        user = request(provider + "/auth/v1/admin/users", {"email": email, "password": password,
                       "email_confirm": True}, service_key, None if args.modern_keys else service_key)
        accounts.append({"id": user["id"], "email": email, "password": password})
    # The local GoTrue container's HMAC secret is used only to construct a correctly
    # signed expired token for negative validation. It never leaves this private file.
    auth_container = json.loads(run(["docker", "inspect", f"supabase_auth_{PROJECT}"], capture_output=True).stdout)[0]
    auth_env = dict(value.split("=", 1) for value in auth_container["Config"]["Env"] if "=" in value)
    jwt_secret = auth_env.get("GOTRUE_JWT_SECRET")
    if not jwt_secret:
        raise RuntimeError("No local signing secret for expired-token negative test.")
    def encoded(value):
        return base64.urlsafe_b64encode(json.dumps(value, separators=(",", ":")).encode()).rstrip(b"=")
    unsigned = encoded({"alg": "HS256", "typ": "JWT"}) + b"." + encoded({
        "sub": accounts[0]["id"], "aud": "authenticated", "role": "authenticated",
        "iss": provider + "/auth/v1", "exp": int(time.time()) - 300, "iat": int(time.time()) - 600})
    expired = (unsigned + b"." + base64.urlsafe_b64encode(hmac.new(jwt_secret.encode(), unsigned,
                hashlib.sha256).digest()).rstrip(b"=")).decode()
    fixture = {"providerURL": provider, "serverURL": "http://127.0.0.1:58080",
               "publishableKey": public_key, "serviceKey": service_key,
               "owner": accounts[0], "peer": accounts[1], "outsider": accounts[2], "expiredToken": expired}
    fixture_path = directory / "fixture.private.json"
    fixture_path.write_text(json.dumps(fixture))
    ui_fixture = {"authURL": provider, "serverURL": fixture["serverURL"], "publishableKey": public_key,
                  "owner": accounts[0], "peer": accounts[1], "outsider": accounts[2],
                  "syntheticRoutineTitle": "Before leaving"}
    ui_fixture_path = directory / "ui-fixture.private.json"
    ui_fixture_path.write_text(json.dumps(ui_fixture))
    Path(tempfile.gettempdir(), "secondlook-m2-paths.private.json").write_text(json.dumps({
        "fixture": str(fixture_path), "uiFixture": str(ui_fixture_path),
        "directory": str(directory), "scratch": os.environ.get("SECONDLOOK_BACKEND_SCRATCH", str(directory / "build"))}))
    scratch = os.environ.get("SECONDLOOK_BACKEND_SCRATCH", str(directory / "build"))
    build_env = dict(env, CLANG_MODULE_CACHE_PATH=str(directory / "clang"),
                     SWIFTPM_MODULECACHE_OVERRIDE=str(directory / "swiftpm"))
    print("Building the Swift command server and localhost integration tests.", flush=True)
    with (directory / "build.private.log").open("w") as log:
        run(["swift", "build", "--package-path", "Backend", "--scratch-path", scratch, "-j", "8"],
            env=build_env, stdout=log, stderr=subprocess.STDOUT)
    binary_dir = run(["swift", "build", "--package-path", "Backend", "--scratch-path", scratch,
                      "--show-bin-path"], env=build_env, capture_output=True).stdout.decode().strip()
    server_env = dict(build_env, SECONDLOOK_PROVIDER_URL=provider, SECONDLOOK_PUBLISHABLE_KEY=public_key,
                      SECONDLOOK_SERVICE_KEY=service_key,
                      SECONDLOOK_ALLOWED_ACCOUNTS=",".join(x["id"] for x in accounts[:2]),
                      SECONDLOOK_LOCAL_DEVELOPMENT="1", SECONDLOOK_TEST_EVIDENCE="1", SECONDLOOK_PORT="58080")
    test_env = dict(build_env, SECONDLOOK_LOCAL_FIXTURE=str(fixture_path),
                    SECONDLOOK_RESTART_EXPECTED=str(directory / "expected.private.json"))
    test_command = ["swift", "test", "--package-path", "Backend", "--scratch-path", scratch,
                    "-j", "8", "--filter", "LocalIntegrationTests"]
    with (directory / "server.private.log").open("w") as log:
        process = subprocess.Popen([str(Path(binary_dir) / "SecondLookServer")], cwd=ROOT, env=server_env,
                                   stdout=log, stderr=subprocess.STDOUT)
        try:
            wait_server(process, fixture["serverURL"])
            run(test_command, env=test_env)
        finally:
            process.terminate()
            process.wait(timeout=15)
        print("Restarting the command server to verify persisted database state.", flush=True)
        process = subprocess.Popen([str(Path(binary_dir) / "SecondLookServer")], cwd=ROOT, env=server_env,
                                   stdout=log, stderr=subprocess.STDOUT)
        try:
            wait_server(process, fixture["serverURL"])
            run(test_command + ["--skip", "testPrivateSharedState"],
                env=dict(test_env, SECONDLOOK_RESTART_CHECK="1"))
            if args.native:
                print("Running native write/convergence/foreground acceptance against the synthetic server.", flush=True)
                run(["python3", "scripts/verify-connected-native.py", "--fixture", str(ui_fixture_path)])
                run(["docker", "exec", f"supabase_db_{PROJECT}", "psql", "-U", "postgres", "-d", "postgres",
                     "-v", "ON_ERROR_STOP=1", "-c",
                     "truncate secondlook_private.command_receipts, secondlook_private.spaces;"], stdout=subprocess.DEVNULL)
                fresh_path = directory / "ui-fresh.private.json"
                fresh_path.write_text(json.dumps(dict(ui_fixture, freshPairing=True)))
                print("Running native owner creation and invited-peer join against an empty synthetic space.", flush=True)
                run(["python3", "scripts/verify-connected-native.py", "--fixture", str(fresh_path)])
        finally:
            process.terminate()
            process.wait(timeout=15)
    print("Local Auth/Postgres/HTTP integration and server-restart checks passed. Hosted/device acceptance is unverified.")
    print("Synthetic stack remains running; stop with npx --yes supabase@2.119.0 stop (preserves local volumes).")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        # Do not print subprocess output, request contents, credentials, or provider diagnostics.
        print(f"Shared-state verification failed: {error}", flush=True)
        raise SystemExit(1)
