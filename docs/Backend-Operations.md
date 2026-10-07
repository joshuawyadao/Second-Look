# Private shared-state service — operations

This M2 implementation has verified localhost behavior and a separate [Supabase Free setup guide](Supabase-Free-Setup.md). The hosted Supabase project/private schema and Render Free Swift command server are configured. Hosted HTTPS liveness and public denial boundaries pass; authenticated hosted app acceptance remains incomplete. Use generated synthetic accounts only in the local integration script; never use household photos, participant data or hosted credentials there.

## Structure and protocol

`Backend/` is a separately pinned Swift package. `SupabaseProvider` verifies bearer tokens through Auth and calls privileged SQL RPCs. `PrivateSpaceService` applies `SecondLookCore` commands. `supabase/migrations/202610050001_private_space.sql` supplies transactional persistence. The root package also exports the exact Foundation transport sources compiled by the iPhone app as `SecondLookTransport` for tests.

All wire dates use milliseconds since 1970. Successful responses are JSON with `Cache-Control: no-store`; errors expose a short code, not provider diagnostics or request bodies. A sanitized framework error handler also returns bounded JSON for missing routes and unhandled failures, without the default middleware's full-URL/error logging.

| Request | Result |
| --- | --- |
| `GET /v1/space` | Current account's `SharedSnapshot`; 404 if not paired |
| `POST /v1/spaces`, `{}` | `snapshot`, plaintext `inviteToken` once, `expiresAt`; rotates an unjoined owner's invite |
| `POST /v1/pairing/join`, `{inviteToken}` | Joined snapshot |
| `GET /v1/spaces/{id}` | Snapshot after membership check |
| `POST /v1/spaces/{id}/commands` | `SharedCommandEnvelope` → `SharedCommandResult` |

The service accepts only the typed command envelope's top-level keys. Actor/time fields and full-state uploads are not API inputs. Space revision and domain versions are required. No unpair or real evidence upload endpoint exists.

## Reproducible local checks

Prerequisites: Swift 6.2+ server toolchain (CI pins 6.2.1), Node 20+, Docker-compatible runtime, Python 3, network access to official dependency/container registries. CLI is pinned to 2.119.0. Tests use a dedicated project `secondlook-m2-local`, Docker network `secondlook_m2_local`, provider ports 56321/56322 and server port 58080. The private Unix-socket adapter in `scripts/local-docker-binding.py` forces every test container port binding to 127.0.0.1. The pinned CLI overrides Docker network binding defaults, so the launcher also verifies actual container bindings before creating accounts. It does not change the Docker daemon or user context. Do not replace these with hosted endpoints.

```sh
swift test
swift test --package-path Backend
./scripts/verify-shared-state.sh
./scripts/verify-shared-state.sh --modern-keys
./scripts/verify-native.sh
```

The shared-state script starts local Auth/Postgres/PostgREST, checks bindings, resets only this project's synthetic aggregate, creates three synthetic Auth accounts, builds/starts the server, runs real HTTP integration, restarts the server and verifies database durability. Its default exercises legacy JWT API keys; `--modern-keys` uses the local stack's actual modern publishable/secret keys, including Auth administration without an invalid API-key bearer header. CI runs both modes. Credentials and logs live in a mode-restricted temporary directory; they are never printed or committed. Gated integration tests skip without a fixture; a skipped test is not acceptance evidence. The script must finish successfully to count local integration evidence.

To run complete connected iPhone UI acceptance on macOS/Xcode, use `./scripts/verify-shared-state.sh --native`. It verifies the backend and its restart, keeps the owned synthetic server running for paired write/convergence/foreground acceptance, then resets only this synthetic aggregate for fresh pairing. The server stops afterward. To test an already running synthetic server separately, use `python3 scripts/verify-connected-native.py --fixture /absolute/private/ui-fixture.private.json`. The integration launcher writes the fixture path into `secondlook-m2-paths.private.json` in the platform temporary directory; do not publish its contents or credentials. This runner passes only the private path to XCTest and only public configuration to the app. It checks an accepted native routine write, owner foreground revalidation, peer convergence, and immediate sign-out/third-account isolation. A second `freshPairing:true` private fixture mode checks native owner creation, invitation entry by the unjoined peer, and both accounts seeing the joined space. Run it only against the reset synthetic aggregate. Ordinary `verify-native.sh` reports these gated tests as skipped without a running fixture.

Stop the local stack with `npx --yes supabase@2.119.0 stop`; this preserves volumes. Do not use hosted `link`, `db push`, provisioning or billing commands as part of M2 local testing.

## Server configuration

Configure environment outside Git. Required values: `SECONDLOOK_PROVIDER_URL` (HTTPS), `SECONDLOOK_PUBLISHABLE_KEY` (public), `SECONDLOOK_SERVICE_KEY` (server only), and `SECONDLOOK_ALLOWED_ACCOUNTS` (two distinct provider UUIDs, comma-separated). `SECONDLOOK_PORT` defaults to 8080. Service startup rejects incomplete/unsafe configuration without printing its contents. Modern Supabase `sb_secret_` RPC credentials are sent on `apikey` only; legacy JWT service-role credentials retain their bearer header for localhost compatibility. Auth verification always sends the actual user's bearer token, never the server credential as user identity.

`Backend/Dockerfile` builds the server in Release using the pinned official Swift 6.2.1 image and starts it in the production environment as an unprivileged user. Build from the repository root so its dependency-free core package is available. The allowlisted `.dockerignore` excludes private runtime files and local fixtures. The Dockerfile declares no `ARG` and never references credentials. Render automatically supplies service environment variables as build arguments as well as at runtime; do not describe its environment UI as runtime-only storage, or consume sensitive arguments during the build. See the [setup guide](Supabase-Free-Setup.md) for the vendor guidance, Free-host settings and runtime configuration. Container health is process liveness, not proof of provider readiness.

For local tests only, `SECONDLOOK_LOCAL_DEVELOPMENT=1` allows a loopback HTTP provider and binds the server to 127.0.0.1. Debug additionally permits `SECONDLOOK_TEST_EVIDENCE=1` with that loopback configuration and a non-production application environment. It exposes `/_testing/synthetic-evidence`; this creates metadata labeled `M2-SYNTHETIC-NO-REAL-PHOTO` and uses normal actor/version/persistence checks. No real image is uploaded. Release and normal composition must not accept this route. Never enable it for hosted acceptance.

## Native connection

In local Settings, choose the private shared space flow and enter only public provider URL, publishable key and Swift-server URL. Sign in using an operator-created account. There is no signup or role selection in the connected flow. Either allowed account can create; the other must use the targeted invitation. The public key does not grant access to private tables/RPCs. High-priority evidence capture remains unavailable until M3; server test metadata is labeled synthetic.

Credentials use Keychain; connected snapshots are memory-only. Signing out immediately clears protected UI, navigation and the local credential. It does not promise immediate global access-token revocation: issued access tokens follow provider expiry semantics. Fresh verification and membership checks still run on server requests.

The native transport keeps Supabase Auth failure decoding separate from command-service errors. Auth HTTP 400 `invalid_credentials` becomes a bounded incorrect-email/password error; `refresh_token_not_found` and `refresh_token_already_used` require a fresh sign-in. Unknown or malformed Auth400 replies remain invalid responses, and command-service `code` mapping is unchanged. Product UI never displays raw provider messages or request contents. [Supabase's error reference](https://supabase.com/docs/guides/auth/debugging/error-codes) documents the recognized codes; synthetic transport regressions cover their wire shapes and successful sign-in/session decoding.

Debug UI acceptance uses both `-ui-testing` and `-shared-testing`, a separate Keychain namespace, simulator-only ad hoc signing with the Debug Keychain entitlement, and public configuration passed by the UI test runner. The private fixture is never bundled into the app or Release.

## Hosted setup and pending acceptance

The operator created the dedicated Supabase project in the existing Free organization on October 6, in West US (Oregon). Email/password sign-in is enabled, public signup and anonymous access are disabled, and the private-space migration is installed. Hosted installation checks pass; the automatic RLS helper's API permissions are restricted while its event trigger remains enabled. Both operator-created Auth accounts show confirmed email identities. See [Verification](Verification.md) for evidence and expected private-table no-policy notices. Render's Second Look workspace is Hobby with no card and an existing $0 monthly pipeline spend limit. After explicit operator approval on October 7, the existing modern keys and two-account server allowlist were entered outside Git/app, and the Free Docker service deployed from `7e32ee0` in Oregon. Auto-deploy and PR previews remain Off. The public server URL is `https://secondlook-m2-server.onrender.com`; its API root does not provide a web frontend. Health, unauthenticated/invalid-token denial and Release synthetic-route absence pass over HTTPS. Supabase also denies an actual direct `sl_read` request made with the public publishable key and an invented UUID. The initial public probes alone did not prove authenticated behavior. Subsequent native first-account sign-in, private-space creation and an invented standard-routine write pass against these hosted services, exercising user-token verification and server-secret RPC authorization for those operations. Second-account pairing, convergence and the remaining hosted acceptance are pending. Follow [Supabase Free Setup](Supabase-Free-Setup.md), run the hosted denial/concurrency/version suite, and verify account isolation before closing M2. Backup, monitoring, rate limits, incident/rotation procedures and aggregate-size limits require hosted operational validation. Apple push entitlement, physical two-device/distribution checks and photo storage/cleanup retain their roadmap gates.
