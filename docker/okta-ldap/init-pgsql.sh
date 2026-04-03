#!/bin/bash
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- ProxySQL PgSQL monitor requires md5 auth (scram-sha-256 not supported)
    SET password_encryption = 'md5';
    CREATE USER monitor WITH PASSWORD 'monitor_pass';
    RESET password_encryption;
    GRANT CONNECT ON DATABASE testdb TO monitor;
EOSQL

# Allow md5 auth for monitor user (must come before the default scram-sha-256 rule)
PG_HBA="${PGDATA}/pg_hba.conf"
# Insert md5 rule for monitor before the catch-all rule
sed -i '/^host all all all/i host all monitor all md5' "$PG_HBA"
# Reload PostgreSQL to pick up pg_hba.conf changes
pg_ctl reload -D "$PGDATA"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE TABLE IF NOT EXISTS test_table (
        id SERIAL PRIMARY KEY,
        name VARCHAR(255) NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );
    INSERT INTO test_table (name) VALUES ('pgsql_test_row');
EOSQL
