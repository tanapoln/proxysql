/**
 * Minimal stub of SQLite3_result, SQLite3_row, SQLite3_column for standalone
 * test compilation. Only implements the subset used by the test and the plugin.
 */

#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <vector>
#include <memory>
#include <pthread.h>

// Include the real header — the sqlite3 types come from the actual sqlite3.h
#include "sqlite3.h"
#include "sqlite3db.h"

// ---- SQLite3_column ----

SQLite3_column::SQLite3_column(int a, const char *b) {
	datatype = a;
	name = strdup(b);
}

SQLite3_column::~SQLite3_column() {
	if (name) free(name);
}

// ---- SQLite3_row ----

SQLite3_row::SQLite3_row(int c) {
	cnt = c;
	ds = 0;
	sizes = (int *)calloc(c, sizeof(int));
	fields = (char **)calloc(c, sizeof(char *));
	data = NULL;
}

SQLite3_row::~SQLite3_row() {
	if (data) free(data);
	if (sizes) free(sizes);
	if (fields) free(fields);
}

unsigned long long SQLite3_row::get_size() {
	unsigned long long s = sizeof(SQLite3_row);
	s += cnt * sizeof(int);
	s += cnt * sizeof(char *);
	s += ds;
	return s;
}

void SQLite3_row::add_fields(char **_fields) {
	int t = 0;
	for (int i = 0; i < cnt; i++) {
		if (_fields[i]) {
			t += strlen(_fields[i]);
		}
	}
	t += cnt; // null terminators
	data = (char *)malloc(t);
	char *o = data;
	for (int i = 0; i < cnt; i++) {
		if (_fields[i]) {
			int l = strlen(_fields[i]);
			sizes[i] = l;
			memcpy(o, _fields[i], l);
			o[l] = '\0';
			fields[i] = o;
			o += l + 1;
		} else {
			sizes[i] = 0;
			fields[i] = NULL;
			*o = '\0';
			o++;
		}
	}
	ds = t;
}

// Stub: not used in test, but needed for link
void SQLite3_row::add_fields(sqlite3_stmt *) {}

// ---- SQLite3_result ----

SQLite3_result::SQLite3_result() {
	columns = 0;
	rows_count = 0;
	enabled_mutex = false;
}

SQLite3_result::SQLite3_result(int num_columns, bool en_mutex) {
	columns = num_columns;
	rows_count = 0;
	enabled_mutex = en_mutex;
	if (en_mutex) {
		pthread_mutex_init(&m, NULL);
	}
}

SQLite3_result::SQLite3_result(SQLite3_result *src) {
	columns = src->columns;
	rows_count = 0;
	enabled_mutex = false;
	for (auto *col : src->column_definition) {
		add_column_definition(col->datatype, col->name);
	}
	for (auto *row : src->rows) {
		add_row(row);
	}
}

SQLite3_result::~SQLite3_result() {
	for (auto *col : column_definition) delete col;
	for (auto *row : rows) delete row;
	if (enabled_mutex) {
		pthread_mutex_destroy(&m);
	}
}

unsigned long long SQLite3_result::get_size() {
	unsigned long long s = sizeof(SQLite3_result);
	for (auto *row : rows) s += row->get_size();
	return s;
}

void SQLite3_result::add_column_definition(int a, const char *b) {
	SQLite3_column *col = new SQLite3_column(a, b);
	column_definition.push_back(col);
}

int SQLite3_result::add_row(char **_fields) {
	SQLite3_row *row = new SQLite3_row(columns);
	row->add_fields(_fields);
	if (enabled_mutex) pthread_mutex_lock(&m);
	rows.push_back(row);
	rows_count++;
	if (enabled_mutex) pthread_mutex_unlock(&m);
	return rows_count;
}

int SQLite3_result::add_row(SQLite3_row *old_row) {
	return add_row(old_row->fields);
}

// Stubs for methods not needed by the test
int SQLite3_result::add_row(sqlite3_stmt *, bool) { return 0; }
int SQLite3_result::add_row(const char *, ...) { return 0; }
SQLite3_result::SQLite3_result(sqlite3_stmt *) : SQLite3_result() {}
SQLite3_result::SQLite3_result(sqlite3_stmt *, int *, unsigned int, unsigned int) : SQLite3_result() {}
char* SQLite3_result::checksum() { return strdup(""); }
uint64_t SQLite3_result::raw_checksum() { return 0; }
void SQLite3_result::dump_to_stderr() {}

// Stub for stmt_deleter_t
void stmt_deleter_t::operator()(sqlite3_stmt* x) const {
	if (x) sqlite3_finalize(x);
}
