# Supabase Free setup for Milestone 2

Setup direction selected October 6, 2026: a dedicated **Supabase Free organization/project**, with a **Render Free web service** as the proposed host for the Swift command server. This is a development/acceptance setup. Operator sign-in, project creation, private credentials and hosted acceptance are pending; no hosted deployment is claimed. The localhost implementation and its tests are described in [Backend Operations](Backend-Operations.md) and [Verification](Verification.md).

## Cost safeguards

Supabase states that [Free-plan usage is not charged](https://supabase.com/docs/guides/platform/cost-control). Free does not have a separate configurable dollar cap; over-quota use can cause restrictions under its fair-use policy. Keep the organization on **Free**, decline paid upgrades and add-ons, and check its Usage page. All projects in an organization share its plan: a new project inside an existing Pro organization is paid. The [billing FAQ](https://supabase.com/docs/guides/platform/billing-faq) describes the two-active-Free-project limit across organizations in which the operator is an Owner/Admin. A dedicated project isolates this app's data; it does not create unlimited Free projects or isolate every quota from other projects in the same organization.

Do not upgrade to Pro just to obtain a Spend Cap. That cap covers selected usage overages and excludes compute and several add-ons; it is not a universal spending ceiling. The current [Free pricing](https://supabase.com/pricing) also includes inactivity pausing and lacks automatic backups. Availability and backup/restore acceptance remain operational limitations.

The command-server host has separate billing. For the proposed [Render Free](https://render.com/docs/free) service, use a Free instance in a workspace with **no payment method**, and keep builds/manual deploys bounded. Without a payment method, exhausted bandwidth suspends services and exhausted build minutes prevent new builds instead of charging for extra usage. If a card is already attached, Free compute alone does not prevent bandwidth/build overage charges; inspect that workspace before deploying. Free services sleep after 15 idle minutes and can take about a minute to wake. Do not add keep-alive traffic, paid disks, paid databases or custom-domain purchases. Use Supabase Postgres; Render's Free Postgres expires after 30 days.

## 1. Create the dedicated project

1. Sign in to the [Supabase dashboard](https://supabase.com/dashboard) yourself. Choose or create a **Free** organization, checking the displayed plan before submitting. Leave unrelated projects unchanged.
2. Create a project named **Second Look**. Prefer a nearby US region if offered; record the actual region privately and keep the server nearby where practical. Region selection remains an engineering default, not a completed privacy or legal review.
3. Enter a strong database password yourself and store it in your password manager. Do not put it in chat, this public repository, an image or a build argument. Stop at any paid-plan or new terms/permission prompt that requires an operator decision.
4. Wait until the project is ready, then recheck the organization's Billing/Usage pages show Free. Do not create a Storage bucket in M2: real photos and retention/cleanup belong to M3.

## 2. Configure private sign-in and install the schema

In Auth configuration, enable email/password sign-in, disable **Allow new users to sign up**, and disable anonymous sign-in. Use Auth → Users → Add user → Create user to create exactly two operator-managed accounts, with distinct identities and securely delivered passwords. Complete credential entry privately. The app implements password sign-in and refresh; email invitation/password-setup deep links and public signup are not implemented. Do not send invitations as a substitute for that missing flow.

Install [202610050001_private_space.sql](../supabase/migrations/202610050001_private_space.sql) into **this dedicated project**, using the dashboard SQL editor or an explicitly linked CLI migration workflow. Review the target project before execution. The migration creates the private schema, RLS/revoked client access and service-role-only transactional RPCs. Do not expose `secondlook_private` in Data API settings or grant app roles direct RPC/table access. Run the privilege checks and inspect Security Advisor findings instead of dismissing them blindly. The local test script must never be pointed at this hosted project: it intentionally resets only its named localhost synthetic aggregate.

Keep the two Auth user UUIDs in the server's private environment, not in public docs. A third synthetic account used for hosted denial acceptance is a test actor and must stay outside the two-account allowlist. Keep acceptance content invented; never use household photos or tasks to validate access.

## 3. Configure and host the Swift server

Use Settings → API Keys / the project's Connect dialog. Prefer a modern `sb_publishable_…` key for the app and a modern `sb_secret_…` key for the server. Modern keys go on `apikey`; actual user access tokens go on `Authorization: Bearer`. The server supports modern RPC headers and retains the legacy JWT service-role path for the pinned localhost stack. Both modes pass actual localhost Auth/Postgres/HTTP and restart checks, as well as request-level tests. See [Supabase API keys](https://supabase.com/docs/guides/api/api-keys). Local checks do not prove hosted key authorization; validate the actual project before claiming acceptance.

In a checked Free Render workspace, create a Web Service from the public repository's intended feature-branch commit. Use Language **Docker**, repository-root build context, Dockerfile **Backend/Dockerfile**, Free instance, port **8080**, health check **/health**, and manual deployment. Leave Docker Command empty to use the Release/production entrypoint. See [Render Docker configuration](https://render.com/docs/docker). No database, disk or background worker is needed for this M2 service.

Enter these values in the host's environment/secret UI, outside Git:

| Variable | Value and handling |
| --- | --- |
| `SECONDLOOK_PROVIDER_URL` | Dedicated project's HTTPS URL; public configuration |
| `SECONDLOOK_PUBLISHABLE_KEY` | Project's public publishable key |
| `SECONDLOOK_SERVICE_KEY` | Modern secret key; server only, entered privately |
| `SECONDLOOK_ALLOWED_ACCOUNTS` | Two distinct Auth UUIDs separated by a comma; keep private |
| `SECONDLOOK_PORT` | `8080` |
| `PORT` | `8080`, to match Render's port detection |

Do not set `SECONDLOOK_LOCAL_DEVELOPMENT`, `SECONDLOOK_TEST_EVIDENCE` or demo flags on a hosted service. Do not use secrets as Docker build arguments. The image accepts runtime configuration, runs as an unprivileged user and builds Release; its build context excludes local private files and fixtures. Its health route checks process availability only, not provider/database readiness.

To build locally without credentials:

```sh
docker build -f Backend/Dockerfile -t secondlook-m2-server:local .
```

Use a private runtime environment file outside Git for local container checks if needed; never paste secrets into a command committed to documentation. Keep local test ports on loopback. The container's build and startup evidence is recorded separately from hosted operation.

## 4. Connect and verify

The iPhone's private shared-space Settings accept only the Supabase HTTPS URL, public publishable key and the Swift server's HTTPS URL. Sign in with one of the two allowed accounts, create the private space and pass the targeted short-lived invitation to the other account. Session credentials stay in Keychain. The app never receives the server secret or database password.

Before closing M2, verify hosted pairing, third-account and direct-RPC denial, actual user-token verification/refresh, accepted writes and convergence, stale-version rejection, request-bound retry/concurrency, immutable snapshots and terminal closure, server restart durability, and account-switch/foreground isolation. Test a Render cold start honestly; do not hide unavailable service states. Release must reject the synthetic-evidence route. M2 photo review rules have localhost synthetic metadata evidence only; hosted real-media behavior belongs to M3. Record each completed check in [Verification](Verification.md). Physical two-device/signing/distribution decisions remain separate later work.
