#!/usr/bin/env bash
# Opt-in SSL gate: with okta_require_ssl=true an LDAP login over an unencrypted
# connection must be rejected ("SSL is required"); with it false (default) an
# unencrypted LDAP login still works.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
okta_setup
trap okta_teardown EXIT

section "okta_require_ssl rejects LDAP logins on unencrypted links (#6)"
map_mysql 100 "$ALICE" "$MYSQL_BACKEND"
map_pgsql 100 "$ALICE" "$PGSQL_BACKEND"
set_ldap_var "ldap-okta_require_ssl" "'true'"
run_admin "LOAD LDAP VARIABLES TO RUNTIME" >/dev/null 2>&1

out=$(mysql -h "$PROXYSQL_HOST" -P "$PROXYSQL_MYSQL_PORT" -u "$ALICE" -p"$ALICE_PASS" $CLEARTEXT \
    --ssl-mode=DISABLED --connect-timeout=15 -N -B -e "SELECT 1" 2>&1 || true)
if is_rejected "$out"; then
    pass "MySQL: unencrypted LDAP login rejected when okta_require_ssl=true"
else
    fail "MySQL: unencrypted LDAP login accepted despite okta_require_ssl=true" "$out"
fi

out=$(PGPASSWORD="$ALICE_PASS" psql "host=$PROXYSQL_HOST port=$PROXYSQL_PGSQL_PORT user=$ALICE dbname=testdb sslmode=disable" \
    -t -A -w -c "SELECT 1" 2>&1 || true)
if is_rejected "$out"; then
    pass "PgSQL: unencrypted LDAP login rejected when okta_require_ssl=true"
else
    fail "PgSQL: unencrypted LDAP login accepted despite okta_require_ssl=true" "$out"
fi

# With the gate off (reset by setup/teardown), an unencrypted login works again.
set_ldap_var "ldap-okta_require_ssl" "'false'"
run_admin "LOAD LDAP VARIABLES TO RUNTIME" >/dev/null 2>&1
out=$(mysql_ldap "$ALICE" "$ALICE_PASS" "SELECT 1" || true)
if is_query_ok "$out"; then
    pass "MySQL: unencrypted LDAP login works again with okta_require_ssl=false"
else
    fail "MySQL: login broken after resetting okta_require_ssl=false" "$out"
fi

okta_summary; exit $?
