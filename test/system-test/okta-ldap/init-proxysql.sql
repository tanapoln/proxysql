-- Configure Okta LDAP authentication variables
SET ldap-okta_url='ldaps://trial-1120298.ldap.okta.com';
SET ldap-okta_base_dn='dc=trial-1120298,dc=okta,dc=com';
SET ldap-okta_user_dn_format='uid=%s,ou=users,%s';
SET ldap-okta_cache_ttl=3600;
SET ldap-okta_bind_timeout_ms=10000;
SET ldap-okta_enabled=true;
SET ldap-okta_default_backend_user='okta_shared';
SET ldap-okta_default_hostgroup=0;
SET ldap-okta_default_max_connections=1000;

LOAD LDAP VARIABLES TO RUNTIME;
SAVE LDAP VARIABLES TO DISK;
