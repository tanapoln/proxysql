# Okta LDAP Authentication Plugin for ProxySQL

Authenticate **MySQL and PostgreSQL** frontend connections against **Okta's LDAP Interface** with result caching. Engineers connect with their Okta credentials; ProxySQL validates them via LDAP bind and routes to backend databases using protocol-specific LDAP mapping tables.

## Architecture

```
Engineer: mysql -h proxy -P 6033 -u alice@company.com -p'okta_pass' -D production_orders
          psql  -h proxy -p 6133 -U alice@company.com -d analytics

    │
    ▼
ProxySQL Frontend (MySQL :6033 / PgSQL :6133)
    ├─ 1. Okta LDAP Auth (with 3600s cache)
    │     └─ Validate alice@company.com via LDAP simple bind
    ├─ 2. Resolve backend user from mapping table
    │     ├─ MySQL: mysql_ldap_mapping → okta_shared
    │     └─ PgSQL: pgsql_ldap_mapping → okta_pgsql
    └─ 3. Route via query rules / hostgroup
          ├─ MySQL: schema "production_orders" → hostgroup 10
          └─ PgSQL: default_hostgroup from pgsql_users
```

**Key properties:**
- Works with both MySQL and PostgreSQL protocols
- No per-user backend mapping required — add/remove users entirely in Okta
- Separate mapping tables per protocol (`mysql_ldap_mapping`, `pgsql_ldap_mapping`)
- Optional per-user backend user overrides, with an `@everyone` catch-all (mapping by Okta group is not currently supported — entries match an exact username or `@everyone`)
- Access control layered via ProxySQL query rules
- PgSQL LDAP auth uses cleartext password exchange (automatic for unknown users)

## Prerequisites

### Okta

1. Enable the **LDAP Interface** in your Okta org (Settings → Directory Integrations → LDAP Interface).
2. Note your LDAP endpoint: `ldaps://<your-org>.ldap.okta.com`
3. Note your Base DN: `dc=<your-org>,dc=com`

### Build Dependencies

| Platform | Install |
|----------|---------|
| Ubuntu/Debian | `apt install libldap2-dev` |
| RHEL/CentOS | `yum install openldap-devel` |
| macOS | `brew install openldap` |

OpenSSL is already required by ProxySQL.

## Building

```bash
# Build the plugin (shared library)
make build_okta_ldap_plugin

# Output:
#   Linux:  binaries/proxysql_okta_ldap_auth.so
#   macOS:  binaries/proxysql_okta_ldap_auth.dylib
```

To clean:
```bash
make clean_okta_ldap_plugin
```

## Configuration

### 1. Load the Plugin

In `proxysql.cfg`:

```
ldap_auth_plugin="/usr/lib/proxysql/proxysql_okta_ldap_auth.so"
```

Or on macOS:
```
ldap_auth_plugin="/usr/local/lib/proxysql_okta_ldap_auth.dylib"
```

### 2. Configure Okta LDAP Variables

Connect to the ProxySQL admin interface and set the variables:

```sql
SET ldap-okta_url='ldaps://yourcompany.ldap.okta.com';
SET ldap-okta_base_dn='dc=yourcompany,dc=com';
SET ldap-okta_user_dn_format='uid=%s,ou=users,%s';
SET ldap-okta_cache_ttl=3600;
SET ldap-okta_bind_timeout_ms=5000;
SET ldap-okta_enabled=true;
SET ldap-okta_default_backend_user='okta_shared';
SET ldap-okta_default_hostgroup=0;
SET ldap-okta_default_max_connections=1000;

LOAD LDAP VARIABLES TO RUNTIME;
SAVE LDAP VARIABLES TO DISK;
```

### 3. Create Backend Users

Backend users are the real database users ProxySQL connects with. Engineers never see these passwords. Use **different backend users** for MySQL and PgSQL to maintain protocol isolation.

**MySQL backend user:**

```sql
INSERT INTO mysql_users (username, password, active, backend, frontend, default_hostgroup)
VALUES ('okta_shared', 'super_secret_db_pass', 1, 1, 0, 0);
--                                                    ^ backend=1, frontend=0
LOAD MYSQL USERS TO RUNTIME;
SAVE MYSQL USERS TO DISK;
```

**PgSQL backend user:**

```sql
INSERT INTO pgsql_users (username, password, active, backend, frontend, default_hostgroup)
VALUES ('okta_pgsql', 'pgsql_secret_pass', 1, 1, 0, 0);
--                                                ^ backend=1, frontend=0
LOAD PGSQL USERS TO RUNTIME;
SAVE PGSQL USERS TO DISK;
```

### 4. Configure LDAP Mapping

Each protocol has its own mapping table. This allows different backend users per protocol.

**MySQL mapping:**

```sql
INSERT INTO mysql_ldap_mapping (priority, frontend_entity, backend_entity, comment)
VALUES (999, '@everyone', 'okta_shared', 'All Okta users → MySQL backend');
LOAD MYSQL LDAP MAPPING TO RUNTIME;
SAVE MYSQL LDAP MAPPING TO DISK;
```

**PgSQL mapping:**

```sql
INSERT INTO pgsql_ldap_mapping (priority, frontend_entity, backend_entity, comment)
VALUES (999, '@everyone', 'okta_pgsql', 'All Okta users → PgSQL backend');
LOAD PGSQL LDAP MAPPING TO RUNTIME;
SAVE PGSQL LDAP MAPPING TO DISK;
```

### 5. Set Up Schema-Based Hostgroup Routing (MySQL)

```sql
INSERT INTO mysql_query_rules (rule_id, active, schemaname, destination_hostgroup, apply)
VALUES
  (100, 1, 'production_orders',  10, 0),
  (200, 1, 'production_users',   20, 0),
  (300, 1, 'staging_orders',     30, 0);
LOAD MYSQL QUERY RULES TO RUNTIME;
SAVE MYSQL QUERY RULES TO DISK;
```

### 6. Connect

```bash
# MySQL: Alice connects to the orders database
mysql -h proxysql.internal -P 6033 -u alice@company.com -p'her_okta_pass' \
  --enable-cleartext-plugin -D production_orders

# PgSQL: Alice connects to analytics
PGPASSWORD='her_okta_pass' psql -h proxysql.internal -p 6133 \
  -U alice@company.com -d analytics
```

## Admin Commands Reference

### LDAP Variables

```sql
LOAD LDAP VARIABLES TO RUNTIME;
SAVE LDAP VARIABLES TO DISK;
LOAD LDAP VARIABLES FROM DISK;
SAVE LDAP VARIABLES FROM RUNTIME;
SHOW LDAP VARIABLES;
```

### MySQL LDAP Mapping

```sql
LOAD MYSQL LDAP MAPPING TO RUNTIME;
SAVE MYSQL LDAP MAPPING FROM RUNTIME;
LOAD MYSQL LDAP MAPPING FROM DISK;
SAVE MYSQL LDAP MAPPING TO DISK;
```

### PgSQL LDAP Mapping

```sql
LOAD PGSQL LDAP MAPPING TO RUNTIME;
SAVE PGSQL LDAP MAPPING FROM RUNTIME;
LOAD PGSQL LDAP MAPPING FROM DISK;
SAVE PGSQL LDAP MAPPING TO DISK;
```

## Admin Variables Reference

All variables use the `ldap-` prefix when set via the admin interface.

| Variable | Default | Description |
|----------|---------|-------------|
| `ldap-okta_url` | `""` | Okta LDAP endpoint (e.g., `ldaps://company.ldap.okta.com`) |
| `ldap-okta_base_dn` | `""` | Base DN for user lookups |
| `ldap-okta_user_dn_format` | `uid=%s,ou=users,%s` | DN format string. First `%s` = username, second `%s` = base_dn |
| `ldap-okta_cache_ttl` | `3600` | Seconds to cache successful auth results |
| `ldap-okta_bind_timeout_ms` | `5000` | LDAP connection/bind timeout in milliseconds |
| `ldap-okta_enabled` | `true` | Enable/disable the plugin. When disabled, falls through to standard auth |
| `ldap-okta_default_backend_user` | `okta_shared` | Fallback backend user when no mapping matches (used if `mysql_ldap_mapping` / `pgsql_ldap_mapping` has no entry) |
| `ldap-okta_default_hostgroup` | `0` | Default hostgroup for MySQL (PgSQL uses the backend user's hostgroup from `pgsql_users`) |
| `ldap-okta_default_max_connections` | `1000` | Max frontend connections per Okta user |
| `ldap-okta_starttls` | `false` | Use StartTLS (for `ldap://` URLs; not needed for `ldaps://`) |
| `ldap-okta_require_ssl` | `false` | When `true`, reject LDAP-authenticated frontend logins arriving over an unencrypted (non-TLS) connection. Note: a PgSQL cleartext password is already on the wire by the time this gate rejects, so combine it with network-level protection; for full prevention require client TLS at the listener. |

## Authentication Flow

### MySQL

1. Client connects to ProxySQL MySQL port (6033) with `username` and `password`
2. If the username is not found in `mysql_users` (frontend), ProxySQL switches to cleartext auth and asks the LDAP plugin
3. Plugin checks its local cache:
   - **Cache hit**: SHA-256 of password matches and entry is within TTL → return immediately
   - **Cache miss/expired**: perform LDAP simple bind against Okta
4. On successful LDAP bind:
   - Resolve backend user from `mysql_ldap_mapping` (supports exact match and `@everyone`)
   - Cache the auth result
5. ProxySQL looks up the backend username in `mysql_users` to get the real DB password
6. Connection routes to hostgroup based on query rules

### PostgreSQL

1. Client connects to ProxySQL PgSQL port (6133) with `username` and `password`
2. If the username is not found in `pgsql_users`, ProxySQL requests cleartext auth from the client
3. Plugin validates via LDAP bind (same cache as MySQL)
4. On successful LDAP bind:
   - Resolve backend user from `pgsql_ldap_mapping` (supports exact match and `@everyone`)
   - Use the backend user's `default_hostgroup` from `pgsql_users` (not `ldap-okta_default_hostgroup`)
5. ProxySQL looks up the backend username in `pgsql_users` to get the real DB password
6. Connection routes to the PgSQL backend

## LDAP Mapping

Each protocol has its own mapping table (`mysql_ldap_mapping`, `pgsql_ldap_mapping`). The mapping resolution follows priority order (lower number = higher priority):

```sql
-- MySQL: Map specific users, with catch-all fallback
INSERT INTO mysql_ldap_mapping (priority, frontend_entity, backend_entity, comment)
VALUES
  (100, 'dba-alice@company.com', 'okta_admin', 'DBA team gets admin backend user'),
  (200, 'bob@company.com', 'okta_readonly', 'Bob is read-only'),
  (999, '@everyone', 'okta_shared', 'Everyone else');
LOAD MYSQL LDAP MAPPING TO RUNTIME;
SAVE MYSQL LDAP MAPPING TO DISK;

-- PgSQL: Separate mapping, can use different backend users
INSERT INTO pgsql_ldap_mapping (priority, frontend_entity, backend_entity, comment)
VALUES
  (100, 'dba-alice@company.com', 'okta_pg_admin', 'DBA gets PgSQL admin'),
  (999, '@everyone', 'okta_pgsql', 'Everyone else');
LOAD PGSQL LDAP MAPPING TO RUNTIME;
SAVE PGSQL LDAP MAPPING TO DISK;
```

The `@everyone` wildcard matches any authenticated user not matched by earlier entries.

Each backend entity must exist in the corresponding users table with `backend=1, frontend=0`.

## Monitoring

### Stats

```sql
SELECT * FROM stats.stats_mysql_ldap_auth;
```

| Metric | Description |
|--------|-------------|
| `Okta_LDAP_cache_hits` | Auth requests served from cache |
| `Okta_LDAP_cache_misses` | Auth requests requiring LDAP bind |
| `Okta_LDAP_cache_expired` | Cache entries that expired |
| `Okta_LDAP_ldap_bind_success` | Successful LDAP binds |
| `Okta_LDAP_ldap_bind_failure` | Failed LDAP binds (wrong password, user not found) |
| `Okta_LDAP_ldap_bind_timeout` | LDAP bind timeouts |
| `Okta_LDAP_ldap_connect_errors` | Failed LDAP connections (network errors) |
| `Okta_LDAP_cache_entries` | Current cache size |
| `Okta_LDAP_active_frontend_connections` | Total active frontend connections |

### Per-User Connection Stats

```sql
SELECT * FROM stats_mysql_users;
```

Shows each Okta user's current and max frontend connections.

## Access Control Examples

### Restrict production access to DBA team

```sql
-- Allow DBA users to production schemas
INSERT INTO mysql_query_rules (rule_id, active, username, schemaname, destination_hostgroup, apply)
VALUES
  (50, 1, 'dba-alice@company.com', 'production_orders', 10, 1),
  (51, 1, 'dba-alice@company.com', 'production_users', 20, 1);

-- Block everyone else from production schemas
INSERT INTO mysql_query_rules (rule_id, active, schemaname, error_msg, apply)
VALUES
  (60, 1, 'production_orders', 'Access denied. Contact DBA team.', 1),
  (61, 1, 'production_users', 'Access denied. Contact DBA team.', 1);

LOAD MYSQL QUERY RULES TO RUNTIME;
```

### Read-only access for specific users

Use a read-only backend user:

```sql
INSERT INTO mysql_users (username, password, active, backend, frontend, default_hostgroup)
VALUES ('okta_readonly', 'readonly_db_pass', 1, 1, 0, 0);

INSERT INTO mysql_ldap_mapping (priority, frontend_entity, backend_entity)
VALUES (200, 'intern@company.com', 'okta_readonly');
LOAD MYSQL LDAP MAPPING TO RUNTIME;
```

The `okta_readonly` MySQL user should have only SELECT grants on the backend databases.

## Offboarding

When an employee leaves:

1. Disable or remove the user in Okta
2. The cache entry expires after `okta_cache_ttl` seconds (default: 1 hour)
3. Next connection attempt will fail LDAP bind → access denied

For immediate revocation, set `ldap-okta_cache_ttl=0` temporarily:

```sql
SET ldap-okta_cache_ttl=0;
LOAD LDAP VARIABLES TO RUNTIME;
-- Wait for active connections to close, then restore
SET ldap-okta_cache_ttl=3600;
LOAD LDAP VARIABLES TO RUNTIME;
```

## Running System Tests

```bash
cd test/system-test/okta-ldap

# Build and run all tests (requires Docker)
docker compose build proxysql
docker compose up -d mysql mysql2 pgsql proxysql
docker compose run --rm test-runner

# Clean up
docker compose down -v
```

The system tests cover:
- MySQL and PgSQL backend connectivity
- Standard auth for both protocols
- LDAP auth via MySQL proxy (Okta bind, cache, wrong password, non-existent user)
- LDAP auth via PgSQL proxy (cleartext auth, backend query routing)
- LOAD/SAVE MYSQL LDAP MAPPING commands (runtime, disk, round-trip)
- `@everyone` catch-all mapping for both protocols
- Cross-protocol isolation (MySQL and PgSQL use independent mapping tables)
- Persistence across restart (save to disk, reload, verify)

## Troubleshooting

| Symptom | Check |
|---------|-------|
| "okta_url not configured" in stderr | Set `ldap-okta_url` and `LOAD LDAP VARIABLES TO RUNTIME` |
| LDAP bind timeout | Increase `ldap-okta_bind_timeout_ms`; verify network path to Okta |
| All users rejected | Check `ldap-okta_enabled=true`; verify DN format matches Okta's user DN structure |
| MySQL: "Access denied" with correct Okta password | Ensure `mysql_ldap_mapping` has an entry (or `@everyone`), and the backend user exists in `mysql_users` with `backend=1` |
| PgSQL: "password authentication failed" | Ensure `pgsql_ldap_mapping` has an entry (or `@everyone`), and the backend user exists in `pgsql_users` with `backend=1` |
| PgSQL: "Hostgroup has no servers" | The PgSQL backend user's `default_hostgroup` in `pgsql_users` must match a hostgroup with PgSQL servers |
| PgSQL monitor auth failure | PostgreSQL 16+ defaults to scram-sha-256; create the monitor user with `SET password_encryption = 'md5'` and add `host all monitor all md5` to `pg_hba.conf` |
| "Connection refused" after disabling in Okta | Working as intended — wait for cache to expire or set `ldap-okta_cache_ttl=0` |
| Cross-protocol backend user confusion | Each protocol resolves from its own mapping table; ensure `LOAD MYSQL LDAP MAPPING TO RUNTIME` and `LOAD PGSQL LDAP MAPPING TO RUNTIME` are both run |
