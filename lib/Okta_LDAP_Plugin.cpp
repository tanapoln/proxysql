/**
 * Okta_LDAP_Plugin.cpp
 *
 * ProxySQL LDAP authentication plugin that validates frontend credentials
 * against Okta's LDAP Interface. Successful authentications are cached for
 * a configurable TTL (default 3600 seconds). All Okta users map to a shared
 * backend MySQL user; schema-based query rules route to specific hostgroups.
 *
 * Built as a shared library loaded by ProxySQL via dlopen().
 */

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string>
#include <unordered_map>
#include <vector>
#include <memory>
#include <algorithm>
#include <sstream>
#include <iomanip>
#include <pthread.h>
#include <openssl/sha.h>
#include <openssl/evp.h>
#include <ldap.h>

#include "sqlite3db.h"
#include "Okta_LDAP_Plugin.h"

#define OKTA_LDAP_PLUGIN_VERSION "1.0.0"

// -----------------------------------------------------------------------
// Variable descriptors — define all admin-configurable settings
// -----------------------------------------------------------------------
const std::vector<OktaVarDescriptor> Okta_LDAP_Plugin::var_descriptors = {
	{"okta_url",                  ""},
	{"okta_base_dn",              ""},
	{"okta_user_dn_format",       "uid=%s,ou=users,%s"},
	{"okta_cache_ttl",            "3600"},
	{"okta_bind_timeout_ms",      "5000"},
	{"okta_enabled",              "true"},
	{"okta_default_backend_user", "okta_shared"},
	{"okta_default_hostgroup",    "0"},
	{"okta_default_max_connections", "1000"},
	{"okta_starttls",             "false"},
};

// -----------------------------------------------------------------------
// Constructor / Destructor
// -----------------------------------------------------------------------

Okta_LDAP_Plugin::Okta_LDAP_Plugin() {
	pthread_rwlock_init(&main_lock, NULL);
	pthread_rwlock_init(&cache_lock, NULL);
	pthread_rwlock_init(&conn_lock, NULL);

	// Initialise variables to defaults
	for (const auto& vd : var_descriptors) {
		variables[vd.name] = vd.default_value;
	}
}

Okta_LDAP_Plugin::~Okta_LDAP_Plugin() {
	pthread_rwlock_destroy(&main_lock);
	pthread_rwlock_destroy(&cache_lock);
	pthread_rwlock_destroy(&conn_lock);
}

// -----------------------------------------------------------------------
// Utility: SHA-256 hex digest
// -----------------------------------------------------------------------
std::string Okta_LDAP_Plugin::sha256_hex(const char *input) {
	unsigned char hash[SHA256_DIGEST_LENGTH];
	EVP_MD_CTX *ctx = EVP_MD_CTX_new();
	if (ctx) {
		EVP_DigestInit_ex(ctx, EVP_sha256(), NULL);
		EVP_DigestUpdate(ctx, input, strlen(input));
		EVP_DigestFinal_ex(ctx, hash, NULL);
		EVP_MD_CTX_free(ctx);
	}

	std::ostringstream ss;
	for (int i = 0; i < SHA256_DIGEST_LENGTH; i++) {
		ss << std::hex << std::setw(2) << std::setfill('0') << (int)hash[i];
	}
	return ss.str();
}

// -----------------------------------------------------------------------
// Build LDAP DN from format string
// -----------------------------------------------------------------------
std::string Okta_LDAP_Plugin::build_user_dn(const char *username) {
	std::string fmt;
	std::string base_dn;

	pthread_rwlock_rdlock(&main_lock);
	auto it_fmt = variables.find("okta_user_dn_format");
	if (it_fmt != variables.end()) fmt = it_fmt->second;
	auto it_dn = variables.find("okta_base_dn");
	if (it_dn != variables.end()) base_dn = it_dn->second;
	pthread_rwlock_unlock(&main_lock);

	// Escape special characters in the username for LDAP DN (RFC 4514)
	// Characters that must be escaped: , + " \ < > ;
	std::string escaped_username;
	for (const char *p = username; *p; p++) {
		switch (*p) {
			case ',': case '+': case '"': case '\\':
			case '<': case '>': case ';':
				escaped_username += '\\';
				escaped_username += *p;
				break;
			default:
				escaped_username += *p;
				break;
		}
	}

	// Replace first %s with escaped username, second %s with base_dn
	char buf[1024];
	snprintf(buf, sizeof(buf), fmt.c_str(), escaped_username.c_str(), base_dn.c_str());
	return std::string(buf);
}

// -----------------------------------------------------------------------
// LDAP simple bind against Okta
// -----------------------------------------------------------------------
bool Okta_LDAP_Plugin::ldap_authenticate(const char *username, const char *password) {
	std::string okta_url;
	int timeout_ms = 5000;
	bool use_starttls = false;

	pthread_rwlock_rdlock(&main_lock);
	{
		auto it = variables.find("okta_url");
		if (it != variables.end()) okta_url = it->second;
		auto it_t = variables.find("okta_bind_timeout_ms");
		if (it_t != variables.end()) timeout_ms = atoi(it_t->second.c_str());
		auto it_tls = variables.find("okta_starttls");
		if (it_tls != variables.end()) use_starttls = (it_tls->second == "true");
	}
	pthread_rwlock_unlock(&main_lock);

	if (okta_url.empty()) {
		fprintf(stderr, "[Okta_LDAP_Plugin] Error: okta_url not configured\n");
		fflush(stderr);
		stats.ldap_connect_errors.fetch_add(1, std::memory_order_relaxed);
		return false;
	}

	LDAP *ld = NULL;
	int rc = ldap_initialize(&ld, okta_url.c_str());
	if (rc != LDAP_SUCCESS) {
		fprintf(stderr, "[Okta_LDAP_Plugin] ldap_initialize failed: %s\n", ldap_err2string(rc));
		stats.ldap_connect_errors.fetch_add(1, std::memory_order_relaxed);
		return false;
	}

	// Set LDAPv3
	int version = LDAP_VERSION3;
	ldap_set_option(ld, LDAP_OPT_PROTOCOL_VERSION, &version);

	// Set network timeout
	struct timeval tv;
	tv.tv_sec = timeout_ms / 1000;
	tv.tv_usec = (timeout_ms % 1000) * 1000;
	ldap_set_option(ld, LDAP_OPT_NETWORK_TIMEOUT, &tv);

	// Optionally StartTLS
	if (use_starttls) {
		rc = ldap_start_tls_s(ld, NULL, NULL);
		if (rc != LDAP_SUCCESS) {
			fprintf(stderr, "[Okta_LDAP_Plugin] ldap_start_tls_s failed: %s\n", ldap_err2string(rc));
			ldap_unbind_ext_s(ld, NULL, NULL);
			stats.ldap_connect_errors.fetch_add(1, std::memory_order_relaxed);
			return false;
		}
	}

	// Build user DN and perform simple bind
	std::string dn = build_user_dn(username);
	struct berval cred;
	cred.bv_val = (char *)password;
	cred.bv_len = strlen(password);

	rc = ldap_sasl_bind_s(ld, dn.c_str(), LDAP_SASL_SIMPLE, &cred, NULL, NULL, NULL);

	ldap_unbind_ext_s(ld, NULL, NULL);

	if (rc == LDAP_SUCCESS) {
		stats.ldap_bind_success.fetch_add(1, std::memory_order_relaxed);
		return true;
	} else if (rc == LDAP_TIMEOUT) {
		stats.ldap_bind_timeout.fetch_add(1, std::memory_order_relaxed);
		fprintf(stderr, "[Okta_LDAP_Plugin] LDAP bind timeout for user %s\n", username);
		return false;
	} else {
		stats.ldap_bind_failure.fetch_add(1, std::memory_order_relaxed);
		// Don't log passwords, but log the username and error
		fprintf(stderr, "[Okta_LDAP_Plugin] LDAP bind failed for user %s: %s\n",
			username, ldap_err2string(rc));
		return false;
	}
}

// -----------------------------------------------------------------------
// Resolve backend user from mapping table or default
// -----------------------------------------------------------------------
std::string Okta_LDAP_Plugin::resolve_backend_user(const char *frontend_username) {
	// main_lock must be held by caller (at least rdlock)
	// Search mapping by priority order (lowest first)
	for (const auto& entry : ldap_mapping) {
		if (entry.frontend_entity == frontend_username) {
			return entry.backend_entity;
		}
	}
	// Check for wildcard/group matches (entries starting with @)
	for (const auto& entry : ldap_mapping) {
		if (!entry.frontend_entity.empty() && entry.frontend_entity[0] == '@') {
			// Wildcard match: "@everyone" matches all users
			// In a full implementation, you'd check group membership via LDAP
			// For now, "@everyone" matches any authenticated user
			if (entry.frontend_entity == "@everyone") {
				return entry.backend_entity;
			}
		}
	}
	// Fall back to default backend user
	auto it = variables.find("okta_default_backend_user");
	if (it != variables.end()) {
		return it->second;
	}
	return "okta_shared";
}

// -----------------------------------------------------------------------
// Core authentication: lookup()
// -----------------------------------------------------------------------
char* Okta_LDAP_Plugin::lookup(
	char *username, char *pass,
	enum cred_username_type usertype,
	bool *use_ssl, int *default_hostgroup,
	char **default_schema, bool *schema_locked,
	bool *transaction_persistent, bool *fast_forward,
	int *max_connections, void **sha1_pass, char **attributes,
	char **backend_username
) {
	if (usertype != USERNAME_FRONTEND) return NULL;

	// Check if plugin is enabled
	pthread_rwlock_rdlock(&main_lock);
	auto it_enabled = variables.find("okta_enabled");
	bool enabled = (it_enabled != variables.end() && it_enabled->second == "true");
	pthread_rwlock_unlock(&main_lock);

	if (!enabled) return NULL;

	if (!username || !pass) return NULL;

	std::string uname(username);
	std::string pass_hash = sha256_hex(pass);

	// --- 1. Check cache ---
	pthread_rwlock_rdlock(&cache_lock);
	auto cache_it = auth_cache.find(uname);
	if (cache_it != auth_cache.end()) {
		const CachedAuthEntry& entry = cache_it->second;
		int ttl = 3600;
		pthread_rwlock_rdlock(&main_lock);
		auto it_ttl = variables.find("okta_cache_ttl");
		if (it_ttl != variables.end()) ttl = atoi(it_ttl->second.c_str());
		pthread_rwlock_unlock(&main_lock);

		time_t now = time(NULL);
		if (entry.password_sha256 == pass_hash && (now - entry.cached_at) < ttl) {
			// Cache hit
			stats.cache_hits.fetch_add(1, std::memory_order_relaxed);

			*use_ssl = entry.use_ssl;
			*default_hostgroup = entry.default_hostgroup;
			if (default_schema) {
				*default_schema = entry.default_schema.empty()
					? strdup((char*)"information_schema") : strdup(entry.default_schema.c_str());
			}
			*schema_locked = entry.schema_locked;
			*transaction_persistent = entry.transaction_persistent;
			*fast_forward = entry.fast_forward;
			*max_connections = entry.max_connections;
			if (sha1_pass) *sha1_pass = NULL;
			if (attributes) *attributes = strdup("");
			if (backend_username) {
				*backend_username = strdup(entry.backend_username.c_str());
			}

			pthread_rwlock_unlock(&cache_lock);

			// Return the cleartext password to signal success.
		// ProxySQL compares this with the client-supplied password.
			return strdup(pass);
		} else if ((now - entry.cached_at) >= ttl) {
			stats.cache_expired.fetch_add(1, std::memory_order_relaxed);
		}
	}
	pthread_rwlock_unlock(&cache_lock);

	// --- 2. Cache miss: authenticate against Okta LDAP ---
	stats.cache_misses.fetch_add(1, std::memory_order_relaxed);

	if (!ldap_authenticate(username, pass)) {
		return NULL;  // Auth failed
	}

	// --- 3. Resolve backend user ---
	pthread_rwlock_rdlock(&main_lock);
	std::string backend_user = resolve_backend_user(username);

	int hg = 0;
	auto it_hg = variables.find("okta_default_hostgroup");
	if (it_hg != variables.end()) hg = atoi(it_hg->second.c_str());

	int maxconn = 1000;
	auto it_mc = variables.find("okta_default_max_connections");
	if (it_mc != variables.end()) maxconn = atoi(it_mc->second.c_str());
	pthread_rwlock_unlock(&main_lock);

	// --- 4. Populate output params ---
	*use_ssl = false;
	*default_hostgroup = hg;
	if (default_schema) *default_schema = strdup((char*)"information_schema");
	*schema_locked = false;
	*transaction_persistent = true;
	*fast_forward = false;
	*max_connections = maxconn;
	if (sha1_pass) *sha1_pass = NULL;
	if (attributes) *attributes = strdup("");
	if (backend_username) {
		*backend_username = strdup(backend_user.c_str());
	}

	// --- 5. Store in cache ---
	CachedAuthEntry new_entry;
	new_entry.password_sha256      = pass_hash;
	new_entry.cached_at            = time(NULL);
	new_entry.backend_username     = backend_user;
	new_entry.default_hostgroup    = hg;
	new_entry.default_schema       = "";
	new_entry.use_ssl              = false;
	new_entry.schema_locked        = false;
	new_entry.transaction_persistent = true;
	new_entry.fast_forward         = false;
	new_entry.max_connections      = maxconn;

	pthread_rwlock_wrlock(&cache_lock);
	auth_cache[uname] = std::move(new_entry);
	pthread_rwlock_unlock(&cache_lock);

	// Return the cleartext password to signal success.
	// ProxySQL compares this with the client-supplied password.
	return strdup(pass);
}

// -----------------------------------------------------------------------
// Frontend connection tracking
// -----------------------------------------------------------------------

int Okta_LDAP_Plugin::increase_frontend_user_connections(char *username, int *mc) {
	if (!username) return 0;
	std::string uname(username);

	int default_max = 1000;
	pthread_rwlock_rdlock(&main_lock);
	auto it = variables.find("okta_default_max_connections");
	if (it != variables.end()) default_max = atoi(it->second.c_str());
	pthread_rwlock_unlock(&main_lock);

	pthread_rwlock_wrlock(&conn_lock);
	auto& tracker = conn_tracker[uname];
	if (tracker.max_connections == 0) {
		tracker.max_connections = default_max;
	}
	tracker.current_connections++;
	int free_conns = tracker.max_connections - tracker.current_connections;
	if (mc) *mc = tracker.max_connections;
	pthread_rwlock_unlock(&conn_lock);

	return free_conns;
}

void Okta_LDAP_Plugin::decrease_frontend_user_connections(char *username) {
	if (!username) return;
	std::string uname(username);

	pthread_rwlock_wrlock(&conn_lock);
	auto it = conn_tracker.find(uname);
	if (it != conn_tracker.end() && it->second.current_connections > 0) {
		it->second.current_connections--;
	}
	pthread_rwlock_unlock(&conn_lock);
}

// -----------------------------------------------------------------------
// dump_all_users — for stats_mysql_ldap_users table
// -----------------------------------------------------------------------
std::unique_ptr<SQLite3_result> dump_all_users_impl(
	pthread_rwlock_t *conn_lock_ptr,
	const std::unordered_map<std::string, FrontendConnTracker>& conn_tracker
) {
	auto result = std::unique_ptr<SQLite3_result>(
		new SQLite3_result(LDAP_USER_FIELD_IDX::__SIZE)
	);
	result->add_column_definition(SQLITE_TEXT, "username");
	result->add_column_definition(SQLITE_INTEGER, "frontend_connections");
	result->add_column_definition(SQLITE_INTEGER, "frontend_max_connections");

	for (const auto& pair : conn_tracker) {
		char conns_buf[16], maxconns_buf[16];
		snprintf(conns_buf, sizeof(conns_buf), "%d", pair.second.current_connections);
		snprintf(maxconns_buf, sizeof(maxconns_buf), "%d", pair.second.max_connections);
		char *fields[LDAP_USER_FIELD_IDX::__SIZE];
		fields[LDAP_USER_FIELD_IDX::USERNAME] = const_cast<char*>(pair.first.c_str());
		fields[LDAP_USER_FIELD_IDX::FRONTEND_CONNECTIONS] = conns_buf;
		fields[LDAP_USER_FIELD_IDX::FRONTED_MAX_CONNECTIONS] = maxconns_buf;
		result->add_row(fields);
	}
	return result;
}

std::unique_ptr<SQLite3_result> Okta_LDAP_Plugin::dump_all_users() {
	pthread_rwlock_rdlock(&conn_lock);
	auto result = dump_all_users_impl(&conn_lock, conn_tracker);
	pthread_rwlock_unlock(&conn_lock);
	return result;
}

// -----------------------------------------------------------------------
// Locking
// -----------------------------------------------------------------------
void Okta_LDAP_Plugin::wrlock() {
	pthread_rwlock_wrlock(&main_lock);
}

void Okta_LDAP_Plugin::wrunlock() {
	pthread_rwlock_unlock(&main_lock);
}

// -----------------------------------------------------------------------
// Admin variable management
// -----------------------------------------------------------------------

char** Okta_LDAP_Plugin::get_variables_list() {
	size_t count = var_descriptors.size();
	char **list = (char **)malloc(sizeof(char *) * (count + 1));
	for (size_t i = 0; i < count; i++) {
		// Return bare names — the admin framework adds the module prefix (e.g. "ldap-")
		list[i] = strdup(var_descriptors[i].name);
	}
	list[count] = NULL;
	return list;
}

bool Okta_LDAP_Plugin::has_variable(const char *name) {
	if (!name) return false;
	return variables.find(name) != variables.end();
}

char* Okta_LDAP_Plugin::get_variable(char *name) {
	if (!name) return NULL;
	auto it = variables.find(name);
	if (it != variables.end()) {
		return strdup(it->second.c_str());
	}
	return NULL;
}

bool Okta_LDAP_Plugin::set_variable(char *name, char *value) {
	if (!name || !value) return false;
	auto it = variables.find(name);
	if (it != variables.end()) {
		it->second = value;
		return true;
	}
	return false;
}

// -----------------------------------------------------------------------
// LDAP Mapping table management
// -----------------------------------------------------------------------

void Okta_LDAP_Plugin::load_mysql_ldap_mapping(SQLite3_result *result) {
	// Caller holds wrlock
	ldap_mapping.clear();

	if (!result) return;

	for (auto *row : result->rows) {
		if (row->cnt < 3) continue;
		LDAPMappingEntry entry;
		entry.priority = atoi(row->fields[0]);
		entry.frontend_entity = row->fields[1] ? row->fields[1] : "";
		entry.backend_entity = row->fields[2] ? row->fields[2] : "";
		entry.comment = (row->cnt > 3 && row->fields[3]) ? row->fields[3] : "";
		ldap_mapping.push_back(entry);
	}

	// Sort by priority (ascending)
	std::sort(ldap_mapping.begin(), ldap_mapping.end(),
		[](const LDAPMappingEntry& a, const LDAPMappingEntry& b) {
			return a.priority < b.priority;
		});
}

SQLite3_result* Okta_LDAP_Plugin::dump_table_mysql_ldap_mapping() {
	// Caller holds rdlock or wrlock
	SQLite3_result *result = new SQLite3_result(4);
	result->add_column_definition(SQLITE_INTEGER, "priority");
	result->add_column_definition(SQLITE_TEXT, "frontend_entity");
	result->add_column_definition(SQLITE_TEXT, "backend_entity");
	result->add_column_definition(SQLITE_TEXT, "comment");

	for (const auto& entry : ldap_mapping) {
		char priority_buf[16];
		snprintf(priority_buf, sizeof(priority_buf), "%d", entry.priority);
		char *fields[4];
		fields[0] = priority_buf;
		fields[1] = const_cast<char*>(entry.frontend_entity.c_str());
		fields[2] = const_cast<char*>(entry.backend_entity.c_str());
		fields[3] = const_cast<char*>(entry.comment.c_str());
		result->add_row(fields);
	}

	return result;
}

SQLite3_result* Okta_LDAP_Plugin::dump_table_pgsql_ldap_mapping() {
	// Shared mapping — same data as mysql_ldap_mapping
	return dump_table_mysql_ldap_mapping();
}

uint64_t Okta_LDAP_Plugin::get_ldap_mapping_runtime_checksum() {
	// Simple checksum based on mapping contents
	uint64_t hash = 0;
	for (const auto& entry : ldap_mapping) {
		// Simple additive hash — not cryptographic, just for cluster sync
		for (char c : entry.frontend_entity) hash = hash * 31 + c;
		for (char c : entry.backend_entity) hash = hash * 31 + c;
		hash = hash * 31 + entry.priority;
	}
	return hash;
}

// -----------------------------------------------------------------------
// Statistics
// -----------------------------------------------------------------------

SQLite3_result* Okta_LDAP_Plugin::SQL3_getStats() {
	SQLite3_result *result = new SQLite3_result(2);
	result->add_column_definition(SQLITE_TEXT, "Variable_Name");
	result->add_column_definition(SQLITE_TEXT, "Variable_Value");

	auto add_stat = [&](const char *name, uint64_t val) {
		char val_buf[32];
		snprintf(val_buf, sizeof(val_buf), "%llu", (unsigned long long)val);
		char *fields[2];
		fields[0] = const_cast<char*>(name);
		fields[1] = val_buf;
		result->add_row(fields);
	};

	add_stat("Okta_LDAP_cache_hits", stats.cache_hits.load(std::memory_order_relaxed));
	add_stat("Okta_LDAP_cache_misses", stats.cache_misses.load(std::memory_order_relaxed));
	add_stat("Okta_LDAP_cache_expired", stats.cache_expired.load(std::memory_order_relaxed));
	add_stat("Okta_LDAP_ldap_bind_success", stats.ldap_bind_success.load(std::memory_order_relaxed));
	add_stat("Okta_LDAP_ldap_bind_failure", stats.ldap_bind_failure.load(std::memory_order_relaxed));
	add_stat("Okta_LDAP_ldap_bind_timeout", stats.ldap_bind_timeout.load(std::memory_order_relaxed));
	add_stat("Okta_LDAP_ldap_connect_errors", stats.ldap_connect_errors.load(std::memory_order_relaxed));

	// Cache size
	pthread_rwlock_rdlock(&cache_lock);
	uint64_t cache_size = auth_cache.size();
	pthread_rwlock_unlock(&cache_lock);
	add_stat("Okta_LDAP_cache_entries", cache_size);

	// Active connections
	pthread_rwlock_rdlock(&conn_lock);
	uint64_t total_conns = 0;
	for (const auto& pair : conn_tracker) {
		total_conns += pair.second.current_connections;
	}
	pthread_rwlock_unlock(&conn_lock);
	add_stat("Okta_LDAP_active_frontend_connections", total_conns);

	return result;
}

// -----------------------------------------------------------------------
// Version
// -----------------------------------------------------------------------

void Okta_LDAP_Plugin::print_version() {
	fprintf(stderr, "Okta LDAP Authentication Plugin version %s\n", OKTA_LDAP_PLUGIN_VERSION);
}

// -----------------------------------------------------------------------
// Plugin entry point — exported symbol for dlopen/dlsym
// -----------------------------------------------------------------------

extern "C" {
	MySQL_LDAP_Authentication* create_MySQL_LDAP_Authentication_func() {
		return new Okta_LDAP_Plugin();
	}
}
