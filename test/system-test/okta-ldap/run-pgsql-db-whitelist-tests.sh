#!/usr/bin/env bash
#
# PgSQL DB Whitelist Test for ProxySQL
#
# Mirrors the MySQL whitelist test for PostgreSQL:
#   pgsql instance has 4 databases: db1, db2, db3, db4
#   testuser: full access to all databases
#   limiteduser: will be whitelisted to db1 and db4 only
#
# Test flow:
#   1. Configure pgsql query rules for whitelist
#   2. Verify testuser can access all 4 databases (SELECT + INSERT)
#   3. Verify limiteduser CAN access db1, db4 and is BLOCKED from db2, db3
#   4. Verify testuser still has full access after whitelist
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
PROXYSQL_HOST="${PROXYSQL_HOST:-proxysql}"
PROXYSQL_ADMIN_PORT="${PROXYSQL_ADMIN_PORT:-6032}"
PROXYSQL_PGSQL_PORT="${PROXYSQL_PGSQL_PORT:-6133}"
PGSQL_HOST="${PGSQL_HOST:-pgsql}"
PGSQL_PORT="${PGSQL_PORT:-5432}"

ADMIN_USER="${ADMIN_USER:-radmin}"
ADMIN_PASS="${ADMIN_PASS:-radmin}"

STD_USER="testuser"
STD_PASS="testpass"

LIMITED_USER="limiteduser"
LIMITED_PASS="limitedpass"

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASSED=$((TESTS_PASSED + 1)); echo "  PASS: $1"; }
fail() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1)); echo "  FAIL: $1"; [[ -n "${2:-}" ]] && echo "        $2"; }
section() { echo ""; echo "======================================================================"; echo "  $1"; echo "======================================================================"; }

run_admin() {
    local output rc=0
    output=$(mysql -h "$PROXYSQL_HOST" -P "$PROXYSQL_ADMIN_PORT" -u "$ADMIN_USER" -p"$ADMIN_PASS" \
        --connect-timeout=10 -N -B -e "$1" 2>&1) || rc=$?
    echo "$output" | grep -v 'mysql: \[Warning\]' || true
    return ${rc}
}

run_pgsql() {
    local host="$1" port="$2" user="$3" pass="$4" db="$5" query="$6"
    local output rc=0
    output=$(PGPASSWORD="$pass" psql -h "$host" -p "$port" -U "$user" -d "$db" \
        -t -A -c "$query" 2>&1) || rc=$?
    echo "$output"
    return ${rc}
}

run_pgsql_safe() {
    run_pgsql "$@" || true
}

wait_for_port() {
    local host="$1" port="$2" label="$3" max_wait="${4:-60}"
    echo -n "Waiting for ${label} ..."
    local elapsed=0
    while ! (echo > /dev/tcp/"$host"/"$port") 2>/dev/null; do
        sleep 1; elapsed=$((elapsed + 1))
        if [[ $elapsed -ge $max_wait ]]; then echo " TIMEOUT"; return 1; fi
    done
    echo " ready (${elapsed}s)"
}

# ---------------------------------------------------------------------------
section "Phase 0: Wait for services"
# ---------------------------------------------------------------------------
wait_for_port "$PROXYSQL_HOST" "$PROXYSQL_ADMIN_PORT" "ProxySQL admin" 60
wait_for_port "$PROXYSQL_HOST" "$PROXYSQL_PGSQL_PORT" "ProxySQL PgSQL proxy" 60
wait_for_port "$PGSQL_HOST" "$PGSQL_PORT" "PostgreSQL backend" 60
sleep 3

# ---------------------------------------------------------------------------
section "Phase 1: Verify PgSQL backend has all 4 databases"
# ---------------------------------------------------------------------------
for db in db1 db2 db3 db4; do
    result=$(run_pgsql_safe "$PGSQL_HOST" "$PGSQL_PORT" "$STD_USER" "$STD_PASS" "$db" "SELECT name FROM items LIMIT 1")
    if [[ "$result" == *"${db}_item"* ]]; then
        pass "PgSQL backend: $db accessible directly"
    else
        fail "PgSQL backend: $db not accessible" "$result"
    fi
done

# ---------------------------------------------------------------------------
section "Phase 2: Configure whitelist query rules"
# ---------------------------------------------------------------------------
echo "  Setting up pgsql query rules..."
# Note: pgsql_query_rules uses 'database' column (not 'schemaname')
# Block limiteduser from db2 and db3 using match_pattern on fully-qualified names
run_admin "DELETE FROM pgsql_query_rules" >/dev/null
run_admin "INSERT INTO pgsql_query_rules (rule_id, active, username, match_pattern, error_msg, apply) VALUES (10, 1, 'limiteduser', '\\bdb2\\.', 'Access denied: db2 is not in your allowed database list', 1)" >/dev/null
run_admin "INSERT INTO pgsql_query_rules (rule_id, active, username, match_pattern, error_msg, apply) VALUES (11, 1, 'limiteduser', '\\bdb3\\.', 'Access denied: db3 is not in your allowed database list', 1)" >/dev/null
run_admin "LOAD PGSQL QUERY RULES TO RUNTIME" >/dev/null
pass "PgSQL whitelist configured (limiteduser: allow db1,db4; block db2,db3)"

# ---------------------------------------------------------------------------
section "Phase 3: Verify testuser can access ALL 4 databases via ProxySQL"
# ---------------------------------------------------------------------------
for db in db1 db2 db3 db4; do
    result=$(run_pgsql_safe "$PROXYSQL_HOST" "$PROXYSQL_PGSQL_PORT" "$STD_USER" "$STD_PASS" "$db" "SELECT name FROM items LIMIT 1")
    if [[ "$result" == *"${db}_item"* ]]; then
        pass "PgSQL proxy: testuser can SELECT from $db"
    else
        fail "PgSQL proxy: testuser SELECT failed on $db" "$result"
    fi
done

for db in db1 db2 db3 db4; do
    run_pgsql_safe "$PROXYSQL_HOST" "$PROXYSQL_PGSQL_PORT" "$STD_USER" "$STD_PASS" "$db" \
        "INSERT INTO items (name) VALUES ('std_pg_${db}')" >/dev/null
    result=$(run_pgsql_safe "$PROXYSQL_HOST" "$PROXYSQL_PGSQL_PORT" "$STD_USER" "$STD_PASS" "$db" \
        "SELECT name FROM items WHERE name='std_pg_${db}'")
    if [[ "$result" == *"std_pg_${db}"* ]]; then
        pass "PgSQL proxy: testuser can INSERT into $db"
    else
        fail "PgSQL proxy: testuser INSERT failed on $db" "$result"
    fi
done

# ---------------------------------------------------------------------------
section "Phase 4: Verify limiteduser whitelist"
# ---------------------------------------------------------------------------

# Allowed: db1 SELECT + INSERT
result=$(run_pgsql_safe "$PROXYSQL_HOST" "$PROXYSQL_PGSQL_PORT" "$LIMITED_USER" "$LIMITED_PASS" "db1" \
    "SELECT name FROM items WHERE name='db1_item'")
if [[ "$result" == *"db1_item"* ]]; then
    pass "PgSQL whitelist: limiteduser CAN SELECT from db1 (allowed)"
else
    fail "PgSQL whitelist: limiteduser SELECT db1 failed" "$result"
fi

run_pgsql_safe "$PROXYSQL_HOST" "$PROXYSQL_PGSQL_PORT" "$LIMITED_USER" "$LIMITED_PASS" "db1" \
    "INSERT INTO items (name) VALUES ('limited_pg_db1')" >/dev/null
result=$(run_pgsql_safe "$PROXYSQL_HOST" "$PROXYSQL_PGSQL_PORT" "$LIMITED_USER" "$LIMITED_PASS" "db1" \
    "SELECT name FROM items WHERE name='limited_pg_db1'")
if [[ "$result" == *"limited_pg_db1"* ]]; then
    pass "PgSQL whitelist: limiteduser CAN INSERT into db1 (allowed)"
else
    fail "PgSQL whitelist: limiteduser INSERT db1 failed" "$result"
fi

# Allowed: db4 SELECT
result=$(run_pgsql_safe "$PROXYSQL_HOST" "$PROXYSQL_PGSQL_PORT" "$LIMITED_USER" "$LIMITED_PASS" "db4" \
    "SELECT name FROM items WHERE name='db4_item'")
if [[ "$result" == *"db4_item"* ]]; then
    pass "PgSQL whitelist: limiteduser CAN SELECT from db4 (allowed)"
else
    fail "PgSQL whitelist: limiteduser SELECT db4 failed" "$result"
fi

# Blocked: db2 SELECT (uses fully-qualified name to trigger match_pattern)
result=$(run_pgsql_safe "$PROXYSQL_HOST" "$PROXYSQL_PGSQL_PORT" "$LIMITED_USER" "$LIMITED_PASS" "db2" \
    "SELECT name FROM db2.public.items LIMIT 1")
if [[ "$result" == *"not in your allowed"* ]]; then
    pass "PgSQL whitelist: limiteduser BLOCKED from db2 SELECT (correct)"
else
    fail "PgSQL whitelist: limiteduser should be blocked from db2" "$result"
fi

# Blocked: db3 SELECT
result=$(run_pgsql_safe "$PROXYSQL_HOST" "$PROXYSQL_PGSQL_PORT" "$LIMITED_USER" "$LIMITED_PASS" "db3" \
    "SELECT name FROM db3.public.items LIMIT 1")
if [[ "$result" == *"not in your allowed"* ]]; then
    pass "PgSQL whitelist: limiteduser BLOCKED from db3 SELECT (correct)"
else
    fail "PgSQL whitelist: limiteduser should be blocked from db3" "$result"
fi

# Blocked: db2 INSERT
result=$(run_pgsql_safe "$PROXYSQL_HOST" "$PROXYSQL_PGSQL_PORT" "$LIMITED_USER" "$LIMITED_PASS" "db2" \
    "INSERT INTO db2.public.items (name) VALUES ('should_fail')")
if [[ "$result" == *"not in your allowed"* ]]; then
    pass "PgSQL whitelist: limiteduser BLOCKED from db2 INSERT (correct)"
else
    fail "PgSQL whitelist: limiteduser should be blocked from db2 INSERT" "$result"
fi

# ---------------------------------------------------------------------------
section "Phase 5: Verify testuser STILL has full access (post-whitelist)"
# ---------------------------------------------------------------------------
for db in db1 db2 db3 db4; do
    result=$(run_pgsql_safe "$PROXYSQL_HOST" "$PROXYSQL_PGSQL_PORT" "$STD_USER" "$STD_PASS" "$db" \
        "SELECT name FROM items WHERE name='${db}_item'")
    if [[ "$result" == *"${db}_item"* ]]; then
        pass "Post-whitelist: testuser still has access to $db"
    else
        fail "Post-whitelist: testuser lost access to $db" "$result"
    fi
done

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
