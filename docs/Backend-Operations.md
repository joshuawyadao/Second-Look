# Private shared-state service — local development

This is an unprovisioned M2 implementation. It is not a deployed backend. Use generated synthetic accounts only; never use household photos, participant data or hosted credentials in the local integration script.

## Structure and protocol

`Backend/` is a separately pinned Swift package. `SupabaseProvider` verifies bearer tokens through Auth and calls privileged SQL RPCs. `PrivateSpaceService` applies `SecondLookCore` commands. `supabase/migrations/202610050001_private_space.sql` supplies transactional persistence. The root package also exports the exact Foundation transport sources compiled by the iPhone app as `SecondLookTransport` for tests.

All wire dates use milliseconds since 1970. Successful responses are JSON with `Cache-Control: no-store`; errors expose a short code, not provider diagnostics or request bodies.

| Request | Result |
| --- | --- |
| `GET /v1/space` | Current account's `SharedSnapshot`; 404 if not paired |
| `POST /v1/spaces`, `{}` | `snapshot`, plaintext `inviteToken` once, `expiresAt`; rotates an unjoined owner's invite |
| `POST /v1/pairing/join`, `{inviteToken}` | Joined snapshot |
| `GET /v1/spaces/{id}` | Snapshot after membership check |
| `POST /v1/spaces/{id}/commands` | `SharedCommandEnvelope` → `SharedCommandResult` |

The service accepts only the typed command envelope's top-level keys. Actor/time fields and full-state uploads are not API inputs. Space revision and domain versions are required. No unpair or real evidence upload endpoint exists.

## Reproducible local checks

Prerequisites: Swift 6.2+ server toolchain (CI pins 6.2.4), Node 20+, Docker-compatible runtime, Python 3, network access to official dependency/container registries. CLI is pinned to 2.119.0. Tests use a dedicated project `secondlook-m2-local`, Docker network `secondlook_m2_local`, provider ports 56321/56322 and server port 58080. The private Unix-socket adapter in `scripts/local-docker-binding.py` forces every test container port binding to 127.0.0.1. The pinned CLI overrides Docker network binding defaults, so the launcher also verifies actual container bindings before creating accounts. It does not change the Docker daemon or user context. Do not replace these with hosted endpoints.

```sh
swift test
swift test --package-path Backend
./scripts/verify-shared-state.sh
./scripts/verify-native.sh
```

The shared-state script starts local Auth/Postgres/PostgREST, checks bindings, resets only this project's synthetic aggregate, creates three synthetic Auth accounts, builds/starts the server, runs real HTTP integration, restarts the server and verifies database durability. Credentials and logs live in a mode-restricted temporary directory; they are never printed or committed. Gated integration tests skip without a fixture; a skipped test is not acceptance evidence. The script must finish successfully to count local integration evidence.

To run complete connected iPhone UI acceptance on macOS/Xcode, use `./scripts/verify-shared-state.sh --native`. It verifies the backend and its restart, keeps the owned synthetic server running for paired write/convergence/foreground acceptance, then resets only this synthetic aggregate for fresh pairing. The server stops afterward. To test an already running synthetic server separately, use `python3 scripts/verify-connected-native.py --fixture /absolute/private/ui-fixture.private.json`. The integration launcher writes the fixture path into `secondlook-m2-paths.private.json` in the platform temporary directory; do not publish its contents or credentials. This runner passes only the private path to XCTest and only public configuration to the app. It checks an accepted native routine write, owner foreground revalidation, peer convergence, and immediate sign-out/third-account isolation. A second `freshPairing:true` private fixture mode checks native owner creation, invitation entry by the unjoined peer, and both accounts seeing the joined space. Run it only against the reset synthetic aggregate. Ordinary `verify-native.sh` reports these gated tests as skipped without a running fixture.

Stop the local stack with `npx --yes supabase@2.119.0 stop`; this preserves volumes. Do not use hosted `link`, `db push`, provisioning or billing commands as part of M2 local testing.

## Server configuration

Configure environment outside Git. Required values: `SECONDLOOK_PROVIDER_URL` (HTTPS), `SECONDLOOK_PUBLISHABLE_KEY` (public), `SECONDLOOK_SERVICE_KEY` (server only), and `SECONDLOOK_ALLOWED_ACCOUNTS` (two distinct provider UUIDs, comma-separated). `SECONDLOOK_PORT` defaults to 8080. Service startup rejects incomplete/unsafe configuration without printing its contents.

For local tests only, `SECONDLOOK_LOCAL_DEVELOPMENT=1` allows a loopback HTTP provider and binds the server to 127.0.0.1. Debug additionally permits `SECONDLOOK_TEST_EVIDENCE=1` with that loopback configuration and a non-production application environment. It exposes `/_testing/synthetic-evidence`; this creates metadata labeled `M2-SYNTHETIC-NO-REAL-PHOTO` and uses normal actor/version/persistence checks. No real image is uploaded. Release and normal composition must not accept this route. Never enable it for hosted acceptance.

## Native connection

In local Settings, choose the private shared space flow and enter only public provider URL, publishable key and Swift-server URL. Sign in using an operator-created account. There is no signup or role selection in the connected flow. Either allowed account can create; the other must use the targeted invitation. The public key does not grant access to private tables/RPCs. High-priority evidence capture remains unavailable until M3; server test metadata is labeled synthetic.

Credentials use Keychain; connected snapshots are memory-only. Signing out immediately clears protected UI, navigation and the local credential. It does not promise immediate global access-token revocation: issued access tokens follow provider expiry semantics. Fresh verification and membership checks still run on server requests.

Debug UI acceptance uses both `-ui-testing` and `-shared-testing`, a separate Keychain namespace, simulator-only ad hoc signing with the Debug Keychain entitlement, and public configuration passed by the UI test runner. The private fixture is never bundled into the app or Release.

## Deferred hosted acceptance

No hosted Supabase project, Swift-service host, region, billing, secrets, Apple push entitlement or distribution route has been selected/provisioned. Before connected acceptance: confirm provider/operator access and region/privacy decisions; create the actual two accounts without public signup; install migrations using the chosen deployment process; keep server secrets outside Git/app; configure HTTPS and operations; run the full denial/concurrency/version suite against the hosted environment; verify two real devices and account isolation. Backup, monitoring, rate limits, incident/rotation procedures and aggregate-size limits require hosted operational validation. Photo storage/cleanup remains M3.
