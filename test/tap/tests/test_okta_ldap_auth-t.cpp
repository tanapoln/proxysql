/**
 * @file test_okta_ldap_auth-t.cpp
 * @brief Unit tests for the Okta LDAP Authentication Plugin.
 * @details Tests plugin internals via dlopen() without requiring a live Okta/LDAP
 *          server or running ProxySQL instance. Covers:
 *            - Plugin loading and factory function
 *            - Admin variable get/set/list
 *            - LDAP mapping table load/dump
 *            - Frontend connection tracking (increase/decrease/limits)
 *            - Stats counters
 *            - dump_all_users output
 *            - print_version
 *
 *  Does NOT test actual LDAP bind (requires Okta). The lookup() path that hits
 *  the LDAP server is tested in integration tests with a real Okta environment.
 */

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <dlfcn.h>

// Must define cred_username_type before MySQL_LDAP_Authentication.hpp
enum cred_username_type { USERNAME_BACKEND, USERNAME_FRONTEND, USERNAME_NONE };

#include "sqlite3db.h"
#include "MySQL_LDAP_Authentication.hpp"

// Minimal TAP implementation for standalone build
static int tap_test_num = 0;
static int tap_plan_count = 0;

void plan(int n) {
	tap_plan_count = n;
	printf("1..%d\n", n);
}

void ok(bool cond, const char *fmt, ...) {
	tap_test_num++;
	va_list ap;
	va_start(ap, fmt);
	char buf[4096];
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	printf("%s %d - %s\n", cond ? "ok" : "not ok", tap_test_num, buf);
}

void diag(const char *fmt, ...) {
	va_list ap;
	va_start(ap, fmt);
	char buf[4096];
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	printf("# %s\n", buf);
}

// Factory function type
typedef MySQL_LDAP_Authentication* create_MySQL_LDAP_Authentication_t();

// Helper: build a SQLite3_result that mimics mysql_ldap_mapping rows
// Columns: priority, frontend_entity, backend_entity, comment
SQLite3_result* make_mapping_result(
	const std::vector<std::tuple<int, std::string, std::string, std::string>>& rows
) {
	SQLite3_result *result = new SQLite3_result(4);
	result->add_column_definition(SQLITE_INTEGER, "priority");
	result->add_column_definition(SQLITE_TEXT, "frontend_entity");
	result->add_column_definition(SQLITE_TEXT, "backend_entity");
	result->add_column_definition(SQLITE_TEXT, "comment");

	for (const auto& [prio, fe, be, comment] : rows) {
		char prio_buf[16];
		snprintf(prio_buf, sizeof(prio_buf), "%d", prio);
		char *fields[4];
		fields[0] = prio_buf;
		fields[1] = const_cast<char*>(fe.c_str());
		fields[2] = const_cast<char*>(be.c_str());
		fields[3] = const_cast<char*>(comment.c_str());
		result->add_row(fields);
	}

	return result;
}

int main(int argc, char** argv) {
	// Determine plugin path from argv or default
	const char *plugin_path = NULL;
	if (argc > 1) {
		plugin_path = argv[1];
	} else {
		// Try default location
		plugin_path = "binaries/proxysql_okta_ldap_auth.dylib";
	}

	plan(29);

	// ===================================================================
	// 1. Load plugin via dlopen
	// ===================================================================
	diag("=== Loading plugin from: %s ===", plugin_path);

	void *handle = dlopen(plugin_path, RTLD_NOW);
	ok(handle != NULL, "dlopen() succeeds - %s", handle ? "loaded" : dlerror());
	if (!handle) {
		diag("Cannot continue without plugin. Aborting.");
		return 1;
	}

	// ===================================================================
	// 2. Resolve factory function
	// ===================================================================
	auto factory = (create_MySQL_LDAP_Authentication_t*)dlsym(handle, "create_MySQL_LDAP_Authentication_func");
	ok(factory != NULL, "dlsym(create_MySQL_LDAP_Authentication_func) resolves");
	if (!factory) {
		dlclose(handle);
		return 1;
	}

	// ===================================================================
	// 3. Create plugin instance
	// ===================================================================
	MySQL_LDAP_Authentication *plugin = factory();
	ok(plugin != NULL, "Factory function returns non-NULL instance");
	if (!plugin) {
		dlclose(handle);
		return 1;
	}

	// ===================================================================
	// 4. print_version (should not crash)
	// ===================================================================
	plugin->print_version();
	ok(true, "print_version() completes without crash");

	// ===================================================================
	// 5. Admin variables — get_variables_list
	// ===================================================================
	char **varlist = plugin->get_variables_list();
	ok(varlist != NULL, "get_variables_list() returns non-NULL");

	int var_count = 0;
	if (varlist) {
		while (varlist[var_count]) var_count++;
	}
	ok(var_count >= 9, "At least 9 variables returned (got %d)", var_count);

	// Check that variable names have "ldap_" prefix
	bool has_prefix = true;
	for (int i = 0; i < var_count; i++) {
		if (strncmp(varlist[i], "ldap_", 5) != 0) {
			has_prefix = false;
			diag("Variable '%s' missing 'ldap_' prefix", varlist[i]);
		}
	}
	ok(has_prefix, "All variable names have 'ldap_' prefix");

	// Free variable list
	for (int i = 0; i < var_count; i++) free(varlist[i]);
	free(varlist);

	// ===================================================================
	// 6. Admin variables — has_variable
	// ===================================================================
	ok(plugin->has_variable("ldap_okta_url"), "has_variable('ldap_okta_url') returns true");
	ok(plugin->has_variable("ldap_okta_cache_ttl"), "has_variable('ldap_okta_cache_ttl') returns true");
	ok(plugin->has_variable("okta_enabled"), "has_variable('okta_enabled') returns true (without prefix)");
	ok(!plugin->has_variable("ldap_nonexistent"), "has_variable('ldap_nonexistent') returns false");

	// ===================================================================
	// 7. Admin variables — get/set
	// ===================================================================
	{
		char *val = plugin->get_variable((char*)"ldap_okta_cache_ttl");
		ok(val != NULL && strcmp(val, "3600") == 0,
			"Default okta_cache_ttl is '3600' (got '%s')", val ? val : "NULL");
		if (val) free(val);
	}

	{
		bool set_ok = plugin->set_variable((char*)"ldap_okta_url", (char*)"ldaps://test.ldap.okta.com");
		ok(set_ok, "set_variable('ldap_okta_url', 'ldaps://test.ldap.okta.com') returns true");

		char *val = plugin->get_variable((char*)"ldap_okta_url");
		ok(val != NULL && strcmp(val, "ldaps://test.ldap.okta.com") == 0,
			"get_variable returns updated value '%s'", val ? val : "NULL");
		if (val) free(val);
	}

	{
		bool set_fail = plugin->set_variable((char*)"ldap_nonexistent", (char*)"value");
		ok(!set_fail, "set_variable for unknown variable returns false");
	}

	{
		char *val = plugin->get_variable((char*)"ldap_okta_default_backend_user");
		ok(val != NULL && strcmp(val, "okta_shared") == 0,
			"Default backend user is 'okta_shared' (got '%s')", val ? val : "NULL");
		if (val) free(val);
	}

	// ===================================================================
	// 8. LDAP Mapping — load and dump
	// ===================================================================
	{
		SQLite3_result *mapping = make_mapping_result({
			{100, "alice@company.com", "okta_admin", "admin user"},
			{200, "bob@company.com",   "okta_readonly", "read only"},
			{999, "@everyone",         "okta_shared", "default fallback"},
		});

		plugin->wrlock();
		plugin->load_mysql_ldap_mapping(mapping);
		plugin->wrunlock();
		delete mapping;

		// Dump and verify
		plugin->wrlock();
		SQLite3_result *dumped = plugin->dump_table_mysql_ldap_mapping();
		plugin->wrunlock();

		ok(dumped != NULL, "dump_table_mysql_ldap_mapping returns non-NULL");
		ok(dumped && dumped->rows_count == 3,
			"Dumped mapping has 3 rows (got %d)", dumped ? dumped->rows_count : -1);

		if (dumped && dumped->rows_count == 3) {
			// Should be sorted by priority ascending
			auto *row0 = dumped->rows[0];
			ok(strcmp(row0->fields[1], "alice@company.com") == 0,
				"First row (priority 100) is alice@company.com");
		} else {
			ok(false, "Skipped row check — unexpected row count");
		}

		delete dumped;
	}

	// ===================================================================
	// 9. Checksum — should be non-zero with mapping loaded
	// ===================================================================
	{
		uint64_t checksum = plugin->get_ldap_mapping_runtime_checksum();
		ok(checksum != 0, "Checksum is non-zero with mapping loaded (got %llu)",
			(unsigned long long)checksum);
	}

	// ===================================================================
	// 10. Frontend connection tracking
	// ===================================================================
	{
		int remaining;

		// Increase connections for user
		remaining = plugin->increase_frontend_user_connections((char*)"testuser@co.com", NULL);
		ok(remaining > 0, "increase_frontend_user_connections: remaining=%d (expected >0)", remaining);

		// Increase again
		int remaining2 = plugin->increase_frontend_user_connections((char*)"testuser@co.com", NULL);
		ok(remaining2 == remaining - 1,
			"Second increase: remaining=%d (expected %d)", remaining2, remaining - 1);

		// Decrease
		plugin->decrease_frontend_user_connections((char*)"testuser@co.com");

		// Increase to verify it went back up
		int remaining3 = plugin->increase_frontend_user_connections((char*)"testuser@co.com", NULL);
		ok(remaining3 == remaining2,
			"After decrease+increase: remaining=%d (expected %d)", remaining3, remaining2);

		// Decrease all to clean up
		plugin->decrease_frontend_user_connections((char*)"testuser@co.com");
		plugin->decrease_frontend_user_connections((char*)"testuser@co.com");
	}

	// ===================================================================
	// 11. dump_all_users
	// ===================================================================
	{
		// Add a tracked user first
		plugin->increase_frontend_user_connections((char*)"dump_test_user@co.com", NULL);

		auto result = plugin->dump_all_users();
		ok(result != nullptr, "dump_all_users returns non-null");
		ok(result && result->rows_count >= 1,
			"dump_all_users has at least 1 row (got %d)", result ? result->rows_count : 0);

		plugin->decrease_frontend_user_connections((char*)"dump_test_user@co.com");
	}

	// ===================================================================
	// 12. Stats
	// ===================================================================
	{
		SQLite3_result *stats = plugin->SQL3_getStats();
		ok(stats != NULL, "SQL3_getStats returns non-NULL");

		int stat_count = stats ? stats->rows_count : 0;
		ok(stat_count >= 8, "At least 8 stat rows (got %d)", stat_count);

		if (stats) {
			bool found_cache_hits = false;
			for (auto *row : stats->rows) {
				if (row->fields[0] && strstr(row->fields[0], "cache_hits")) {
					found_cache_hits = true;
				}
			}
			ok(found_cache_hits, "Stats include 'cache_hits' metric");
			delete stats;
		} else {
			ok(false, "Skipped stats content check");
		}
	}

	// ===================================================================
	// 13. lookup with plugin disabled — should return NULL
	// ===================================================================
	{
		plugin->set_variable((char*)"ldap_okta_enabled", (char*)"false");

		bool use_ssl = false;
		int hg = -1;
		char *schema = NULL;
		bool schema_locked = false, txn_persist = false, ff = false;
		int max_conn = 0;
		void *sha1 = NULL;
		char *attrs = NULL;
		char *backend_user = NULL;

		char *result = plugin->lookup(
			(char*)"test@company.com", (char*)"password",
			USERNAME_FRONTEND,
			&use_ssl, &hg, &schema, &schema_locked,
			&txn_persist, &ff, &max_conn, &sha1, &attrs, &backend_user
		);
		ok(result == NULL, "lookup() returns NULL when plugin is disabled");

		// Re-enable
		plugin->set_variable((char*)"ldap_okta_enabled", (char*)"true");
	}

	// ===================================================================
	// Cleanup
	// ===================================================================
	delete plugin;
	dlclose(handle);

	diag("=== All tests completed ===");

	return 0;
}
