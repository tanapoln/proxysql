#!/usr/bin/env bash
#
# Hermetic regression tests for the ProxySQL Okta LDAP plugin.
#
# Unlike run-tests.sh (which binds against a live external Okta org), this suite
# uses a LOCAL OpenLDAP container as the LDAP server, so it is self-contained and
# can run in CI. Each phase targets a specific bug that the previous test layers
# could not catch, with a comment explaining what would happen on the buggy code:
#
#   Phase 2  baseline: local LDAP bind works via MySQL and PgSQL
#   Phase 3  SQL-injection / escaping of the username in the mapping lookup
#   Phase 4  exact mapping must beat the '@everyone' catch-all regardless of priority
#   Phase 5  per-protocol mapping isolation at the runtime-table level
#   Phase 6  PgSQL frontend connection counter must be decremented on disconnect
#   Phase 7  mapping to a non-existent backend is rejected cleanly (no crash)
#
set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
PROXYSQL_HOST="${PROXYSQL_HOST:-proxysql}"
PROXYSQL_ADMIN_PORT="${PROXYSQL_ADMIN_PORT:-6032}"
PROXYSQL_MYSQL_PORT="${PROXYSQL_MYSQL_PORT:-6033}"
PROXYSQL_PGSQL_PORT="${PROXYSQL_PGSQL_PORT:-6133}"
ADMIN_USER="${ADMIN_USER:-radmin}"
ADMIN_PASS="${ADMIN_PASS:-radmin}"

# Local LDAP server (osixia/openldap), seeded from ldap/bootstrap.ldif
LDAP_URL="${LDAP_URL:-ldap://openldap:389}"
LDAP_BASE_DN="${LDAP_BASE_DN:-dc=example,dc=com}"
LDAP_DN_FORMAT="${LDAP_DN_FORMAT:-uid=%s,ou=users,%s}"

# Seeded LDAP users (must match ldap/bootstrap.ldif)
ALICE="alice@example.com";     ALICE_PASS="alicepass"
BOB="bob@example.com";         BOB_PASS="bobpass"
OBRIEN="o'brien@example.com";  OBRIEN_PASS="obrienpass"
CAROL="carol@example.com";     CAROL_PASS="carolpass"
DAVE="dave@example.com";       DAVE_PASS="davepass"

# Backend users defined in proxysql.cnf / the backend init scripts
MYSQL_BACKEND="okta_shared"
PGSQL_BACKEND="okta_pgsql"

CLEARTEXT="--enable-cleartext-plugin"

# ---------------------------------------------------------------------------
# Counters / output
# ---------------------------------------------------------------------------
TESTS_RUN=0; TESTS_PASSED=0; TESTS_FAILED=0
pass() { TESTS_RUN=$((TESTS_RUN+1)); TESTS_PASSED=$((TESTS_PASSED+1)); echo "  PASS: $1"; }
fail() { TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1)); echo "  FAIL: $1"; [[ -n "${2:-}" ]] && echo "        $2"; return 0; }
section() { echo; echo "======================================================================"; echo "  $1"; echo "======================================================================"; }

wait_for_port() {
    local host="$1" port="$2" label="$3" max_wait="${4:-120}" elapsed=0
    echo -n "Waiting for ${label} (${host}:${port}) ..."
    while ! (echo > /dev/tcp/"$host"/"$port") 2>/dev/null; do
        sleep 1; elapsed=$((elapsed+1))
        if [[ $elapsed -ge $max_wait ]]; then echo " TIMEOUT"; return 1; fi
    done
    echo " ready (${elapsed}s)"
}

run_admin() {
    local out rc=0
    out=$(mysql -h "$PROXYSQL_HOST" -P "$PROXYSQL_ADMIN_PORT" -u "$ADMIN_USER" -p"$ADMIN_PASS" \
        --connect-timeout=10 -N -B -e "$1" 2>&1) || rc=$?
    echo "$out" | grep -v 'mysql: \[Warning\]' || true
    return ${rc}
}

# MySQL LDAP auth via the proxy (cleartext plugin). Echoes output; returns rc.
mysql_ldap() {
    local user="$1" pass="$2" query="$3" out rc=0
    out=$(mysql -h "$PROXYSQL_HOST" -P "$PROXYSQL_MYSQL_PORT" -u "$user" -p"$pass" \
        --connect-timeout=15 $CLEARTEXT -N -B -e "$query" 2>&1) || rc=$?
    echo "$out" | grep -v 'mysql: \[Warning\]' || true
    return ${rc}
}

# PgSQL LDAP auth via the proxy. Echoes output; returns rc.
pgsql_ldap() {
    local user="$1" pass="$2" db="$3" query="$4"
    PGPASSWORD="$pass" psql -h "$PROXYSQL_HOST" -p "$PROXYSQL_PGSQL_PORT" -U "$user" -d "$db" \
        -t -A -w -c "$query" 2>&1
}

set_ldap_var() { run_admin "SET $1=$2" >/dev/null 2>&1; }

# Double single quotes so a username/value is safe inside a single-quoted SQL
# literal (needed because a test user contains an apostrophe).
sqlq() { local s="$1"; printf '%s' "${s//\'/\'\'}"; }

# A login was rejected if the client got an auth error rather than the row.
# MySQL's rejection text ("ERROR 1045 ... Access denied") contains a digit, so we
# must key off the error markers, not the absence of "1".
is_rejected()  { [[ "$1" == *denied* || "$1" == *ERROR* || "$1" == *FATAL* || "$1" == *failed* ]]; }
is_query_ok()  { ! is_rejected "$1" && [[ "$1" == *"1"* ]]; }

reset_mappings() {
    run_admin "DELETE FROM mysql_ldap_mapping" >/dev/null 2>&1
    run_admin "DELETE FROM pgsql_ldap_mapping" >/dev/null 2>&1
    run_admin "LOAD MYSQL LDAP MAPPING TO RUNTIME" >/dev/null 2>&1
    run_admin "LOAD PGSQL LDAP MAPPING TO RUNTIME" >/dev/null 2>&1
}

map_mysql() { # priority frontend backend
    run_admin "INSERT INTO mysql_ldap_mapping (priority, frontend_entity, backend_entity, comment) VALUES ($1, '$(sqlq "$2")', '$3', 'regression')" >/dev/null 2>&1
    run_admin "LOAD MYSQL LDAP MAPPING TO RUNTIME" >/dev/null 2>&1
}
map_pgsql() { # priority frontend backend
    run_admin "INSERT INTO pgsql_ldap_mapping (priority, frontend_entity, backend_entity, comment) VALUES ($1, '$(sqlq "$2")', '$3', 'regression')" >/dev/null 2>&1
    run_admin "LOAD PGSQL LDAP MAPPING TO RUNTIME" >/dev/null 2>&1
}

# ===========================================================================
section "Phase 0: wait for services"
# ===========================================================================
wait_for_port "$PROXYSQL_HOST" "$PROXYSQL_ADMIN_PORT" "ProxySQL admin" 180 || true
wait_for_port "$PROXYSQL_HOST" "$PROXYSQL_MYSQL_PORT" "ProxySQL MySQL proxy" 180 || true
wait_for_port "$PROXYSQL_HOST" "$PROXYSQL_PGSQL_PORT" "ProxySQL PgSQL proxy" 180 || true
sleep 3

# ===========================================================================
section "Phase 1: point ProxySQL at the local LDAP server"
# ===========================================================================
# String values must be single-quoted so the admin stores them unquoted. The DN
# format additionally contains '=' characters, which exercises the SET parser.
set_ldap_var "ldap-okta_url"                  "'$LDAP_URL'"
set_ldap_var "ldap-okta_base_dn"              "'$LDAP_BASE_DN'"
set_ldap_var "ldap-okta_user_dn_format"       "'$LDAP_DN_FORMAT'"
set_ldap_var "ldap-okta_starttls"             "'false'"
set_ldap_var "ldap-okta_enabled"              "'true'"
# Disable the auth cache (ttl=0) so every connection re-resolves against the
# CURRENT mappings/default. Otherwise a backend user cached from an earlier
# phase could be reused as a fallback and mask a resolution regression.
set_ldap_var "ldap-okta_cache_ttl"            "0"
set_ldap_var "ldap-okta_bind_timeout_ms"      "10000"
set_ldap_var "ldap-okta_default_backend_user" "'$MYSQL_BACKEND'"
set_ldap_var "ldap-okta_default_hostgroup"    "0"
set_ldap_var "ldap-okta_default_max_connections" "1000"
run_admin "LOAD LDAP VARIABLES TO RUNTIME" >/dev/null 2>&1

stored=$(run_admin "SELECT variable_value FROM global_variables WHERE variable_name='ldap-okta_user_dn_format'")
if [[ "$stored" == "$LDAP_DN_FORMAT" ]]; then
    pass "DN format stored correctly with '=' preserved: $stored"
else
    fail "DN format corrupted by SET parser" "expected '$LDAP_DN_FORMAT' got '$stored'"
fi

# ===========================================================================
section "Phase 2: baseline — local LDAP bind works (MySQL + PgSQL)"
# ===========================================================================
reset_mappings
map_mysql 999 '@everyone' "$MYSQL_BACKEND"
map_pgsql 999 '@everyone' "$PGSQL_BACKEND"

out=$(mysql_ldap "$ALICE" "$ALICE_PASS" "SELECT 1" || true)
if is_query_ok "$out"; then pass "MySQL: alice binds against local LDAP and queries"; else fail "MySQL: alice LDAP auth failed" "$out"; fi

out=$(pgsql_ldap "$ALICE" "$ALICE_PASS" "testdb" "SELECT 1" || true)
if is_query_ok "$out"; then pass "PgSQL: alice binds against local LDAP and queries"; else fail "PgSQL: alice LDAP auth failed" "$out"; fi

out=$(mysql_ldap "$ALICE" "WrongPass!" "SELECT 1" || true)
if is_rejected "$out"; then pass "MySQL: wrong password rejected"; else fail "MySQL: wrong password was accepted" "$out"; fi

# ===========================================================================
section "Phase 3: username with SQL metacharacters resolves safely (#3)"
# ===========================================================================
# Map o'brien (apostrophe) to a VALID backend, and set the default backend user
# to a bogus name. Backend resolution is an in-memory match against the runtime
# mapping (no SQL is built from the username, so there is no injection surface),
# but a username with metacharacters must still round-trip correctly: o'brien
# must resolve via its exact mapping rather than fall back to the (bogus)
# default. So o'brien succeeding proves the username is handled correctly end to
# end (and the mapping INSERT, which IS SQL, escapes it — see sqlq).
reset_mappings
set_ldap_var "ldap-okta_default_backend_user" "'__no_such_backend__'"
run_admin "LOAD LDAP VARIABLES TO RUNTIME" >/dev/null 2>&1
map_mysql 100 "$OBRIEN" "$MYSQL_BACKEND"

out=$(mysql_ldap "$OBRIEN" "$OBRIEN_PASS" "SELECT 1" || true)
if is_query_ok "$out"; then
    pass "MySQL: username with apostrophe resolves via its exact (escaped) mapping"
else
    fail "MySQL: apostrophe username failed (escaping regression?)" "$out"
fi

# Control: a user with NO mapping falls back to the bogus default -> rejected.
# This proves the default really is unusable, so o'brien's success above came
# from its exact mapping rather than from the fallback.
out=$(mysql_ldap "$ALICE" "$ALICE_PASS" "SELECT 1" || true)
if is_rejected "$out"; then
    pass "MySQL: unmapped user falls back to (bogus) default and is rejected"
else
    fail "MySQL: unmapped user unexpectedly authenticated" "$out"
fi

# Same escaping check on the PgSQL path.
map_pgsql 100 "$OBRIEN" "$PGSQL_BACKEND"
out=$(pgsql_ldap "$OBRIEN" "$OBRIEN_PASS" "testdb" "SELECT 1" || true)
if is_query_ok "$out"; then
    pass "PgSQL: username with apostrophe resolves via its exact (escaped) mapping"
else
    fail "PgSQL: apostrophe username failed (escaping regression?)" "$out"
fi

set_ldap_var "ldap-okta_default_backend_user" "'$MYSQL_BACKEND'"
run_admin "LOAD LDAP VARIABLES TO RUNTIME" >/dev/null 2>&1

# ===========================================================================
section "Phase 4: exact mapping beats @everyone regardless of priority (#7)"
# ===========================================================================
# @everyone is given a LOWER priority number (1 = higher priority) than the
# exact alice mapping (100), and points to a bogus backend. With the old
# "ORDER BY priority" resolution, @everyone (priority 1) would win and alice
# would be routed to the bogus backend and rejected. With exact-match-first,
# alice's exact mapping wins and she authenticates.
reset_mappings
map_mysql 1   '@everyone' '__no_such_backend__'
map_mysql 100 "$ALICE"    "$MYSQL_BACKEND"

out=$(mysql_ldap "$ALICE" "$ALICE_PASS" "SELECT 1" || true)
if is_query_ok "$out"; then
    pass "MySQL: exact mapping (priority 100) beats @everyone (priority 1)"
else
    fail "MySQL: @everyone shadowed the exact mapping (precedence regression)" "$out"
fi

# Control: bob is only matched by @everyone -> bogus backend -> rejected. Proves
# @everyone really points at the bogus backend.
out=$(mysql_ldap "$BOB" "$BOB_PASS" "SELECT 1" || true)
if is_rejected "$out"; then
    pass "MySQL: @everyone-only user routed to bogus backend and rejected"
else
    fail "MySQL: @everyone catch-all unexpectedly authenticated bob" "$out"
fi

# ===========================================================================
section "Phase 5: per-protocol mapping isolation at the runtime tables (#2,#5)"
# ===========================================================================
# Load DIFFERENT data into the MySQL and PgSQL mapping tables (PgSQL loaded
# last), then read the runtime_* admin tables. Selecting a runtime_* table
# re-dumps the plugin's in-memory mapping. With the old single shared vector,
# loading PgSQL last left that vector holding PgSQL rows, so re-dumping
# runtime_mysql_ldap_mapping returned the PgSQL backend/row-count instead of the
# MySQL ones. With separate per-protocol vectors each table reflects its own
# source.
reset_mappings
run_admin "INSERT INTO mysql_ldap_mapping (priority, frontend_entity, backend_entity, comment) VALUES (10, '$ALICE', '$MYSQL_BACKEND', 'm')" >/dev/null 2>&1
run_admin "LOAD MYSQL LDAP MAPPING TO RUNTIME" >/dev/null 2>&1
run_admin "INSERT INTO pgsql_ldap_mapping (priority, frontend_entity, backend_entity, comment) VALUES (20, '$ALICE', '$PGSQL_BACKEND', 'p')" >/dev/null 2>&1
run_admin "INSERT INTO pgsql_ldap_mapping (priority, frontend_entity, backend_entity, comment) VALUES (30, '$BOB', '$PGSQL_BACKEND', 'p')" >/dev/null 2>&1
run_admin "LOAD PGSQL LDAP MAPPING TO RUNTIME" >/dev/null 2>&1

m_be=$(run_admin "SELECT backend_entity FROM runtime_mysql_ldap_mapping WHERE frontend_entity='$ALICE'")
p_be=$(run_admin "SELECT backend_entity FROM runtime_pgsql_ldap_mapping WHERE frontend_entity='$ALICE'")
p_cnt=$(run_admin "SELECT COUNT(*) FROM runtime_pgsql_ldap_mapping")

if [[ "$m_be" == "$MYSQL_BACKEND" ]]; then
    pass "runtime_mysql_ldap_mapping: alice -> $MYSQL_BACKEND"
else
    fail "runtime_mysql_ldap_mapping wrong backend" "expected $MYSQL_BACKEND got '$m_be'"
fi
if [[ "$p_be" == "$PGSQL_BACKEND" ]]; then
    pass "runtime_pgsql_ldap_mapping: alice -> $PGSQL_BACKEND (isolated from MySQL table)"
else
    fail "runtime_pgsql_ldap_mapping shows wrong/clobbered backend" "expected $PGSQL_BACKEND got '$p_be'"
fi
if [[ "$p_cnt" == "2" ]]; then
    pass "runtime_pgsql_ldap_mapping has its own 2 rows (not clobbered to MySQL's 1)"
else
    fail "runtime_pgsql_ldap_mapping row count wrong" "expected 2 got '$p_cnt'"
fi

# ===========================================================================
section "Phase 6: PgSQL frontend connection counter is released (#1)"
# ===========================================================================
# Cap connections low, then open and CLOSE many sequential PgSQL LDAP sessions.
# Each disconnect must decrement the plugin's per-user counter. With the bug the
# counter only ever increased, so after MAX cycles every further connection was
# rejected with "too many connections", and the active-connections stat stayed
# pinned high.
# 'dave' connects here for the FIRST time, after the cap is lowered to 5, so his
# per-user max is 5. With the bug the counter is never decremented, so the 6th
# and later connections are rejected (only ~5 of 15 succeed); with the fix every
# disconnect frees a slot and all 15 succeed.
reset_mappings
map_pgsql 100 "$DAVE" "$PGSQL_BACKEND"
set_ldap_var "ldap-okta_default_max_connections" "5"
run_admin "LOAD LDAP VARIABLES TO RUNTIME" >/dev/null 2>&1
sleep 1

CYCLES=15
ok_count=0
for _ in $(seq 1 $CYCLES); do
    out=$(pgsql_ldap "$DAVE" "$DAVE_PASS" "testdb" "SELECT 1" || true)
    if is_query_ok "$out"; then ok_count=$((ok_count+1)); fi
    sleep 0.2
done
if [[ $ok_count -eq $CYCLES ]]; then
    pass "PgSQL: all $CYCLES sequential LDAP connections succeeded (slots released on disconnect)"
else
    fail "PgSQL: only $ok_count/$CYCLES connections succeeded — connection counter leaking" \
         "with max=5 and a leaking counter, connections fail after ~5 cycles"
fi

sleep 2
active=$(run_admin "SELECT Variable_Value FROM stats_mysql_global WHERE Variable_Name='Okta_LDAP_active_frontend_connections'")
if [[ -n "$active" && "$active" -le 1 ]]; then
    pass "Okta_LDAP_active_frontend_connections returned to ~0 after disconnects (got $active)"
else
    fail "active frontend connection counter not released after disconnect" "stat=$active (expected <=1)"
fi
set_ldap_var "ldap-okta_default_max_connections" "1000"
run_admin "LOAD LDAP VARIABLES TO RUNTIME" >/dev/null 2>&1

# ===========================================================================
section "Phase 7: mapping to a non-existent backend is rejected cleanly (#10)"
# ===========================================================================
# carol is mapped to a backend user that does not exist in mysql_users. The
# connection must be rejected (not crash ProxySQL), and a subsequent valid
# connection must still work.
reset_mappings
map_mysql 100 "$CAROL" '__missing_backend__'

out=$(mysql_ldap "$CAROL" "$CAROL_PASS" "SELECT 1" || true)
if is_rejected "$out"; then
    pass "MySQL: user mapped to a missing backend is rejected"
else
    fail "MySQL: connection to missing backend unexpectedly succeeded" "$out"
fi

# ProxySQL must still be alive and serving after the rejected/failed login.
map_mysql 100 "$ALICE" "$MYSQL_BACKEND"
out=$(mysql_ldap "$ALICE" "$ALICE_PASS" "SELECT 1" || true)
if is_query_ok "$out"; then
    pass "ProxySQL still serves valid logins after the rejected one (no crash)"
else
    fail "ProxySQL not serving after the rejected login" "$out"
fi

# ===========================================================================
section "Phase 8: MySQL per-user tracking keys on the Okta user (#2)"
# ===========================================================================
# After a MySQL LDAP login, stats_mysql_users must list the Okta username (the
# session's fe_username), not the shared backend user. With the bug fe_username
# was set to the backend user, so every Okta user collapsed onto one
# backend-named counter and per-user max_connections/stats were meaningless.
reset_mappings
map_mysql 100 "$ALICE" "$MYSQL_BACKEND"
mysql_ldap "$ALICE" "$ALICE_PASS" "SELECT 1" >/dev/null 2>&1 || true
# stats_mysql_users is refreshed on SELECT and includes the LDAP tracker rows;
# the per-user entry persists (at 0 connections) after the client disconnects.
u=$(run_admin "SELECT username FROM stats_mysql_users WHERE username='$ALICE'")
if [[ "$u" == "$ALICE" ]]; then
    pass "stats_mysql_users tracks the Okta user '$ALICE' (per-user, not the backend user)"
else
    fail "per-user tracking keyed on the backend user, not the Okta user" "stats_mysql_users row for '$ALICE' = '$u'"
fi

# ===========================================================================
section "Results"
# ===========================================================================
echo "  Total:  $TESTS_RUN"
echo "  Passed: $TESTS_PASSED"
echo "  Failed: $TESTS_FAILED"
echo "======================================================================"
[[ $TESTS_FAILED -eq 0 ]] && { echo "ALL REGRESSION TESTS PASSED"; exit 0; } || { echo "SOME REGRESSION TESTS FAILED"; exit 1; }
