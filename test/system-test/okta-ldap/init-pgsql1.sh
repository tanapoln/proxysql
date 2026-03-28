#!/bin/bash
set -e

# PostgreSQL Instance 1: hosts testdb (default), db1, db2, db3, db4
# The default database (testdb) is created by POSTGRES_DB env var.

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- Monitor user for ProxySQL health checks
    CREATE USER monitor WITH PASSWORD 'monitor_pass';
    GRANT CONNECT ON DATABASE testdb TO monitor;

    -- Limited user for whitelist testing (same privileges as testuser initially)
    CREATE USER limiteduser WITH PASSWORD 'limitedpass';
    GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO limiteduser;

    -- Test table in testdb
    CREATE TABLE IF NOT EXISTS test_table (
        id SERIAL PRIMARY KEY,
        name VARCHAR(255) NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );
    INSERT INTO test_table (name) VALUES ('pgsql_test_row');

    -- Create additional databases
    CREATE DATABASE db1;
    CREATE DATABASE db2;
    CREATE DATABASE db3;
    CREATE DATABASE db4;
EOSQL

# Grant connect on all databases
for db in db1 db2 db3 db4; do
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$db" <<-EOSQL
        -- Grant access
        GRANT ALL PRIVILEGES ON DATABASE ${db} TO ${POSTGRES_USER};
        GRANT CONNECT ON DATABASE ${db} TO monitor;
        GRANT CONNECT ON DATABASE ${db} TO limiteduser;

        -- Create test table
        CREATE TABLE IF NOT EXISTS items (
            id SERIAL PRIMARY KEY,
            name VARCHAR(255) NOT NULL
        );
        INSERT INTO items (name) VALUES ('${db}_item');

        -- Grant limiteduser access to tables
        GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO limiteduser;
        GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO limiteduser;
EOSQL
done
