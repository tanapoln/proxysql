#!/bin/bash
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE USER monitor WITH PASSWORD 'monitor_pass';
    GRANT CONNECT ON DATABASE testdb TO monitor;

    CREATE TABLE IF NOT EXISTS test_table (
        id SERIAL PRIMARY KEY,
        name VARCHAR(255) NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );
    INSERT INTO test_table (name) VALUES ('pgsql_test_row');
EOSQL
