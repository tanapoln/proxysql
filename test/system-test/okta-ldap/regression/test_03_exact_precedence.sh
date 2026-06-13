#!/usr/bin/env bash
# An exact mapping must beat the '@everyone' catch-all even when @everyone has a
# numerically higher priority. @everyone (priority 1) points at a bogus backend;
# alice has an exact mapping (priority 100) to a real backend.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
okta_setup
trap okta_teardown EXIT

section "Exact mapping beats @everyone regardless of priority (#7)"
map_mysql 1   '@everyone' '__no_such_backend__'
map_mysql 100 "$ALICE"    "$MYSQL_BACKEND"

out=$(mysql_ldap "$ALICE" "$ALICE_PASS" "SELECT 1" || true)
if is_query_ok "$out"; then
    pass "MySQL: exact mapping (priority 100) beats @everyone (priority 1)"
else
    fail "MySQL: @everyone shadowed the exact mapping (precedence regression)" "$out"
fi

# Control: bob is only matched by @everyone -> bogus backend -> rejected.
out=$(mysql_ldap "$BOB" "$BOB_PASS" "SELECT 1" || true)
if is_rejected "$out"; then
    pass "MySQL: @everyone-only user routed to the bogus backend and rejected"
else
    fail "MySQL: @everyone catch-all unexpectedly authenticated bob" "$out"
fi

okta_summary; exit $?
