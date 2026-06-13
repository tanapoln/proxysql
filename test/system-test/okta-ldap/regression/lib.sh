#!/usr/bin/env bash
# shellcheck disable=SC2034  # config vars below are consumed by sourcing test_*.sh
#
# Shared library for the Okta LDAP regression tests.
#
# Each test_*.sh sources this, calls `okta_setup` (which resets the shared
# ProxySQL to a known baseline), registers `okta_teardown` via trap, runs its
# assertions, and ends with `okta_summary`. Tests run in separate processes
# (no shell-state leakage) against one shared ProxySQL + OpenLDAP; isolation is
# provided by setup/teardown resetting all LDAP variables and clearing both
# mapping tables, so test order does not matter.

set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration (overridable via environment)
# ---------------------------------------------------------------------------
PROXYSQL_HOST="${PROXYSQL_HOST:-proxysql}"
PROXYSQL_ADMIN_PORT="${PROXYSQL_ADMIN_PORT:-6032}"
PROXYSQL_MYSQL_PORT="${PROXYSQL_MYSQL_PORT:-6033}"
PROXYSQL_PGSQL_PORT="${PROXYSQL_PGSQL_PORT:-6133}"
ADMIN_USER="${ADMIN_USER:-radmin}"
ADMIN_PASS="${ADMIN_PASS:-radmin}"

# Local LDAP server (osixia/openldap), seeded from ../ldap/bootstrap.ldif
LDAP_URL="${LDAP_URL:-ldap://openldap:389}"
LDAP_BASE_DN="${LDAP_BASE_DN:-dc=example,dc=com}"
LDAP_DN_FORMAT="${LDAP_DN_FORMAT:-uid=%s,ou=users,%s}"

# Seeded LDAP users (must match ../ldap/bootstrap.ldif)
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
# Per-test counters / output
# ---------------------------------------------------------------------------
TESTS_RUN=0; TESTS_PASSED=0; TESTS_FAILED=0
pass() { TESTS_RUN=$((TESTS_RUN+1)); TESTS_PASSED=$((TESTS_PASSED+1)); echo "  PASS: $1"; }
fail() { TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1)); echo "  FAIL: $1"; [[ -n "${2:-}" ]] && echo "        $2"; return 0; }
section() { echo; echo "======================================================================"; echo "  $1"; echo "======================================================================"; }

# ---------------------------------------------------------------------------
# Connection / query helpers
# ---------------------------------------------------------------------------
wait_for_port() {
    local host="$1" port="$2" label="$3" max_wait="${4:-120}" elapsed=0
    echo -n "Waiting for ${label} (${host}:${port}) ..."
    while ! (echo > /dev/tcp/"$host"/"$port") 2>/dev/null; do
        sleep 1; elapsed=$((elapsed+1))
        if [[ $elapsed -ge $max_wait ]]; then echo " TIMEOUT"; return 1; fi
    done
    echo " ready (${elapsed}s)"
}

okta_wait_for_services() {
    wait_for_port "$PROXYSQL_HOST" "$PROXYSQL_ADMIN_PORT" "ProxySQL admin" "${1:-180}" || return 1
    wait_for_port "$PROXYSQL_HOST" "$PROXYSQL_MYSQL_PORT" "ProxySQL MySQL proxy" "${1:-180}" || return 1
    wait_for_port "$PROXYSQL_HOST" "$PROXYSQL_PGSQL_PORT" "ProxySQL PgSQL proxy" "${1:-180}" || return 1
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

map_mysql() { # priority frontend backend
    run_admin "INSERT INTO mysql_ldap_mapping (priority, frontend_entity, backend_entity, comment) VALUES ($1, '$(sqlq "$2")', '$3', 'regression')" >/dev/null 2>&1
    run_admin "LOAD MYSQL LDAP MAPPING TO RUNTIME" >/dev/null 2>&1
}
map_pgsql() { # priority frontend backend
    run_admin "INSERT INTO pgsql_ldap_mapping (priority, frontend_entity, backend_entity, comment) VALUES ($1, '$(sqlq "$2")', '$3', 'regression')" >/dev/null 2>&1
    run_admin "LOAD PGSQL LDAP MAPPING TO RUNTIME" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Setup / teardown — reset the shared ProxySQL to a known baseline so each
# test is isolated regardless of run order. cache_ttl=0 disables the auth cache
# so every connection re-resolves against the current mappings/variables.
# ---------------------------------------------------------------------------
_okta_reset_state() {
    set_ldap_var "ldap-okta_url"                     "'$LDAP_URL'"
    set_ldap_var "ldap-okta_base_dn"                 "'$LDAP_BASE_DN'"
    set_ldap_var "ldap-okta_user_dn_format"          "'$LDAP_DN_FORMAT'"
    set_ldap_var "ldap-okta_starttls"                "'false'"
    set_ldap_var "ldap-okta_enabled"                 "'true'"
    set_ldap_var "ldap-okta_cache_ttl"               "0"
    set_ldap_var "ldap-okta_bind_timeout_ms"         "10000"
    set_ldap_var "ldap-okta_default_backend_user"    "'$MYSQL_BACKEND'"
    set_ldap_var "ldap-okta_default_hostgroup"       "0"
    set_ldap_var "ldap-okta_default_max_connections" "1000"
    set_ldap_var "ldap-okta_require_ssl"             "'false'"
    run_admin "LOAD LDAP VARIABLES TO RUNTIME" >/dev/null 2>&1
    run_admin "DELETE FROM mysql_ldap_mapping" >/dev/null 2>&1
    run_admin "DELETE FROM pgsql_ldap_mapping" >/dev/null 2>&1
    run_admin "LOAD MYSQL LDAP MAPPING TO RUNTIME" >/dev/null 2>&1
    run_admin "LOAD PGSQL LDAP MAPPING TO RUNTIME" >/dev/null 2>&1
}

okta_setup() {
    # Make the test independently runnable: ensure ProxySQL is reachable (fast
    # when already up), then establish the clean baseline.
    wait_for_port "$PROXYSQL_HOST" "$PROXYSQL_ADMIN_PORT" "ProxySQL admin" 60 >/dev/null 2>&1 || true
    _okta_reset_state
}

okta_teardown() { _okta_reset_state; }

okta_summary() {
    echo
    echo "  ---- result: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed ----"
    [[ $TESTS_FAILED -eq 0 ]]
}
