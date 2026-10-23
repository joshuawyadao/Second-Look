#!/usr/bin/env python3
"""Actual localhost Auth/Postgres/Swift HTTP tests, using generated synthetic accounts only."""
from __future__ import annotations
import argparse
import base64
import hashlib
import hmac
import json
import os
import re
import signal
from pathlib import Path
import secrets
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from shared_stack_diagnostics import startup_failure_message

ROOT = Path(__file__).resolve().parents[1]
CLI = ["npx", "--yes", "supabase@2.119.0"]
PROJECT = "secondlook-m2-local"
NETWORK = "secondlook_m2_local"
EXCLUDED = "realtime,storage-api,imgproxy,mailpit,postgres-meta,studio,edge-runtime,logflare,vector,supavisor"
DEADLINES = {"inventory": 20, "docker": 60, "stack_start": 300, "cli_status": 30,
             "stack_stop": 60, "schema": 120, "build": 600, "bin_path": 30,
             "integration": 600, "native": 780}


class VerifierFailure(RuntimeError):
    def __init__(self, code: str):
        self.code = code


def deadline_for(command):
    """Accept only this verifier's known local commands with a finite phase limit."""
    phase = None
    if command[:3] == ["docker", "network", "inspect"] and command[3:] == [NETWORK]:
        phase = "inventory"
    elif command[:3] == ["docker", "network", "create"] and command[-1:] == [NETWORK]:
        phase = "docker"
    elif command[:2] == ["docker", "inspect"] and command[2:] and all(
            item in {f"supabase_db_{PROJECT}", f"supabase_kong_{PROJECT}",
                     f"supabase_auth_{PROJECT}"} for item in command[2:]):
        phase = "inventory"
    elif command[:2] == ["docker", "exec"] and len(command) > 3 and command[2 + (command[2] == "-i")] == f"supabase_db_{PROJECT}":
        phase = "schema"
    elif command[:2] == ["python3", "scripts/local-docker-binding.py"] and \
            command[2:2 + len(CLI) + 1] == [*CLI, "start"]:
        phase = "stack_start"
    elif command[:len(CLI) + 1] == [*CLI, "status"]:
        phase = "cli_status"
    elif command[:len(CLI) + 1] == [*CLI, "stop"]:
        phase = "stack_stop"
    elif command[:2] == ["swift", "build"]:
        phase = "bin_path" if "--show-bin-path" in command else "build"
    elif command[:2] == ["swift", "test"]:
        phase = "integration"
    elif command[:2] == ["python3", "scripts/verify-connected-native.py"]:
        phase = "native"
    if phase is None:
        raise VerifierFailure("unsupported_command")
    return phase, DEADLINES[phase]


def stop_owned_process(process, grace=5):
    """Stop the process group, including descendants after its leader exits, and reap it."""
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.communicate(timeout=grace)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        process.communicate(timeout=grace)
    except subprocess.TimeoutExpired:
        try:
            process.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            raise VerifierFailure("cleanup") from None


def stop_owned_server(process):
    stop_owned_process(process, grace=15)


def run_owned(command, timeout, phase, *, grace=5, check=True, capture_output=False,
              input=None, stdin=None, stdout=None, stderr=None, env=None):
    if input is not None and stdin is not None:
        raise VerifierFailure("unsupported_command")
    try:
        process = subprocess.Popen(command, cwd=ROOT, env=env, start_new_session=True,
                                   stdin=subprocess.PIPE if input is not None else stdin or subprocess.DEVNULL,
                                   stdout=subprocess.PIPE if capture_output else stdout or subprocess.DEVNULL,
                                   stderr=subprocess.PIPE if capture_output else stderr or subprocess.DEVNULL)
    except OSError:
        raise VerifierFailure(phase + "_failed") from None
    try:
        output, error = process.communicate(input=input, timeout=timeout)
    except subprocess.TimeoutExpired:
        stop_owned_process(process, grace=grace)
        raise VerifierFailure(phase + "_timeout") from None
    if check and process.returncode != 0:
        raise VerifierFailure(phase + "_failed")
    return subprocess.CompletedProcess(command, process.returncode, output, error)


def run(command, **kwargs):
    phase, timeout = deadline_for(command)
    return run_owned(command, timeout, phase, **kwargs)


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


def start_stack(directory, env):
    stack_log = directory / "stack.private.log"
    with stack_log.open("w") as log:
        try:
            run(["python3", "scripts/local-docker-binding.py"] + CLI + ["start", "--debug", "--network-id", NETWORK, "--exclude", EXCLUDED], env=env,
                stdout=log, stderr=subprocess.STDOUT)
        except VerifierFailure as failure:
            log.flush()
            if failure.code == "stack_start_timeout":
                raise RuntimeError("Local Supabase startup timed out; owned process group stopped; inspect the private stack log.") from None
            raise RuntimeError(startup_failure_message(stack_log)) from None
        except subprocess.CalledProcessError:
            log.flush()
            raise RuntimeError(startup_failure_message(stack_log)) from None


def apply_pending_local_migrations():
    """Apply only checked-in migrations to the exact named synthetic database."""
    docker = ["docker", "exec", "-i", f"supabase_db_{PROJECT}", "psql", "-U", "postgres",
              "-d", "postgres", "-v", "ON_ERROR_STOP=1"]
    for migration in sorted((ROOT / "supabase/migrations").glob("*.sql")):
        matched = re.fullmatch(r"(\d{12,14})_([a-z0-9_]+)\.sql", migration.name)
        if not matched:
            raise RuntimeError("Unsupported local migration filename.")
        version, name = matched.groups()
        check = run(docker + ["-At", "-c", "select count(*) from supabase_migrations.schema_migrations "
                    "where version = '" + version + "';"], capture_output=True).stdout.decode().strip()
        if check == "1":
            continue
        if check != "0":
            raise RuntimeError("Unexpected local migration status.")
        sql = ("begin;\n" + migration.read_text() + "\ninsert into supabase_migrations.schema_migrations "
               "(version, name) values ('" + version + "', '" + name + "');\ncommit;\n")
        run(docker, input=sql.encode(), stdout=subprocess.DEVNULL)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true", help="Also run paired and fresh-pairing iPhone simulator acceptance (macOS/Xcode).")
    parser.add_argument("--modern-keys", action="store_true", help="Use this localhost stack's modern publishable/secret keys instead of legacy JWT API keys.")
    args = parser.parse_args()
    os.umask(0o077)
    directory = Path(tempfile.mkdtemp(prefix="secondlook-m2-"))
    env = dict(os.environ, SUPABASE_TELEMETRY_DISABLED="1")
    # The custom network binds published ports to loopback, including database ports.
    inspected = run(["docker", "network", "inspect", NETWORK], capture_output=True, check=False)
    if inspected.returncode:
        run(["docker", "network", "create", "--opt",
             "com.docker.network.bridge.host_binding_ipv4=127.0.0.1", NETWORK], stdout=subprocess.DEVNULL)
    else:
        options = json.loads(inspected.stdout)[0]["Options"]
        if options.get("com.docker.network.bridge.host_binding_ipv4") != "127.0.0.1":
            raise RuntimeError("Local test network is not bound to loopback.")
    print("Starting isolated localhost Supabase services; output stays in a private temporary directory.", flush=True)
    start_stack(directory, env)
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
    apply_pending_local_migrations()
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
    # Stable caches accompany a reused scratch path; fresh per-run cache paths otherwise
    # invalidate the cached dependency build and obscure the HTTP/UI feedback loop.
    module_cache = Path(scratch).resolve() / "module-caches"
    build_env = dict(env, CLANG_MODULE_CACHE_PATH=str(module_cache / "clang"),
                     SWIFTPM_MODULECACHE_OVERRIDE=str(module_cache / "swiftpm"))
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
    with (directory / "server.private.log").open("w") as log, \
            (directory / "integration.private.log").open("w") as integration_log:
        process = subprocess.Popen([str(Path(binary_dir) / "SecondLookServer")], cwd=ROOT, env=server_env,
                                   stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            wait_server(process, fixture["serverURL"])
            run(test_command, env=test_env, stdout=integration_log, stderr=subprocess.STDOUT)
        finally:
            stop_owned_server(process)
        print("Restarting the command server to verify persisted database state.", flush=True)
        process = subprocess.Popen([str(Path(binary_dir) / "SecondLookServer")], cwd=ROOT, env=server_env,
                                   stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            wait_server(process, fixture["serverURL"])
            run(test_command + ["--skip", "testPrivateSharedState"],
                env=dict(test_env, SECONDLOOK_RESTART_CHECK="1"),
                stdout=integration_log, stderr=subprocess.STDOUT)
            if args.native:
                print("Running native write/convergence/foreground acceptance against the synthetic server.", flush=True)
                run(["python3", "scripts/verify-connected-native.py", "--fixture", str(ui_fixture_path)],
                    stdout=integration_log, stderr=subprocess.STDOUT)
                run(["docker", "exec", f"supabase_db_{PROJECT}", "psql", "-U", "postgres", "-d", "postgres",
                     "-v", "ON_ERROR_STOP=1", "-c",
                     "truncate secondlook_private.command_receipts, secondlook_private.spaces;"], stdout=subprocess.DEVNULL)
                fresh_path = directory / "ui-fresh.private.json"
                fresh_path.write_text(json.dumps(dict(ui_fixture, freshPairing=True)))
                print("Running native owner creation and invited-peer join against an empty synthetic space.", flush=True)
                run(["python3", "scripts/verify-connected-native.py", "--fixture", str(fresh_path)],
                    stdout=integration_log, stderr=subprocess.STDOUT)
                run(["docker", "exec", f"supabase_db_{PROJECT}", "psql", "-U", "postgres", "-d", "postgres",
                     "-v", "ON_ERROR_STOP=1", "-c",
                     "truncate secondlook_private.command_receipts, secondlook_private.spaces;"], stdout=subprocess.DEVNULL)
                access_loss_path = directory / "ui-access-loss.private.json"
                access_loss_path.write_text(json.dumps(dict(ui_fixture, invitationAccessLoss=True)))
                print("Running native invitation access-loss acceptance against an empty synthetic space.", flush=True)
                run(["python3", "scripts/verify-connected-native.py", "--fixture", str(access_loss_path),
                     "--only-invitation-access-loss"], stdout=integration_log, stderr=subprocess.STDOUT)
                recovery_cases = (
                    ("invitation", "committed invitation renewal with a lost reply"),
                    ("invitation-expiry", "expired invitation display during paused same-revision refresh"),
                    ("join", "committed peer join with a lost reply"),
                    ("restore", "concurrent account restoration"),
                    ("busy", "mutation controls during a delayed refresh"),
                    ("draft", "editor draft after a genuine one-off rejection"),
                    ("identity", "protected-state clearing after a refresh identity mismatch"),
                    ("revision-floor", "initial membership revision after a simulated lagging explicit fetch"),
                    ("revision-consistency", "same-revision content rejection before coordinator publication"),
                    ("receipt", "original command receipt after invitation renewal"),
                    ("create", "membership discovery after an initial creation reply is lost"),
                    ("lifecycle", "original command receipt across foreground revalidation"),
                    ("alert", "unknown-outcome alert privacy across foreground revalidation"),
                    ("forbidden", "saved-session cleanup after a forbidden restoration"),
                    ("creation", "originating-flow completion after recovered creation receipts"),
                    ("creation-navigation", "pending routine Start across tab and navigation changes"),
                    ("creation-editor-oneoff", "one-off editor recovery after simulated lost reply and dismissal"),
                    ("creation-editor-routine", "new-routine editor recovery after simulated lost reply and dismissal"),
                    ("creation-open-saveas", "open-checklist save-as recovery across navigation"),
                    ("creation-archive-repeat", "archive repeat recovery across navigation"),
                    ("creation-archive-saveas", "archive save-as recovery across navigation"),
                    ("cleanup", "explicit synthetic archive cleanup status"),
                    ("draft-lifecycle", "private drafts across verified foreground revalidation"),
                )
                for recovery_case, description in recovery_cases:
                    # Each scenario needs its own empty space. Truncate only the exact
                    # named synthetic project's private receipt and space tables.
                    run(["docker", "exec", f"supabase_db_{PROJECT}", "psql", "-U", "postgres", "-d", "postgres",
                         "-v", "ON_ERROR_STOP=1", "-c",
                         "truncate secondlook_private.command_receipts, secondlook_private.spaces;"],
                        stdout=subprocess.DEVNULL)
                    recovery_path = directory / f"ui-recovery-{recovery_case}.private.json"
                    recovery_path.write_text(json.dumps(dict(ui_fixture, pairingRecovery=True,
                                                             recoveryCase=recovery_case)))
                    print(f"Running native {description} against an empty synthetic space.", flush=True)
                    run(["python3", "scripts/verify-connected-native.py", "--fixture", str(recovery_path),
                         "--only-pairing-recovery", "--recovery-case", recovery_case],
                        stdout=integration_log, stderr=subprocess.STDOUT)
        finally:
            stop_owned_server(process)
    print("Local Auth/Postgres/HTTP integration and server-restart checks passed. Hosted/device acceptance is unverified.")
    print("Synthetic stack remains running; stop with npx --yes supabase@2.119.0 stop (preserves local volumes).")


def safe_failure_message(error):
    """Public result text uses fixed categories, never command arguments or provider data."""
    if isinstance(error, VerifierFailure):
        if error.code == "cleanup":
            return "Owned process cleanup did not complete; inspect private logs."
        labels = {"inventory": "Docker inventory", "docker": "local Docker setup",
                  "stack_start": "local Supabase startup", "cli_status": "local Supabase status",
                  "stack_stop": "local Supabase stop", "schema": "local schema checks",
                  "build": "Swift server build", "bin_path": "Swift binary lookup",
                  "integration": "local HTTP integration tests", "native": "native acceptance wrapper"}
        for phase, label in labels.items():
            if error.code == phase + "_timeout":
                return label + " timed out; owned process group stopped; inspect private logs."
            if error.code == phase + "_failed":
                return label + " failed; inspect private logs."
        return "Local command unavailable; inspect private logs."
    message = str(error)
    fixed = {
        "Unsupported local migration filename.", "Unexpected local migration status.",
        "Local test network is not bound to loopback.",
        "A local test service was exposed beyond loopback; synthetic stack stopped.",
        "The local stack did not supply modern API keys.", "Unexpected integration provider URL.",
        "No local signing secret for expired-token negative test.",
        "Local Swift server exited; private build/runtime log retained.",
        "Local Swift server did not become ready.",
        "Local Supabase startup timed out; owned process group stopped; inspect the private stack log.",
    }
    if message in fixed or message.startswith("Local Supabase startup failed:") or \
            re.fullmatch(r"Local provider HTTP \d{3}", message):
        return message
    return "Local verification unavailable; inspect private logs."


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("Shared-state verification failed: " + safe_failure_message(error), flush=True)
        raise SystemExit(1)
