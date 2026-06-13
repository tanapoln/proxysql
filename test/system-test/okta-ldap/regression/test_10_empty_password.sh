#!/usr/bin/env bash
# An empty password must never reach an LDAP simple bind (RFC 4513
# unauthenticated bind); ProxySQL must reject it outright. (--password= sends an
# empty password without prompting.)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
okta_setup
trap okta_teardown EXIT

section "Empty password is rejected (#2)"
map_mysql 100 "$ALICE" "$MYSQL_BACKEND"
out=$(mysql -h "$PROXYSQL_HOST" -P "$PROXYSQL_MYSQL_PORT" -u "$ALICE" --password= $CLEARTEXT \
    --connect-timeout=15 -N -B -e "SELECT 1" 2>&1 || true)
out=$(echo "$out" | grep -v 'mysql: \[Warning\]' || true)
if is_rejected "$out" || [[ "$out" != *"1"* ]]; then
    pass "MySQL: empty-password login is rejected"
else
    fail "MySQL: empty-password login was ACCEPTED (auth bypass)" "$out"
fi

okta_summary; exit $?
