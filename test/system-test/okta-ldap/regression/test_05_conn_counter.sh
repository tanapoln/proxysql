#!/usr/bin/env bash
# The PgSQL frontend connection counter must be decremented on disconnect. Cap
# connections at 5 and open+close 15 sequential LDAP sessions: with the leak the
# counter never decremented, so connections failed after ~5 and the active stat
# stayed pinned. 'dave' is used only here so its per-user cap is a fresh 5.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
okta_setup
trap okta_teardown EXIT

section "PgSQL frontend connection counter is released on disconnect (#1)"
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

okta_summary; exit $?
