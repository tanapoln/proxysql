CREATE USER IF NOT EXISTS 'okta_shared'@'%' IDENTIFIED WITH mysql_native_password BY 'okta_backend_pass';
GRANT ALL PRIVILEGES ON testdb.* TO 'okta_shared'@'%';

CREATE USER IF NOT EXISTS 'monitor'@'%' IDENTIFIED WITH mysql_native_password BY 'monitor_pass';
GRANT USAGE, REPLICATION CLIENT ON *.* TO 'monitor'@'%';

GRANT ALL PRIVILEGES ON testdb.* TO 'testuser'@'%';

FLUSH PRIVILEGES;

USE testdb;
CREATE TABLE IF NOT EXISTS test_table (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
INSERT INTO test_table (name) VALUES ('mysql_test_row');
