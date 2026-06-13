#!/usr/bin/env bash
# Saving >=8 LDAP mappings must not crash ProxySQL. The bulk-insert path bound
# placeholders with the wrong multiplier and aborted the daemon at the 8th row.
# Insert 9 mappings, LOAD TO RUNTIME (bulk-saves to the runtime table), and
# confirm the runtime table has 9 rows and admin is still responsive.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
okta_setup
trap okta_teardown EXIT

section "Saving >=8 LDAP mappings does not crash ProxySQL (#1)"
for i in $(seq 1 9); do
    run_admin "INSERT INTO mysql_ldap_mapping (priority, frontend_entity, backend_entity, comment) VALUES ($((100+i)), 'bulk${i}@example.com', '$MYSQL_BACKEND', 'bulk')" >/dev/null 2>&1
done
run_admin "LOAD MYSQL LDAP MAPPING TO RUNTIME" >/dev/null 2>&1
cnt=$(run_admin "SELECT COUNT(*) FROM runtime_mysql_ldap_mapping")
if [[ "$cnt" == "9" ]]; then
    pass "MySQL: 9-row bulk save populated runtime_mysql_ldap_mapping (no crash)"
else
    fail "MySQL: bulk save of >=8 mappings crashed/failed" "runtime count='$cnt' (expected 9; empty => ProxySQL aborted)"
fi

run_admin "DELETE FROM pgsql_ldap_mapping" >/dev/null 2>&1
for i in $(seq 1 9); do
    run_admin "INSERT INTO pgsql_ldap_mapping (priority, frontend_entity, backend_entity, comment) VALUES ($((100+i)), 'bulk${i}@example.com', '$PGSQL_BACKEND', 'bulk')" >/dev/null 2>&1
done
run_admin "LOAD PGSQL LDAP MAPPING TO RUNTIME" >/dev/null 2>&1
cntp=$(run_admin "SELECT COUNT(*) FROM runtime_pgsql_ldap_mapping")
if [[ "$cntp" == "9" ]]; then
    pass "PgSQL: 9-row bulk save populated runtime_pgsql_ldap_mapping (no crash)"
else
    fail "PgSQL: bulk save of >=8 mappings crashed/failed" "runtime count='$cntp' (expected 9)"
fi

alive=$(run_admin "SELECT 1")
if [[ "$alive" == "1" ]]; then pass "ProxySQL admin still responsive after bulk saves"; else fail "ProxySQL not responsive after bulk saves" "$alive"; fi

okta_summary; exit $?
