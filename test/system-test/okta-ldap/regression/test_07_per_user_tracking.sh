#!/usr/bin/env bash
# After a MySQL LDAP login, stats_mysql_users must list the Okta username (the
# session's fe_username), not the shared backend user. With the bug fe_username
# was the backend user, collapsing every Okta user onto one counter.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
okta_setup
trap okta_teardown EXIT

section "MySQL per-user tracking keys on the Okta user (#2)"
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

okta_summary; exit $?
