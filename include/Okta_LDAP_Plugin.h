#ifndef OKTA_LDAP_PLUGIN_H
#define OKTA_LDAP_PLUGIN_H

#include <string>
#include <unordered_map>
#include <vector>
#include <ctime>
#include <cstring>
#include <memory>
#include <atomic>
#include <pthread.h>
#include <openssl/sha.h>

// Forward declarations — avoid pulling in full ProxySQL headers in plugin
enum cred_username_type { USERNAME_BACKEND, USERNAME_FRONTEND, USERNAME_NONE };
class SQLite3_result;
class SQLite3_row;

#include "MySQL_LDAP_Authentication.hpp"

// -----------------------------------------------------------------------
// Cached authentication entry
// -----------------------------------------------------------------------
struct CachedAuthEntry {
	std::string password_sha256;     // hex-encoded SHA-256 of plaintext password
	time_t      cached_at;
	std::string backend_username;
	int         default_hostgroup;
	std::string default_schema;
	bool        use_ssl;
	bool        schema_locked;
	bool        transaction_persistent;
	bool        fast_forward;
	int         max_connections;
};

// -----------------------------------------------------------------------
// Per-user frontend connection tracker
// -----------------------------------------------------------------------
struct FrontendConnTracker {
	int current_connections;
	int max_connections;
};

// -----------------------------------------------------------------------
// LDAP mapping entry (priority-ordered)
// -----------------------------------------------------------------------
struct LDAPMappingEntry {
	int         priority;
	std::string frontend_entity;
	std::string backend_entity;
	std::string comment;
};

// -----------------------------------------------------------------------
// Plugin statistics
// -----------------------------------------------------------------------
struct OktaLDAPStats {
	std::atomic<uint64_t> cache_hits{0};
	std::atomic<uint64_t> cache_misses{0};
	std::atomic<uint64_t> cache_expired{0};
	std::atomic<uint64_t> ldap_bind_success{0};
	std::atomic<uint64_t> ldap_bind_failure{0};
	std::atomic<uint64_t> ldap_bind_timeout{0};
	std::atomic<uint64_t> ldap_connect_errors{0};
};

// -----------------------------------------------------------------------
// Admin variable descriptor
// -----------------------------------------------------------------------
struct OktaVarDescriptor {
	const char* name;
	const char* default_value;
};

// -----------------------------------------------------------------------
// Okta_LDAP_Plugin — concrete LDAP authentication via Okta's LDAP Interface
// -----------------------------------------------------------------------
class Okta_LDAP_Plugin : public MySQL_LDAP_Authentication {
public:
	Okta_LDAP_Plugin();
	~Okta_LDAP_Plugin() override;

	// --- Core authentication ---
	char* lookup(
		char *username, char *pass,
		enum cred_username_type usertype,
		bool *use_ssl, int *default_hostgroup,
		char **default_schema, bool *schema_locked,
		bool *transaction_persistent, bool *fast_forward,
		int *max_connections, void **sha1_pass, char **attributes,
		char **backend_username
	) override;

	// --- Frontend connection tracking ---
	int  increase_frontend_user_connections(char *username, int *max_connections = NULL) override;
	void decrease_frontend_user_connections(char *username) override;

	// --- User listing (for stats_mysql_ldap_users) ---
	std::unique_ptr<SQLite3_result> dump_all_users() override;

	// --- Locking ---
	void wrlock() override;
	void wrunlock() override;

	// --- Admin variables ---
	char** get_variables_list() override;
	bool   has_variable(const char *name) override;
	char*  get_variable(char *name) override;
	bool   set_variable(char *name, char *value) override;

	// --- LDAP mapping table (separate per-protocol storage) ---
	void            load_mysql_ldap_mapping(SQLite3_result *result) override;
	void            load_pgsql_ldap_mapping(SQLite3_result *result) override;
	SQLite3_result* dump_table_mysql_ldap_mapping() override;
	SQLite3_result* dump_table_pgsql_ldap_mapping() override;
	uint64_t        get_ldap_mapping_runtime_checksum() override;

	// --- Stats ---
	SQLite3_result* SQL3_getStats() override;

	// --- Version ---
	void print_version() override;

private:
	// Perform an LDAP simple bind against Okta and return true on success
	bool ldap_authenticate(const char *username, const char *password);

	// Build the user DN from the format string
	std::string build_user_dn(const char *username);

	// Compute hex-encoded SHA-256
	static std::string sha256_hex(const char *input);

	// Fallback backend user when a protocol-specific mapping yields no match.
	// Per-protocol mapping resolution is performed by the MySQL/PgSQL protocol
	// handlers against their own tables, so this only returns the configured
	// default backend user.
	std::string resolve_backend_user();

	// --- Locks ---
	pthread_rwlock_t main_lock;    // protects mapping + variables
	pthread_rwlock_t cache_lock;   // protects auth_cache
	pthread_rwlock_t conn_lock;    // protects conn_tracker

	// --- Auth cache ---
	std::unordered_map<std::string, CachedAuthEntry> auth_cache;

	// --- Connection tracking ---
	std::unordered_map<std::string, FrontendConnTracker> conn_tracker;

	// --- LDAP mapping (sorted by priority), one table per protocol ---
	std::vector<LDAPMappingEntry> mysql_ldap_mapping;
	std::vector<LDAPMappingEntry> pgsql_ldap_mapping;

	// --- Admin variables (name → value) ---
	std::unordered_map<std::string, std::string> variables;

	// --- Statistics ---
	OktaLDAPStats stats;

	// --- Variable descriptors (static list) ---
	static const std::vector<OktaVarDescriptor> var_descriptors;
};

#endif /* OKTA_LDAP_PLUGIN_H */
