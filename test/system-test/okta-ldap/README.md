# Okta LDAP plugin — system tests

Two suites exercise the Okta LDAP authentication plugin against a real ProxySQL,
real MySQL, and real PostgreSQL:

| Suite | LDAP server | Runs in CI | Purpose |
|-------|-------------|-----------|---------|
| `run-tests.sh` | live external **Okta** org | no (needs network + a real Okta account) | end-to-end smoke test against the real Okta LDAP interface |
| `run-regression-tests.sh` | local **OpenLDAP** container | yes (`CI-okta-ldap.yml`) | hermetic regression tests for specific bug classes |

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
  flaky. `run-regression-tests.sh` replaces that with a local OpenLDAP server.
- **Assertions sat at the wrong layer.** Backend-user resolution happens via a
  direct admin-DB query, so "auth succeeds / routes" passed even when the
  plugin's in-memory mapping was wrong. The old "specific user beats @everyone"
  check used a lower priority number for the specific user, so exact-first and
  priority-order gave the same answer. Usernames were always clean emails (no
  SQL metacharacters). Only a handful of connections were opened (never enough
  to surface a per-user connection-counter leak). There were no memory checks.

## What the regression suite covers

`run-regression-tests.sh` configures ProxySQL to bind against the local
OpenLDAP server (seeded from `ldap/bootstrap.ldif`) and then runs, each phase
guarding a specific fix:

| Phase | Guards |
|-------|--------|
| 3 | username is SQL-escaped in the mapping lookup (a `'` in the username must not break or bypass resolution) |
| 4 | an exact mapping beats the `@everyone` catch-all even when `@everyone` has a numerically higher priority |
| 5 | the MySQL and PgSQL mapping tables are independent (loading one must not clobber the other's runtime table) |
| 6 | the PgSQL frontend connection counter is decremented on disconnect (no per-user lockout / DoS) |
| 7 | mapping to a non-existent backend user is rejected cleanly without crashing ProxySQL |

## Running locally

```bash
cd test/system-test/okta-ldap

# Hermetic regression suite (local OpenLDAP — no Okta account needed)
docker compose build proxysql
docker compose up -d openldap mysql mysql2 pgsql proxysql
docker compose run --rm test-regression
docker compose down -v

# End-to-end suite against a real Okta org (set OKTA_USER / OKTA_PASS first)
docker compose run --rm test-runner
```
