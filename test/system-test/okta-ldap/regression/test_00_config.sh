#!/usr/bin/env bash
# Setup sanity: LDAP variables apply and the DN format (which contains '=')
# round-trips through the admin SET parser unmangled.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
okta_setup
trap okta_teardown EXIT

section "Config: DN format with '=' preserved by the SET parser"
stored=$(run_admin "SELECT variable_value FROM global_variables WHERE variable_name='ldap-okta_user_dn_format'")
if [[ "$stored" == "$LDAP_DN_FORMAT" ]]; then
    pass "DN format stored with '=' preserved: $stored"
else
    fail "DN format corrupted by SET parser" "expected '$LDAP_DN_FORMAT' got '$stored'"
fi

okta_summary; exit $?
