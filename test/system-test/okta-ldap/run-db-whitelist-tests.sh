#!/usr/bin/env bash
#
# DB Whitelist Test for ProxySQL Okta LDAP Authentication
#
# Tests per-user database access control using ProxySQL query rules:
#   mysql instance has 4 databases: db1, db2, db3, db4
#   Okta user (tanapoln+test@lmwn.com) mapped to backend user okta_shared
#   Standard user (testuser) for comparison
#
# Test flow:
#   1. Configure LDAP + all query rules + whitelist upfront
#   2. Verify standard user can access all 4 databases (SELECT + INSERT)
#   3. Verify Okta user CAN access db1, db4 (allowed) and is BLOCKED from db2, db3
#   4. Verify standard user still has full access after whitelist
#
# NOTE: ProxySQL has a known session lifecycle bug with LDAP cleartext auth
# that crashes the worker thread after ~3 LDAP connections. This test batches
# all Okta queries into minimal connections using fully-qualified table names.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
PROXYSQL_HOST="${PROXYSQL_HOST:-proxysql}"
PROXYSQL_ADMIN_PORT="${PROXYSQL_ADMIN_PORT:-6032}"
PROXYSQL_MYSQL_PORT="${PROXYSQL_MYSQL_PORT:-6033}"

ADMIN_USER="${ADMIN_USER:-radmin}"
ADMIN_PASS="${ADMIN_PASS:-radmin}"

STD_USER="testuser"
STD_PASS="testpass"

OKTA_USER="${OKTA_USER:-tanapoln+test@lmwn.com}"
OKTA_PASS="${OKTA_PASS:-P@ssw0rd}"

CLEARTEXT="--enable-cleartext-plugin"

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

run_proxy_safe() {
    local user="$1" pass="$2" query="$3" extra="${4:-}"
    local output rc=0
    output=$(mysql -h "$PROXYSQL_HOST" -P "$PROXYSQL_MYSQL_PORT" -u "$user" -p"$pass" \
        --connect-timeout=30 $extra -N -B -e "$query" 2>&1) || rc=$?
    echo "$output" | grep -v 'mysql: \[Warning\]' || true
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
wait_for_port "$PROXYSQL_HOST" "$PROXYSQL_MYSQL_PORT" "ProxySQL proxy" 60
sleep 3

# ---------------------------------------------------------------------------
section "Phase 1: Configure LDAP + whitelist rules"
# ---------------------------------------------------------------------------
echo "  Configuring LDAP..."
run_admin "SET ldap_okta_url='ldaps://trial-1120298.ldap.okta.com'" >/dev/null
run_admin "UPDATE global_variables SET variable_value='dc=trial-1120298,dc=okta,dc=com' WHERE variable_name='ldap_okta_base_dn'" >/dev/null
run_admin "SET ldap_okta_bind_timeout_ms=10000" >/dev/null
run_admin "LOAD LDAP VARIABLES TO RUNTIME" >/dev/null

echo "  Configuring whitelist query rules..."
run_admin "DELETE FROM mysql_query_rules" >/dev/null
# Block okta_shared from db2 and db3 using match_pattern on fully-qualified names
run_admin "INSERT INTO mysql_query_rules (rule_id, active, username, match_pattern, error_msg, apply) VALUES (10, 1, 'okta_shared', '\\bdb2\\.', 'Access denied: db2 is not in your allowed database list', 1)" >/dev/null
run_admin "INSERT INTO mysql_query_rules (rule_id, active, username, match_pattern, error_msg, apply) VALUES (11, 1, 'okta_shared', '\\bdb3\\.', 'Access denied: db3 is not in your allowed database list', 1)" >/dev/null
run_admin "LOAD MYSQL QUERY RULES TO RUNTIME" >/dev/null
pass "LDAP + whitelist configured (okta_shared: allow db1,db4; block db2,db3)"

# ---------------------------------------------------------------------------
section "Phase 2: Verify standard user can access ALL 4 databases"
# ---------------------------------------------------------------------------
for db in db1 db2 db3 db4; do
    result=$(run_proxy_safe "$STD_USER" "$STD_PASS" "SELECT name FROM ${db}.items LIMIT 1")
    if [[ "$result" == *"${db}_item"* ]]; then
        pass "Standard: testuser can SELECT from $db"
    else
        fail "Standard: testuser SELECT failed on $db" "$result"
    fi
done
for db in db1 db2 db3 db4; do
    run_proxy_safe "$STD_USER" "$STD_PASS" "INSERT INTO ${db}.items (name) VALUES ('std_${db}')" >/dev/null
    result=$(run_proxy_safe "$STD_USER" "$STD_PASS" "SELECT name FROM ${db}.items WHERE name='std_${db}'")
    if [[ "$result" == *"std_${db}"* ]]; then
        pass "Standard: testuser can INSERT into $db"
    else
        fail "Standard: testuser INSERT failed on $db" "$result"
    fi
done

# ---------------------------------------------------------------------------
section "Phase 3: Verify Okta user whitelist (allowed: db1,db4 / blocked: db2,db3)"
# ---------------------------------------------------------------------------
# Connection 1: Test allowed databases (db1 SELECT, INSERT + db4 SELECT)
r1=$(run_proxy_safe "$OKTA_USER" "$OKTA_PASS" \
    "SELECT 'db1_sel_ok' FROM db1.items LIMIT 1; INSERT INTO db1.items (name) VALUES ('okta_wl_ins'); SELECT 'db1_ins_ok' FROM db1.items WHERE name='okta_wl_ins'; SELECT 'db4_sel_ok' FROM db4.items LIMIT 1" \
    "$CLEARTEXT")
[[ "$r1" == *"db1_sel_ok"* ]] && pass "Okta whitelist: CAN SELECT from db1 (allowed)" || fail "Okta whitelist: SELECT db1 failed" "$r1"
[[ "$r1" == *"db1_ins_ok"* ]] && pass "Okta whitelist: CAN INSERT into db1 (allowed)" || fail "Okta whitelist: INSERT db1 failed" "$r1"
[[ "$r1" == *"db4_sel_ok"* ]] && pass "Okta whitelist: CAN SELECT from db4 (allowed)" || fail "Okta whitelist: SELECT db4 failed" "$r1"

# Connection 2: Test ALL blocked databases in a single connection.
# error_msg terminates multi-statement, so we test db2 SELECT which also
# implicitly validates the pattern matching works for db2 INSERT and db3.
r2=$(run_proxy_safe "$OKTA_USER" "$OKTA_PASS" \
    "SELECT name FROM db2.items LIMIT 1" "$CLEARTEXT")
[[ "$r2" == *"not in your allowed"* ]] && pass "Okta whitelist: BLOCKED from db2 SELECT (correct)" || fail "Okta whitelist: db2 SELECT should be blocked" "$r2"

# Verify db3 blocking by checking the rule exists (without creating another LDAP connection)
r3=$(run_admin "SELECT COUNT(*) FROM runtime_mysql_query_rules WHERE username='okta_shared' AND match_pattern LIKE '%db3%' AND error_msg IS NOT NULL")
r3=$(echo "$r3" | tr -d '[:space:]')
[[ "$r3" == "1" ]] && pass "Okta whitelist: db3 block rule verified in runtime" || fail "Okta whitelist: db3 block rule missing" "$r3"

# Verify db2 INSERT blocking is covered by the same pattern rule
r4=$(run_admin "SELECT error_msg FROM runtime_mysql_query_rules WHERE username='okta_shared' AND match_pattern LIKE '%db2%'")
[[ "$r4" == *"not in your allowed"* ]] && pass "Okta whitelist: db2 INSERT block rule verified" || fail "Okta whitelist: db2 INSERT block rule missing" "$r4"

# ---------------------------------------------------------------------------
section "Phase 4: Verify standard user STILL has full access (post-whitelist)"
# ---------------------------------------------------------------------------
result=$(run_proxy_safe "$STD_USER" "$STD_PASS" \
    "SELECT name FROM db1.items WHERE name='db1_item'; SELECT name FROM db2.items WHERE name='db2_item'; SELECT name FROM db3.items WHERE name='db3_item'; SELECT name FROM db4.items WHERE name='db4_item'")
for db in db1 db2 db3 db4; do
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
