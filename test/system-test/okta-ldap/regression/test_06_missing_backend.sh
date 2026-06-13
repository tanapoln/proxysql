#!/usr/bin/env bash
# A user mapped to a backend that does not exist must be rejected cleanly (not
# crash ProxySQL), and a subsequent valid login must still work.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
okta_setup
trap okta_teardown EXIT

section "Mapping to a non-existent backend is rejected cleanly (#10)"
map_mysql 100 "$CAROL" '__missing_backend__'

out=$(mysql_ldap "$CAROL" "$CAROL_PASS" "SELECT 1" || true)
if is_rejected "$out"; then
    pass "MySQL: user mapped to a missing backend is rejected"
else
    fail "MySQL: connection to a missing backend unexpectedly succeeded" "$out"
fi

map_mysql 100 "$ALICE" "$MYSQL_BACKEND"
out=$(mysql_ldap "$ALICE" "$ALICE_PASS" "SELECT 1" || true)
if is_query_ok "$out"; then
    pass "ProxySQL still serves valid logins after the rejected one (no crash)"
else
    fail "ProxySQL not serving after the rejected login" "$out"
fi

okta_summary; exit $?
