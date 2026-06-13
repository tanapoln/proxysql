#!/usr/bin/env bash
# Baseline: a seeded LDAP user binds against the local OpenLDAP and queries via
# both the MySQL and PgSQL frontends; a wrong password is rejected.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
okta_setup
trap okta_teardown EXIT

section "Baseline: local LDAP bind works (MySQL + PgSQL)"
map_mysql 999 '@everyone' "$MYSQL_BACKEND"
map_pgsql 999 '@everyone' "$PGSQL_BACKEND"

out=$(mysql_ldap "$ALICE" "$ALICE_PASS" "SELECT 1" || true)
if is_query_ok "$out"; then pass "MySQL: alice binds against local LDAP and queries"; else fail "MySQL: alice LDAP auth failed" "$out"; fi

out=$(pgsql_ldap "$ALICE" "$ALICE_PASS" "testdb" "SELECT 1" || true)
if is_query_ok "$out"; then pass "PgSQL: alice binds against local LDAP and queries"; else fail "PgSQL: alice LDAP auth failed" "$out"; fi

out=$(mysql_ldap "$ALICE" "WrongPass!" "SELECT 1" || true)
if is_rejected "$out"; then pass "MySQL: wrong password rejected"; else fail "MySQL: wrong password was accepted" "$out"; fi

okta_summary; exit $?
