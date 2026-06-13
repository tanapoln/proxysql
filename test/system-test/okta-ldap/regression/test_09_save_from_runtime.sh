#!/usr/bin/env bash
# SAVE ... LDAP MAPPING FROM RUNTIME must copy the runtime mapping into the
# persistent main config table (so SAVE TO DISK persists it). It previously
# wrote the runtime display table, leaving main empty.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
okta_setup
trap okta_teardown EXIT

section "SAVE LDAP MAPPING FROM RUNTIME writes the main table (#4)"
run_admin "INSERT INTO mysql_ldap_mapping (priority, frontend_entity, backend_entity, comment) VALUES (100, '$ALICE', '$MYSQL_BACKEND', 'persist')" >/dev/null 2>&1
run_admin "LOAD MYSQL LDAP MAPPING TO RUNTIME" >/dev/null 2>&1
run_admin "DELETE FROM mysql_ldap_mapping" >/dev/null 2>&1
run_admin "SAVE MYSQL LDAP MAPPING FROM RUNTIME" >/dev/null 2>&1
main_cnt=$(run_admin "SELECT COUNT(*) FROM mysql_ldap_mapping")
if [[ "$main_cnt" == "1" ]]; then
    pass "MySQL: SAVE FROM RUNTIME restored the persistent main table (count=1)"
else
    fail "MySQL: SAVE FROM RUNTIME did not write the main table" "mysql_ldap_mapping count='$main_cnt' (expected 1)"
fi

okta_summary; exit $?
