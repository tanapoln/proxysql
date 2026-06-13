#!/usr/bin/env bash
# The MySQL and PgSQL mapping tables are independent. Load DIFFERENT data into
# each (PgSQL last), then read the runtime_* tables: each must reflect its own
# source. With the old single shared vector, loading PgSQL last clobbered the
# MySQL runtime table.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
okta_setup
trap okta_teardown EXIT

section "Per-protocol mapping isolation at the runtime tables (#2,#5)"
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
    pass "runtime_pgsql_ldap_mapping keeps its own 2 rows (not clobbered to MySQL's 1)"
else
    fail "runtime_pgsql_ldap_mapping row count wrong" "expected 2 got '$p_cnt'"
fi

okta_summary; exit $?
