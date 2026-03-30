#!/usr/bin/env bash
#
# System test for ProxySQL Okta LDAP Authentication
#
# Validates:
#   1. MySQL backend is healthy and accessible
#   2. PostgreSQL backend is healthy and accessible
#   3. ProxySQL standard MySQL frontend auth works
#   4. ProxySQL standard PgSQL frontend auth works
#   5. ProxySQL Okta LDAP authentication works (via LDAP bind to Okta)
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — override via environment if needed
# ---------------------------------------------------------------------------
PROXYSQL_HOST="${PROXYSQL_HOST:-127.0.0.1}"
PROXYSQL_ADMIN_PORT="${PROXYSQL_ADMIN_PORT:-16032}"
PROXYSQL_MYSQL_PORT="${PROXYSQL_MYSQL_PORT:-16033}"
PROXYSQL_PGSQL_PORT="${PROXYSQL_PGSQL_PORT:-16133}"

MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-13306}"

PGSQL_HOST="${PGSQL_HOST:-127.0.0.1}"
PGSQL_PORT="${PGSQL_PORT:-15432}"

# Standard credentials (defined in docker-compose / init scripts)
STD_MYSQL_USER="testuser"
STD_MYSQL_PASS="testpass"
STD_PGSQL_USER="testuser"
STD_PGSQL_PASS="testpass"
ADMIN_USER="${ADMIN_USER:-radmin}"
ADMIN_PASS="${ADMIN_PASS:-radmin}"

# Okta LDAP test credentials
OKTA_USER="${OKTA_USER:-tanapoln+test@lmwn.com}"
OKTA_PASS="${OKTA_PASS:-P@ssw0rd}"

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "  PASS: $1"
}

fail() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  FAIL: $1"
    if [[ -n "${2:-}" ]]; then
        echo "        $2"
    fi
}

section() {
    echo ""
    echo "======================================================================"
    echo "  $1"
    echo "======================================================================"
}

# ---------------------------------------------------------------------------
# Helper: wait for a TCP port to accept connections
# ---------------------------------------------------------------------------
wait_for_port() {
    local host="$1" port="$2" label="$3" max_wait="${4:-60}"
    echo -n "Waiting for ${label} (${host}:${port}) ..."
    local elapsed=0
    while ! (echo > /dev/tcp/"$host"/"$port") 2>/dev/null; do
        sleep 1
        elapsed=$((elapsed + 1))
        if [[ $elapsed -ge $max_wait ]]; then
            echo " TIMEOUT after ${max_wait}s"
            return 1
        fi
    done
    echo " ready (${elapsed}s)"
}

# ---------------------------------------------------------------------------
# Helper: run mysql query, return output or fail
# ---------------------------------------------------------------------------
run_mysql() {
    local host="$1" port="$2" user="$3" pass="$4" db="${5:-}" query="$6"
    local extra_flags="${7:-}"
    local db_flag=""
    if [[ -n "$db" ]]; then
        db_flag="-D $db"
    fi
    local output rc
    output=$(mysql -h "$host" -P "$port" -u "$user" -p"$pass" $db_flag \
        --connect-timeout=30 $extra_flags -N -B -e "$query" 2>&1) || rc=$?
    # Filter out mysql warning about password on command line
    echo "$output" | grep -v 'mysql: \[Warning\]' || true
    return ${rc:-0}
}

# ---------------------------------------------------------------------------
# Helper: run psql query, return output or fail
# ---------------------------------------------------------------------------
run_psql() {
    local host="$1" port="$2" user="$3" pass="$4" db="$5" query="$6"
    PGPASSWORD="$pass" psql -h "$host" -p "$port" -U "$user" -d "$db" \
        -t -A -c "$query" 2>&1
}

# ---------------------------------------------------------------------------
section "Phase 0: Wait for services"
# ---------------------------------------------------------------------------
wait_for_port "$MYSQL_HOST" "$MYSQL_PORT" "MySQL backend" 120
wait_for_port "$PGSQL_HOST" "$PGSQL_PORT" "PostgreSQL backend" 120
wait_for_port "$PROXYSQL_HOST" "$PROXYSQL_ADMIN_PORT" "ProxySQL admin" 120
wait_for_port "$PROXYSQL_HOST" "$PROXYSQL_MYSQL_PORT" "ProxySQL MySQL proxy" 120
wait_for_port "$PROXYSQL_HOST" "$PROXYSQL_PGSQL_PORT" "ProxySQL PgSQL proxy" 120

# Give ProxySQL a moment to finish internal initialization
sleep 3

# ---------------------------------------------------------------------------
section "Phase 1: MySQL backend direct connectivity"
# ---------------------------------------------------------------------------
result=$(run_mysql "$MYSQL_HOST" "$MYSQL_PORT" "$STD_MYSQL_USER" "$STD_MYSQL_PASS" "testdb" "SELECT name FROM test_table LIMIT 1")
if [[ "$result" == *"mysql_test_row"* ]]; then
    pass "MySQL backend: can query test_table"
else
    fail "MySQL backend: unexpected result" "$result"
fi

result=$(run_mysql "$MYSQL_HOST" "$MYSQL_PORT" "okta_shared" "okta_backend_pass" "testdb" "SELECT 1")
if [[ "$result" == *"1"* ]]; then
    pass "MySQL backend: okta_shared user can connect"
else
    fail "MySQL backend: okta_shared user failed" "$result"
fi

# ---------------------------------------------------------------------------
section "Phase 2: PostgreSQL backend direct connectivity"
# ---------------------------------------------------------------------------
result=$(run_psql "$PGSQL_HOST" "$PGSQL_PORT" "$STD_PGSQL_USER" "$STD_PGSQL_PASS" "testdb" "SELECT name FROM test_table LIMIT 1")
if [[ "$result" == *"pgsql_test_row"* ]]; then
    pass "PgSQL backend: can query test_table"
else
    fail "PgSQL backend: unexpected result" "$result"
fi

# ---------------------------------------------------------------------------
section "Phase 3: ProxySQL admin interface"
# ---------------------------------------------------------------------------
result=$(run_mysql "$PROXYSQL_HOST" "$PROXYSQL_ADMIN_PORT" "$ADMIN_USER" "$ADMIN_PASS" "" "SELECT 1")
if [[ "$result" == *"1"* ]]; then
    pass "ProxySQL admin: can connect"
else
    fail "ProxySQL admin: connection failed" "$result"
fi

# Configure LDAP variables via admin interface
echo "  Configuring LDAP variables via admin..."
ldap_ok=true
run_mysql "$PROXYSQL_HOST" "$PROXYSQL_ADMIN_PORT" "$ADMIN_USER" "$ADMIN_PASS" "" \
    "SET ldap_okta_url='ldaps://trial-1120298.ldap.okta.com'" >/dev/null 2>&1 || ldap_ok=false
run_mysql "$PROXYSQL_HOST" "$PROXYSQL_ADMIN_PORT" "$ADMIN_USER" "$ADMIN_PASS" "" \
    "SET ldap_okta_base_dn='dc=trial-1120298,dc=okta,dc=com'" >/dev/null 2>&1 || ldap_ok=false
run_mysql "$PROXYSQL_HOST" "$PROXYSQL_ADMIN_PORT" "$ADMIN_USER" "$ADMIN_PASS" "" \
    "SET ldap_okta_cache_ttl=3600" >/dev/null 2>&1 || ldap_ok=false
run_mysql "$PROXYSQL_HOST" "$PROXYSQL_ADMIN_PORT" "$ADMIN_USER" "$ADMIN_PASS" "" \
    "SET ldap_okta_bind_timeout_ms=10000" >/dev/null 2>&1 || ldap_ok=false
run_mysql "$PROXYSQL_HOST" "$PROXYSQL_ADMIN_PORT" "$ADMIN_USER" "$ADMIN_PASS" "" \
    "SET ldap_okta_enabled=true" >/dev/null 2>&1 || ldap_ok=false
run_mysql "$PROXYSQL_HOST" "$PROXYSQL_ADMIN_PORT" "$ADMIN_USER" "$ADMIN_PASS" "" \
    "SET ldap_okta_default_backend_user='okta_shared'" >/dev/null 2>&1 || ldap_ok=false
run_mysql "$PROXYSQL_HOST" "$PROXYSQL_ADMIN_PORT" "$ADMIN_USER" "$ADMIN_PASS" "" \
    "SET ldap_okta_default_hostgroup=0" >/dev/null 2>&1 || ldap_ok=false
run_mysql "$PROXYSQL_HOST" "$PROXYSQL_ADMIN_PORT" "$ADMIN_USER" "$ADMIN_PASS" "" \
    "SET ldap_okta_default_max_connections=1000" >/dev/null 2>&1 || ldap_ok=false
run_mysql "$PROXYSQL_HOST" "$PROXYSQL_ADMIN_PORT" "$ADMIN_USER" "$ADMIN_PASS" "" \
    "LOAD LDAP VARIABLES TO RUNTIME" >/dev/null 2>&1 || ldap_ok=false
run_mysql "$PROXYSQL_HOST" "$PROXYSQL_ADMIN_PORT" "$ADMIN_USER" "$ADMIN_PASS" "" \
    "SAVE LDAP VARIABLES TO DISK" >/dev/null 2>&1 || ldap_ok=false
if [[ "$ldap_ok" == "true" ]]; then
    pass "ProxySQL admin: LDAP variables configured"
else
    fail "ProxySQL admin: failed to configure LDAP variables"
fi

# Verify LDAP variables are set
result=$(run_mysql "$PROXYSQL_HOST" "$PROXYSQL_ADMIN_PORT" "$ADMIN_USER" "$ADMIN_PASS" "" \
    "SELECT variable_value FROM global_variables WHERE variable_name='ldap_okta_url'")
if [[ "$result" == *"trial-1120298.ldap.okta.com"* ]]; then
    pass "ProxySQL admin: LDAP okta_url confirmed"
else
    fail "ProxySQL admin: LDAP okta_url not set correctly" "$result"
fi

result=$(run_mysql "$PROXYSQL_HOST" "$PROXYSQL_ADMIN_PORT" "$ADMIN_USER" "$ADMIN_PASS" "" \
    "SELECT variable_value FROM global_variables WHERE variable_name='ldap_okta_enabled'")
if [[ "$result" == *"true"* ]]; then
    pass "ProxySQL admin: LDAP enabled confirmed"
else
    fail "ProxySQL admin: LDAP not enabled" "$result"
fi

# Verify base_dn is stored correctly (value contains '=' signs that must be preserved)
result=$(run_mysql "$PROXYSQL_HOST" "$PROXYSQL_ADMIN_PORT" "$ADMIN_USER" "$ADMIN_PASS" "" \
    "SELECT variable_value FROM global_variables WHERE variable_name='ldap_okta_base_dn'")
if [[ "$result" == "dc=trial-1120298,dc=okta,dc=com" ]]; then
    pass "ProxySQL admin: LDAP base_dn preserved (SET with '=' in value)"
else
    fail "ProxySQL admin: LDAP base_dn corrupted or missing" "$result"
fi

# Verify MySQL backend server is registered
result=$(run_mysql "$PROXYSQL_HOST" "$PROXYSQL_ADMIN_PORT" "$ADMIN_USER" "$ADMIN_PASS" "" \
    "SELECT hostname FROM mysql_servers")
if [[ "$result" == *"mysql"* ]]; then
    pass "ProxySQL admin: MySQL backend server registered"
else
    fail "ProxySQL admin: MySQL backend server not found" "$result"
fi

# Verify PgSQL backend server is registered
result=$(run_mysql "$PROXYSQL_HOST" "$PROXYSQL_ADMIN_PORT" "$ADMIN_USER" "$ADMIN_PASS" "" \
    "SELECT hostname FROM pgsql_servers")
if [[ "$result" == *"pgsql"* ]]; then
    pass "ProxySQL admin: PgSQL backend server registered"
else
    fail "ProxySQL admin: PgSQL backend server not found" "$result"
fi

# ---------------------------------------------------------------------------
section "Phase 4: ProxySQL standard MySQL frontend authentication"
# ---------------------------------------------------------------------------
result=$(run_mysql "$PROXYSQL_HOST" "$PROXYSQL_MYSQL_PORT" "$STD_MYSQL_USER" "$STD_MYSQL_PASS" "testdb" "SELECT name FROM test_table LIMIT 1")
if [[ "$result" == *"mysql_test_row"* ]]; then
    pass "ProxySQL MySQL proxy: standard auth + query works"
else
    fail "ProxySQL MySQL proxy: standard auth failed" "$result"
fi

# ---------------------------------------------------------------------------
section "Phase 5: ProxySQL standard PgSQL frontend authentication"
# ---------------------------------------------------------------------------
result=$(run_psql "$PROXYSQL_HOST" "$PROXYSQL_PGSQL_PORT" "$STD_PGSQL_USER" "$STD_PGSQL_PASS" "testdb" "SELECT name FROM test_table LIMIT 1")
if [[ "$result" == *"pgsql_test_row"* ]]; then
    pass "ProxySQL PgSQL proxy: standard auth + query works"
else
    fail "ProxySQL PgSQL proxy: standard auth failed" "$result"
fi

# ---------------------------------------------------------------------------
section "Phase 6: ProxySQL Okta LDAP authentication"
# ---------------------------------------------------------------------------

# LDAP auth requires cleartext password plugin
CLEARTEXT="--enable-cleartext-plugin"

# Test 1: LDAP auth should succeed with valid Okta credentials
echo "  Attempting LDAP auth with Okta user: ${OKTA_USER}"
result=$(run_mysql "$PROXYSQL_HOST" "$PROXYSQL_MYSQL_PORT" "$OKTA_USER" "$OKTA_PASS" "" "SELECT 1" "$CLEARTEXT" 2>&1 || true)
if [[ "$result" == "1" ]]; then
    pass "Okta LDAP auth: valid user can authenticate and query"
else
    fail "Okta LDAP auth: valid user authentication failed" "$result"
fi

# Test 2: Second connection should hit cache (faster)
result=$(run_mysql "$PROXYSQL_HOST" "$PROXYSQL_MYSQL_PORT" "$OKTA_USER" "$OKTA_PASS" "" "SELECT 1" "$CLEARTEXT" 2>&1 || true)
if [[ "$result" == "1" ]]; then
    pass "Okta LDAP auth: cached auth (second connection) works"
elif [[ "$result" == *"Access denied"* ]]; then
    fail "Okta LDAP auth: cached auth failed (still denied)" "$result"
else
    fail "Okta LDAP auth: cached auth failed" "$result"
fi

# Test 3: Check LDAP stats show activity
result=$(run_mysql "$PROXYSQL_HOST" "$PROXYSQL_ADMIN_PORT" "$ADMIN_USER" "$ADMIN_PASS" "" \
    "SELECT Variable_Value FROM stats_mysql_global WHERE Variable_Name='Okta_LDAP_ldap_bind_success'" || true)
result=$(echo "$result" | tr -d '[:space:]')
if [[ -n "$result" ]] && [[ "$result" != "0" ]]; then
    pass "Okta LDAP auth: stats show bind success count=$result"
else
    fail "Okta LDAP auth: stats show no bind success (count=$result)"
fi

# Test 4: Check cache hit stats
result=$(run_mysql "$PROXYSQL_HOST" "$PROXYSQL_ADMIN_PORT" "$ADMIN_USER" "$ADMIN_PASS" "" \
    "SELECT Variable_Value FROM stats_mysql_global WHERE Variable_Name='Okta_LDAP_cache_hits'" || true)
result=$(echo "$result" | tr -d '[:space:]')
if [[ -n "$result" ]] && [[ "$result" != "0" ]]; then
    pass "Okta LDAP auth: cache hits detected count=$result"
else
    echo "  INFO: cache hits = ${result:-0} (expected 0 if auth failed or connections were sequential)"
fi

# Test 5: LDAP auth should fail with wrong password
result=$(run_mysql "$PROXYSQL_HOST" "$PROXYSQL_MYSQL_PORT" "$OKTA_USER" "WrongPassword123!" "" "SELECT 1" "$CLEARTEXT" 2>&1 || true)
if [[ "$result" == *"Access denied"* ]] || [[ "$result" == *"ERROR"* ]]; then
    pass "Okta LDAP auth: wrong password correctly rejected"
else
    fail "Okta LDAP auth: wrong password was NOT rejected" "$result"
fi

# Test 6: LDAP auth should fail with non-existent user
result=$(run_mysql "$PROXYSQL_HOST" "$PROXYSQL_MYSQL_PORT" "nonexistent@example.com" "anypass" "" "SELECT 1" "$CLEARTEXT" 2>&1 || true)
if [[ "$result" == *"Access denied"* ]] || [[ "$result" == *"ERROR"* ]]; then
    pass "Okta LDAP auth: non-existent user correctly rejected"
else
    fail "Okta LDAP auth: non-existent user was NOT rejected" "$result"
fi

# Test 7: Check bind failure stats
result=$(run_mysql "$PROXYSQL_HOST" "$PROXYSQL_ADMIN_PORT" "$ADMIN_USER" "$ADMIN_PASS" "" \
    "SELECT Variable_Value FROM stats_mysql_global WHERE Variable_Name='Okta_LDAP_ldap_bind_failure'" || true)
result=$(echo "$result" | tr -d '[:space:]')
if [[ -n "$result" ]] && [[ "$result" != "0" ]]; then
    pass "Okta LDAP auth: stats show bind failures count=$result"
else
    fail "Okta LDAP auth: expected bind failure stats (count=$result)"
fi

# ---------------------------------------------------------------------------
section "Results"
# ---------------------------------------------------------------------------
echo ""
echo "  Total:  $TESTS_RUN"
echo "  Passed: $TESTS_PASSED"
echo "  Failed: $TESTS_FAILED"
echo ""

if [[ $TESTS_FAILED -gt 0 ]]; then
    echo "SOME TESTS FAILED"
    exit 1
else
    echo "ALL TESTS PASSED"
    exit 0
fi
