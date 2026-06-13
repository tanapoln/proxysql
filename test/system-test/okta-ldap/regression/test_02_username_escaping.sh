#!/usr/bin/env bash
# A username with SQL metacharacters (o'brien) must resolve via its exact
# mapping. With the default backend set to a bogus name, a mapped user must
# still authenticate (resolution round-trips the username correctly), while an
# unmapped user falls back to the bogus default and is rejected.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
okta_setup
trap okta_teardown EXIT

section "Username with SQL metacharacters resolves safely (#3)"
set_ldap_var "ldap-okta_default_backend_user" "'__no_such_backend__'"
run_admin "LOAD LDAP VARIABLES TO RUNTIME" >/dev/null 2>&1
map_mysql 100 "$OBRIEN" "$MYSQL_BACKEND"

out=$(mysql_ldap "$OBRIEN" "$OBRIEN_PASS" "SELECT 1" || true)
if is_query_ok "$out"; then
    pass "MySQL: apostrophe username resolves via its exact mapping"
else
    fail "MySQL: apostrophe username failed" "$out"
fi

out=$(mysql_ldap "$ALICE" "$ALICE_PASS" "SELECT 1" || true)
if is_rejected "$out"; then
    pass "MySQL: unmapped user falls back to the bogus default and is rejected"
else
    fail "MySQL: unmapped user unexpectedly authenticated" "$out"
fi

map_pgsql 100 "$OBRIEN" "$PGSQL_BACKEND"
out=$(pgsql_ldap "$OBRIEN" "$OBRIEN_PASS" "testdb" "SELECT 1" || true)
if is_query_ok "$out"; then
    pass "PgSQL: apostrophe username resolves via its exact mapping"
else
    fail "PgSQL: apostrophe username failed" "$out"
fi

okta_summary; exit $?
