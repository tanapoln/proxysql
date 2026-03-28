# Okta LDAP Authentication Plugin for ProxySQL

Authenticate MySQL frontend connections against **Okta's LDAP Interface** with result caching. Engineers connect with their Okta credentials; ProxySQL validates them via LDAP bind and routes to backend databases based on the schema name specified at connect time.

## Architecture

```
Engineer: mysql -h proxy -P 6033 -u alice@company.com -p'okta_pass' -D production_orders
    │
    ▼
ProxySQL Frontend
    ├─ 1. Okta LDAP Auth (with 3600s cache)
    │     └─ Validate alice@company.com via LDAP simple bind
    ├─ 2. Map to shared backend user (e.g., "okta_shared")
    │     └─ All Okta users → single backend MySQL user
    └─ 3. Route via schema-based query rules
          ├─ schema "production_orders" → hostgroup 10
          ├─ schema "production_users"  → hostgroup 20
          └─ schema "staging_orders"    → hostgroup 30
```

**Key properties:**
- No per-user backend mapping required — add/remove users entirely in Okta
- Any authenticated user can access any database by specifying the schema
- Optional per-user or per-group backend user overrides via `mysql_ldap_mapping`
- Access control layered via ProxySQL query rules

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

### 3. Create the Shared Backend User

This is the real MySQL user ProxySQL uses for backend connections. Engineers never see this password.

```sql
INSERT INTO mysql_users (username, password, active, backend, frontend, default_hostgroup)
VALUES ('okta_shared', 'super_secret_db_pass', 1, 1, 0, 0);
--                                                    ^ backend=1, frontend=0
LOAD MYSQL USERS TO RUNTIME;
SAVE MYSQL USERS TO DISK;
```

### 4. Set Up Schema-Based Hostgroup Routing

```sql
-- Route by schema name to different database clusters
INSERT INTO mysql_query_rules (rule_id, active, schemaname, destination_hostgroup, apply)
VALUES
  (100, 1, 'production_orders',  10, 0),
  (200, 1, 'production_users',   20, 0),
  (300, 1, 'staging_orders',     30, 0),
  (400, 1, 'staging_users',      40, 0),
  (500, 1, 'analytics',          50, 0);
LOAD MYSQL QUERY RULES TO RUNTIME;
SAVE MYSQL QUERY RULES TO DISK;

-- Configure backend servers in each hostgroup
INSERT INTO mysql_servers (hostgroup_id, hostname, port) VALUES
  (10, 'orders-db-primary.internal', 3306),
  (20, 'users-db-primary.internal', 3306),
  (30, 'staging-orders-db.internal', 3306),
  (40, 'staging-users-db.internal', 3306),
  (50, 'analytics-replica.internal', 3306);
LOAD MYSQL SERVERS TO RUNTIME;
SAVE MYSQL SERVERS TO DISK;
```

### 5. Connect

```bash
# Alice connects to the orders database
mysql -h proxysql.internal -P 6033 -u alice@company.com -p'her_okta_pass' -D production_orders

# Bob connects to analytics
mysql -h proxysql.internal -P 6033 -u bob@company.com -p'his_okta_pass' -D analytics
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
| `ldap-okta_default_backend_user` | `okta_shared` | Backend MySQL user for Okta-authenticated connections |
| `ldap-okta_default_hostgroup` | `0` | Default hostgroup (overridden by query rules) |
| `ldap-okta_default_max_connections` | `1000` | Max frontend connections per Okta user |
| `ldap-okta_starttls` | `false` | Use StartTLS (for `ldap://` URLs; not needed for `ldaps://`) |

## Authentication Flow

1. Client connects to ProxySQL with `username` and `password`
2. If the username is not found in `mysql_users` (frontend), ProxySQL asks the LDAP plugin
3. Plugin checks its local cache:
   - **Cache hit**: SHA-256 of password matches and entry is within TTL → return immediately
   - **Cache miss/expired**: perform LDAP simple bind against Okta
4. On successful LDAP bind:
   - Resolve backend user (from `mysql_ldap_mapping` or default)
   - Cache the result
   - Return backend username to ProxySQL
5. ProxySQL looks up the backend username in `mysql_users` to get the real DB password
6. Connection routes to hostgroup based on query rules matching the schema name

## LDAP Mapping (Optional)

By default, all Okta users map to the `okta_default_backend_user`. For fine-grained control:

```sql
-- Map specific users to different backend users
INSERT INTO mysql_ldap_mapping (priority, frontend_entity, backend_entity, comment)
VALUES
  (100, 'dba-alice@company.com', 'okta_admin', 'DBA team gets admin backend user'),
  (200, 'bob@company.com', 'okta_readonly', 'Bob is read-only'),
  (999, '@everyone', 'okta_shared', 'Everyone else');
LOAD MYSQL LDAP MAPPING TO RUNTIME;
```

The `@everyone` wildcard matches any authenticated user not matched by earlier entries.

Each backend entity (`okta_admin`, `okta_readonly`, `okta_shared`) must exist in `mysql_users` with `backend=1, frontend=0`.

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

## Running Tests

```bash
# Build the plugin first
make build_okta_ldap_plugin

# Build and run unit tests (no Okta server needed)
cd test/tap/tests
g++ -std=c++17 -DCXX17 -O0 -ggdb \
  -I../../../include \
  -I../../../deps/sqlite3/sqlite3 \
  -I/opt/homebrew/Cellar/openssl@3/3.5.1/include \
  -o test_okta_ldap_auth-t \
  test_okta_ldap_auth-t.cpp \
  sqlite3db_stub.cpp \
  ../../../deps/sqlite3/sqlite3/sqlite3.o \
  -lpthread \
  -L/opt/homebrew/Cellar/openssl@3/3.5.1/lib -lssl -lcrypto

./test_okta_ldap_auth-t ../../../binaries/proxysql_okta_ldap_auth.dylib
```

## Troubleshooting

| Symptom | Check |
|---------|-------|
| "okta_url not configured" in stderr | Set `ldap-okta_url` and `LOAD LDAP VARIABLES TO RUNTIME` |
| LDAP bind timeout | Increase `ldap-okta_bind_timeout_ms`; verify network path to Okta |
| All users rejected | Check `ldap-okta_enabled=true`; verify DN format matches Okta's user DN structure |
| "Connection refused" after disabling in Okta | Working as intended — wait for cache to expire or set `okta_cache_ttl=0` |
| Backend auth failure | Ensure `okta_default_backend_user` exists in `mysql_users` with `backend=1` |
