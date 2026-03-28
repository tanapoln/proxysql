-- MySQL Instance 1: hosts db1, db2, db3, db4, and testdb
-- db3/db4 are also on mysql2 for multi-instance testing

-- Create databases
CREATE DATABASE IF NOT EXISTS db1;
CREATE DATABASE IF NOT EXISTS db2;
CREATE DATABASE IF NOT EXISTS db3;
CREATE DATABASE IF NOT EXISTS db4;

-- Create backend users
CREATE USER IF NOT EXISTS 'okta_shared'@'%' IDENTIFIED WITH mysql_native_password BY 'okta_backend_pass';
GRANT ALL PRIVILEGES ON db1.* TO 'okta_shared'@'%';
GRANT ALL PRIVILEGES ON db2.* TO 'okta_shared'@'%';
GRANT ALL PRIVILEGES ON db3.* TO 'okta_shared'@'%';
GRANT ALL PRIVILEGES ON db4.* TO 'okta_shared'@'%';
GRANT ALL PRIVILEGES ON testdb.* TO 'okta_shared'@'%';

CREATE USER IF NOT EXISTS 'monitor'@'%' IDENTIFIED WITH mysql_native_password BY 'monitor_pass';
GRANT USAGE, REPLICATION CLIENT ON *.* TO 'monitor'@'%';

-- testuser is created by MYSQL_USER env var; grant additional privileges
GRANT ALL PRIVILEGES ON testdb.* TO 'testuser'@'%';
GRANT ALL PRIVILEGES ON db1.* TO 'testuser'@'%';
GRANT ALL PRIVILEGES ON db2.* TO 'testuser'@'%';
GRANT ALL PRIVILEGES ON db3.* TO 'testuser'@'%';
GRANT ALL PRIVILEGES ON db4.* TO 'testuser'@'%';

FLUSH PRIVILEGES;

-- Create test tables in each database
USE testdb;
CREATE TABLE IF NOT EXISTS test_table (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
INSERT INTO test_table (name) VALUES ('mysql_test_row');

USE db1;
CREATE TABLE IF NOT EXISTS items (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(255) NOT NULL
);
INSERT INTO items (name) VALUES ('db1_item');

USE db2;
CREATE TABLE IF NOT EXISTS items (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(255) NOT NULL
);
INSERT INTO items (name) VALUES ('db2_item');

USE db3;
CREATE TABLE IF NOT EXISTS items (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(255) NOT NULL
);
INSERT INTO items (name) VALUES ('db3_item');

USE db4;
CREATE TABLE IF NOT EXISTS items (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(255) NOT NULL
);
INSERT INTO items (name) VALUES ('db4_item');
