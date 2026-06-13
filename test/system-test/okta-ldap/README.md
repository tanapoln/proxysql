# Okta LDAP plugin — system tests

Two suites exercise the Okta LDAP authentication plugin against a real ProxySQL,
real MySQL, and real PostgreSQL:

| Suite | LDAP server | Runs in CI | Purpose |
|-------|-------------|-----------|---------|
| `run-tests.sh` | live external **Okta** org | no (needs network + a real Okta account) | end-to-end smoke test against the real Okta LDAP interface |
| `regression/` | local **OpenLDAP** container | yes (`CI-okta-ldap.yml`) | hermetic regression tests, one independent script per bug class |

A fast, Docker-free unit test also exists at
`test/tap/tests/test_okta_ldap_auth-t.cpp`; it `dlopen`s the plugin with a
stubbed SQLite3 and is run by the `unit` job of `CI-okta-ldap.yml`.

## Why earlier tests missed real bugs

- **Nothing ran in CI.** The unit test was not registered in any TAP group or
  Makefile, and the system test was not referenced by any workflow. Tests that
  never execute cannot catch regressions. `CI-okta-ldap.yml` now runs both.
- **The unit test used only stubs.** With a stubbed `SQLite3_result` and no
  ProxySQL/admin/protocol/session code (and no LDAP server), the entire
  authentication, admin-command, and connection-lifecycle surface — where most
  bugs lived — was never exercised.
- **The system test needed a live external Okta org** (a trial endpoint plus a
  hard-coded account/password), so it was non-hermetic, unavailable in CI, and
  flaky. The `regression/` suite replaces that with a local OpenLDAP server.
- **Assertions sat at the wrong layer.** Backend-user resolution happens via a
  direct admin-DB query, so "auth succeeds / routes" passed even when the
  plugin's in-memory mapping was wrong. The old "specific user beats @everyone"
  check used a lower priority number for the specific user, so exact-first and
  priority-order gave the same answer. Usernames were always clean emails (no
  SQL metacharacters). Only a handful of connections were opened (never enough
  to surface a per-user connection-counter leak). There were no memory checks.

## What the regression suite covers

The `regression/` directory holds one **independent** script per bug class.
Each sources `regression/lib.sh` (connection helpers + `okta_setup` /
`okta_teardown`), so it can be run on its own and runs in its own process. Setup
and teardown reset the shared ProxySQL to a known baseline — every LDAP variable
back to default (the auth cache disabled via `cache_ttl=0`) and both mapping
tables cleared — so the tests are isolated and order-independent even though they
share one ProxySQL + OpenLDAP. `regression/run-all.sh` waits for the stack, runs
every `test_*.sh`, and fails if any does.

| Script | Guards |
|--------|--------|
| `test_00_config.sh` | the DN format (which contains `=`) round-trips through the admin SET parser |
| `test_01_baseline.sh` | a seeded LDAP user binds (MySQL + PgSQL); a wrong password is rejected |
| `test_02_username_escaping.sh` | a username with SQL metacharacters (`'`) resolves via its exact mapping; unmapped users fall back and are rejected |
| `test_03_exact_precedence.sh` | an exact mapping beats `@everyone` even when `@everyone` has a numerically higher priority |
| `test_04_protocol_isolation.sh` | the MySQL and PgSQL mapping tables are independent at the runtime-table level |
| `test_05_conn_counter.sh` | the PgSQL frontend connection counter is released on disconnect (no per-user lockout / DoS) |
| `test_06_missing_backend.sh` | mapping to a non-existent backend is rejected cleanly without crashing ProxySQL |
| `test_07_per_user_tracking.sh` | per-user tracking/stats key on the Okta user, not the shared backend user |
| `test_08_bulk_mappings.sh` | saving ≥8 mappings (the bulk-insert path) does not crash the daemon |
| `test_09_save_from_runtime.sh` | `SAVE … LDAP MAPPING FROM RUNTIME` writes the persistent main table |
| `test_10_empty_password.sh` | an empty password is rejected (no unauthenticated LDAP bind) |
| `test_11_require_ssl.sh` | `okta_require_ssl=true` rejects LDAP logins on unencrypted connections |

## Running locally

```bash
cd test/system-test/okta-ldap

# Hermetic regression suite (local OpenLDAP — no Okta account needed)
docker compose build proxysql
docker compose up -d openldap mysql mysql2 pgsql proxysql
docker compose run --rm test-regression          # runs regression/run-all.sh
docker compose down -v

# Run a single regression test against an already-running stack:
#   docker compose run --rm --entrypoint "bash /opt/regression/test_05_conn_counter.sh" test-regression

# End-to-end suite against a real Okta org (set OKTA_USER / OKTA_PASS first)
docker compose run --rm test-runner
```
