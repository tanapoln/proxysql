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

	plan(58);

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

	// The plugin returns BARE variable names (e.g. "okta_url"); the ProxySQL
	// admin framework adds the "ldap-" module prefix when exposing them via
	// SHOW LDAP VARIABLES / global_variables. Verify that contract here: the
	// names must be bare "okta_*" and must NOT already carry the "ldap-" prefix.
	bool names_are_bare = true;
	for (int i = 0; i < var_count; i++) {
		if (strncmp(varlist[i], "ldap-", 5) == 0 || strncmp(varlist[i], "okta_", 5) != 0) {
			names_are_bare = false;
			diag("Variable '%s' is not a bare 'okta_*' name", varlist[i]);
		}
	}
	ok(names_are_bare, "Variable names are bare 'okta_*' (admin framework adds the 'ldap-' prefix)");

	// Free variable list
	for (int i = 0; i < var_count; i++) free(varlist[i]);
	free(varlist);

	// ===================================================================
	// 6. Admin variables — has_variable
	// ===================================================================
	// has_variable operates on bare names — the admin framework strips "ldap-".
	ok(plugin->has_variable("okta_url"), "has_variable('okta_url') returns true");
	ok(plugin->has_variable("okta_cache_ttl"), "has_variable('okta_cache_ttl') returns true");
	ok(!plugin->has_variable("ldap-okta_url"), "has_variable('ldap-okta_url') returns false (prefix is stripped by framework, not stored)");
	ok(!plugin->has_variable("nonexistent"), "has_variable('nonexistent') returns false");

	// ===================================================================
	// 7. Admin variables — get/set
	// ===================================================================
	{
		char *val = plugin->get_variable((char*)"okta_cache_ttl");
		ok(val != NULL && strcmp(val, "3600") == 0,
			"Default okta_cache_ttl is '3600' (got '%s')", val ? val : "NULL");
		if (val) free(val);
	}

	{
		bool set_ok = plugin->set_variable((char*)"okta_url", (char*)"ldaps://test.ldap.okta.com");
		ok(set_ok, "set_variable('okta_url', 'ldaps://test.ldap.okta.com') returns true");

		char *val = plugin->get_variable((char*)"okta_url");
		ok(val != NULL && strcmp(val, "ldaps://test.ldap.okta.com") == 0,
			"get_variable returns updated value '%s'", val ? val : "NULL");
		if (val) free(val);
	}

	{
		bool set_fail = plugin->set_variable((char*)"nonexistent", (char*)"value");
		ok(!set_fail, "set_variable for unknown variable returns false");
	}

	{
		char *val = plugin->get_variable((char*)"okta_default_backend_user");
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
	// 9b. Per-protocol mapping isolation.
	// Load DIFFERENT data into the MySQL and PgSQL mapping tables and verify
	// each dump returns its OWN data. Regression for the shared-vector bug
	// where the plugin kept a single mapping list, so loading one protocol
	// clobbered the other and dump_table_pgsql_ldap_mapping() returned MySQL
	// rows. With a stub SQLite3 this needs no real ProxySQL or LDAP server.
	// ===================================================================
	{
		SQLite3_result *m = make_mapping_result({
			{100, "alice@company.com", "okta_mysql", "mysql only"},
		});
		SQLite3_result *p = make_mapping_result({
			{100, "alice@company.com", "okta_pgsql",  "pgsql only"},
			{200, "bob@company.com",   "okta_pgsql2", "pgsql only"},
		});
		plugin->wrlock();
		plugin->load_mysql_ldap_mapping(m);
		plugin->load_pgsql_ldap_mapping(p);   // must NOT clobber the MySQL table
		plugin->wrunlock();
		delete m;
		delete p;

		plugin->wrlock();
		SQLite3_result *dm = plugin->dump_table_mysql_ldap_mapping();
		SQLite3_result *dp = plugin->dump_table_pgsql_ldap_mapping();
		plugin->wrunlock();

		ok(dm && dm->rows_count == 1,
			"MySQL mapping dump has 1 row (got %d)", dm ? dm->rows_count : -1);
		ok(dp && dp->rows_count == 2,
			"PgSQL mapping dump has 2 rows (got %d) — not clobbered by the MySQL load",
			dp ? dp->rows_count : -1);

		// The same frontend user must resolve to a DIFFERENT backend per protocol.
		const char *mysql_be = (dm && dm->rows_count >= 1) ? dm->rows[0]->fields[2] : "";
		const char *pgsql_be = "";
		if (dp) {
			for (auto *r : dp->rows) {
				if (r->fields[1] && strcmp(r->fields[1], "alice@company.com") == 0) {
					pgsql_be = r->fields[2];
				}
			}
		}
		ok(mysql_be && strcmp(mysql_be, "okta_mysql") == 0,
			"MySQL dump resolves alice -> okta_mysql (got '%s')", mysql_be ? mysql_be : "NULL");
		ok(pgsql_be && strcmp(pgsql_be, "okta_pgsql") == 0,
			"PgSQL dump resolves alice -> okta_pgsql (got '%s') — isolated from MySQL table",
			pgsql_be ? pgsql_be : "NULL");

		if (dm) delete dm;
		if (dp) delete dp;
	}

	// ===================================================================
	// 9c. Per-protocol backend resolution — the path the MySQL/PgSQL protocol
	// handlers use instead of querying the admin DB. The same frontend user must
	// resolve to a different backend per protocol; an unmapped user falls through
	// to @everyone; an exact match beats @everyone regardless of priority; and
	// when neither matches the result is NULL (caller uses the default user).
	// resolve_*_backend take the lock internally, so the test must NOT hold it.
	// ===================================================================
	{
		SQLite3_result *m = make_mapping_result({
			{100, "alice@company.com", "okta_m_alice", "m"},
			{999, "@everyone",         "okta_m_all",   "m"},
		});
		SQLite3_result *p = make_mapping_result({
			{100, "alice@company.com", "okta_p_alice", "p"},
			{999, "@everyone",         "okta_p_all",   "p"},
		});
		plugin->wrlock();
		plugin->load_mysql_ldap_mapping(m);
		plugin->load_pgsql_ldap_mapping(p);
		plugin->wrunlock();
		delete m;
		delete p;

		char *mb = plugin->resolve_mysql_backend((char*)"alice@company.com");
		char *pb = plugin->resolve_pgsql_backend((char*)"alice@company.com");
		ok(mb && strcmp(mb, "okta_m_alice") == 0,
			"resolve_mysql_backend(alice) -> okta_m_alice (got '%s')", mb ? mb : "NULL");
		ok(pb && strcmp(pb, "okta_p_alice") == 0,
			"resolve_pgsql_backend(alice) -> okta_p_alice — isolated per protocol (got '%s')", pb ? pb : "NULL");
		if (mb) free(mb);
		if (pb) free(pb);

		char *me = plugin->resolve_mysql_backend((char*)"nobody@company.com");
		ok(me && strcmp(me, "okta_m_all") == 0,
			"resolve falls through to @everyone for an unmapped user (got '%s')", me ? me : "NULL");
		if (me) free(me);

		// @everyone given a *lower* priority number than the exact entry.
		SQLite3_result *m2 = make_mapping_result({
			{1,   "@everyone",       "okta_all_hi", "m"},
			{100, "vip@company.com", "okta_vip",    "m"},
		});
		plugin->wrlock();
		plugin->load_mysql_ldap_mapping(m2);
		plugin->wrunlock();
		delete m2;
		char *vip = plugin->resolve_mysql_backend((char*)"vip@company.com");
		ok(vip && strcmp(vip, "okta_vip") == 0,
			"exact mapping beats @everyone regardless of priority (got '%s')", vip ? vip : "NULL");
		if (vip) free(vip);

		// No exact entry and no @everyone -> NULL.
		SQLite3_result *m3 = make_mapping_result({
			{100, "only@company.com", "okta_only", "m"},
		});
		plugin->wrlock();
		plugin->load_mysql_ldap_mapping(m3);
		plugin->wrunlock();
		delete m3;
		char *none = plugin->resolve_mysql_backend((char*)"absent@company.com");
		ok(none == NULL, "resolve returns NULL when neither an exact entry nor @everyone matches");
		if (none) free(none);
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
	// 10b. Connection-limit semantics must match MySQL_Authentication:
	// increase_frontend_user_connections() returns the number of free slots
	// BEFORE incrementing, increments ONLY when there is room, and when full
	// returns 0 without incrementing. The caller rejects when the return is
	// <= 0, so exactly `max` connections are admitted (not max-1), and a
	// rejected over-limit attempt (which never calls decrease) must not leak
	// the counter. Regression for the unconditional `current_connections++`.
	// ===================================================================
	{
		plugin->set_variable((char*)"okta_default_max_connections", (char*)"2");
		const char *u = "cap_user@co.com";

		int i1 = plugin->increase_frontend_user_connections((char*)u, NULL); // room: 2 free, used->1
		int i2 = plugin->increase_frontend_user_connections((char*)u, NULL); // room: 1 free, used->2
		ok(i1 == 2 && i2 == 1,
			"increase returns free slots before incrementing (got %d,%d, expected 2,1)", i1, i2);

		int i3 = plugin->increase_frontend_user_connections((char*)u, NULL); // FULL: 0, no increment
		ok(i3 == 0,
			"exactly max=2 admitted; the 3rd reports no free slot (got %d, expected 0)", i3);

		int i4 = plugin->increase_frontend_user_connections((char*)u, NULL); // still FULL: 0, no leak
		ok(i4 == 0,
			"repeated over-limit attempts stay at 0 — counter does not leak (got %d, expected 0)", i4);

		// Release one real connection; a slot must free up despite the rejected
		// attempts above (which must not have incremented the counter).
		plugin->decrease_frontend_user_connections((char*)u);
		int i5 = plugin->increase_frontend_user_connections((char*)u, NULL);
		ok(i5 == 1,
			"a slot frees up after decrease, unaffected by the over-limit attempts (got %d, expected 1)", i5);

		// Clean up and restore the default.
		plugin->decrease_frontend_user_connections((char*)u);
		plugin->decrease_frontend_user_connections((char*)u);
		plugin->set_variable((char*)"okta_default_max_connections", (char*)"1000");
	}

	// ===================================================================
	// 10c. A runtime change to okta_default_max_connections must apply to an
	// already-tracked user on its next connection. The per-user cap was
	// previously initialized lazily and then frozen, so changing the global
	// default (and LOAD LDAP VARIABLES TO RUNTIME) had no effect on users that
	// had already connected once.
	// ===================================================================
	{
		const char *u = "recap_user@co.com";
		int mc1 = 0, mc2 = 0;

		plugin->set_variable((char*)"okta_default_max_connections", (char*)"5");
		plugin->increase_frontend_user_connections((char*)u, &mc1);   // tracked at 5
		ok(mc1 == 5, "initial max_connections reported as 5 (got %d)", mc1);

		plugin->set_variable((char*)"okta_default_max_connections", (char*)"10");
		plugin->increase_frontend_user_connections((char*)u, &mc2);   // must pick up 10
		ok(mc2 == 10,
			"runtime max_connections change applies to an already-tracked user (got %d, expected 10)", mc2);

		plugin->decrease_frontend_user_connections((char*)u);
		plugin->decrease_frontend_user_connections((char*)u);
		plugin->set_variable((char*)"okta_default_max_connections", (char*)"1000");
	}

	// ===================================================================
	// 10d. conn_tracker must not grow without bound. LDAP users are discovered
	// dynamically and their entries are kept after disconnect (so idle-but-recent
	// users still appear in stats_mysql_users), but entries with no active
	// connections must be reclaimed once the table gets large. Connect+disconnect
	// many DISTINCT users (each left at 0 active connections); the tracked count
	// must stay well below the number of distinct users seen.
	// N must exceed the plugin's internal cap (OKTA_LDAP_CONN_TRACKER_MAX_ENTRIES).
	// ===================================================================
	{
		const int N = 10050;
		char ubuf[64];
		for (int i = 0; i < N; i++) {
			snprintf(ubuf, sizeof(ubuf), "growth_%d@co.com", i);
			plugin->increase_frontend_user_connections(ubuf, NULL);
			plugin->decrease_frontend_user_connections(ubuf);   // leaves entry at 0 active
		}
		auto result = plugin->dump_all_users();
		int rows = result ? result->rows_count : -1;
		ok(rows >= 0 && rows < N,
			"conn_tracker bounded: %d distinct users seen, %d tracked (must be < %d)", N, rows, N);
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
		plugin->set_variable((char*)"okta_enabled", (char*)"false");

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
		plugin->set_variable((char*)"okta_enabled", (char*)"true");
	}

	// ===================================================================
	// 14. Empty password must be rejected WITHOUT attempting an LDAP bind
	// (defense in depth vs. the RFC 4513 unauthenticated-bind auth bypass).
	// Point the plugin at an unreachable URL: an empty password must
	// short-circuit (no bind => bind/connect stats unchanged), while a
	// non-empty password DOES attempt a bind (stats move) — proving the
	// short-circuit is specific to the empty case.
	// ===================================================================
	{
		plugin->set_variable((char*)"okta_enabled", (char*)"true");
		plugin->set_variable((char*)"okta_url", (char*)"ldap://127.0.0.1:1");
		plugin->set_variable((char*)"okta_bind_timeout_ms", (char*)"1000");

		auto bind_attempts = [&]() -> long {
			SQLite3_result *s = plugin->SQL3_getStats();
			long v = 0;
			if (s) {
				for (auto *row : s->rows) {
					if (row->fields[0] && (
						strcmp(row->fields[0], "Okta_LDAP_ldap_bind_failure") == 0 ||
						strcmp(row->fields[0], "Okta_LDAP_ldap_connect_errors") == 0 ||
						strcmp(row->fields[0], "Okta_LDAP_ldap_bind_timeout") == 0)) {
						v += atol(row->fields[1]);
					}
				}
				delete s;
			}
			return v;
		};

		bool e_ssl=false; int e_hg=-1; char *e_schema=NULL; bool e_sl=false,e_tp=false,e_ff=false;
		int e_mc=0; void *e_sha1=NULL; char *e_attrs=NULL; char *e_be=NULL;

		long before = bind_attempts();
		char *r_empty = plugin->lookup((char*)"u@x", (char*)"", USERNAME_FRONTEND,
			&e_ssl,&e_hg,&e_schema,&e_sl,&e_tp,&e_ff,&e_mc,&e_sha1,&e_attrs,&e_be);
		long after_empty = bind_attempts();
		ok(r_empty == NULL, "lookup() with an empty password returns NULL");
		ok(after_empty == before,
			"empty password rejected WITHOUT an LDAP bind (bind/connect stats %ld == %ld)", after_empty, before);
		if (r_empty) free(r_empty);

		long before2 = bind_attempts();
		char *r_real = plugin->lookup((char*)"u@x", (char*)"somepass", USERNAME_FRONTEND,
			&e_ssl,&e_hg,&e_schema,&e_sl,&e_tp,&e_ff,&e_mc,&e_sha1,&e_attrs,&e_be);
		long after_real = bind_attempts();
		ok(r_real == NULL, "lookup() with an unreachable LDAP returns NULL");
		ok(after_real > before2,
			"a non-empty password DOES attempt a bind (stats %ld -> %ld) — short-circuit is empty-specific", before2, after_real);
		if (r_real) free(r_real);

		plugin->set_variable((char*)"okta_url", (char*)"");
	}

	// ===================================================================
	// 15. Admin-variable validation: integer variables reject negative /
	// non-numeric input (a negative okta_default_max_connections locks out all
	// LDAP users; a negative okta_bind_timeout_ms makes an invalid timeval;
	// etc.), and a rejected set must NOT change the stored value.
	// ===================================================================
	{
		ok(plugin->set_variable((char*)"okta_default_max_connections", (char*)"250") == true,
			"valid okta_default_max_connections accepted");
		ok(plugin->set_variable((char*)"okta_default_max_connections", (char*)"-1") == false,
			"negative okta_default_max_connections rejected");
		ok(plugin->set_variable((char*)"okta_cache_ttl", (char*)"notanumber") == false,
			"non-numeric okta_cache_ttl rejected");
		ok(plugin->set_variable((char*)"okta_bind_timeout_ms", (char*)"-5") == false,
			"negative okta_bind_timeout_ms rejected");
		ok(plugin->set_variable((char*)"okta_default_hostgroup", (char*)"-2") == false,
			"negative okta_default_hostgroup rejected");
		char *v = plugin->get_variable((char*)"okta_default_max_connections");
		ok(v && strcmp(v, "250") == 0,
			"a rejected set leaves the previous valid value intact (got '%s')", v ? v : "NULL");
		if (v) free(v);
		plugin->set_variable((char*)"okta_default_max_connections", (char*)"1000");
		plugin->set_variable((char*)"okta_cache_ttl", (char*)"3600");
		plugin->set_variable((char*)"okta_bind_timeout_ms", (char*)"5000");
		plugin->set_variable((char*)"okta_default_hostgroup", (char*)"0");
	}

	// ===================================================================
	// 16. okta_user_dn_format must contain a %s placeholder — without one,
	// every username collapses to a single fixed bind DN (fails open).
	// ===================================================================
	{
		ok(plugin->set_variable((char*)"okta_user_dn_format", (char*)"uid=%s,ou=users,%s") == true,
			"dn_format with a placeholder accepted");
		ok(plugin->set_variable((char*)"okta_user_dn_format", (char*)"uid=fixed,ou=users,dc=x") == false,
			"dn_format without a placeholder rejected");
	}

	// ===================================================================
	// 17. The mapping runtime checksum must reflect comment changes, so cluster
	// nodes detect comment-only edits (the comment was previously excluded).
	// ===================================================================
	{
		SQLite3_result *ca_res = make_mapping_result({ {100, "alice@company.com", "okta_shared", "comment-A"} });
		SQLite3_result *cb_res = make_mapping_result({ {100, "alice@company.com", "okta_shared", "comment-B"} });
		plugin->wrlock(); plugin->load_mysql_ldap_mapping(ca_res); plugin->wrunlock();
		uint64_t ca = plugin->get_ldap_mapping_runtime_checksum();
		plugin->wrlock(); plugin->load_mysql_ldap_mapping(cb_res); plugin->wrunlock();
		uint64_t cb = plugin->get_ldap_mapping_runtime_checksum();
		ok(ca != cb, "checksum changes when only the comment changes (cluster detects comment edits)");
		delete ca_res; delete cb_res;
	}

	// ===================================================================
	// Cleanup
	// ===================================================================
	delete plugin;
	dlclose(handle);

	diag("=== All tests completed ===");

	return 0;
}
