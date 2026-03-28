-- MySQL Instance 2: hosts db3 and db4

-- Create databases
CREATE DATABASE IF NOT EXISTS db3;
CREATE DATABASE IF NOT EXISTS db4;

-- Create backend users
CREATE USER IF NOT EXISTS 'okta_shared'@'%' IDENTIFIED WITH mysql_native_password BY 'okta_backend_pass';
GRANT ALL PRIVILEGES ON db3.* TO 'okta_shared'@'%';
GRANT ALL PRIVILEGES ON db4.* TO 'okta_shared'@'%';

CREATE USER IF NOT EXISTS 'testuser'@'%' IDENTIFIED WITH mysql_native_password BY 'testpass';
GRANT ALL PRIVILEGES ON db3.* TO 'testuser'@'%';
GRANT ALL PRIVILEGES ON db4.* TO 'testuser'@'%';

CREATE USER IF NOT EXISTS 'monitor'@'%' IDENTIFIED WITH mysql_native_password BY 'monitor_pass';
GRANT USAGE, REPLICATION CLIENT ON *.* TO 'monitor'@'%';

FLUSH PRIVILEGES;

-- Create test tables
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
