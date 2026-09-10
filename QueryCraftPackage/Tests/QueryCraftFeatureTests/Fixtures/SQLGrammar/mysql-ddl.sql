CREATE TABLE `audit_log` (
  `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `payload` JSON NOT NULL,
  `customer_name` VARCHAR(255)
    GENERATED ALWAYS AS (JSON_UNQUOTE(JSON_EXTRACT(`payload`, '$.customer.name'))) STORED,
  `created_at` TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (`id`),
  KEY `idx_customer_name` (`customer_name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

ALTER TABLE `audit_log`
  ADD COLUMN `request_id` BINARY(16) NULL AFTER `id`,
  ADD UNIQUE KEY `uk_request_id` (`request_id`),
  ALGORITHM=INPLACE,
  LOCK=NONE;

CREATE INDEX `idx_created_at` ON `audit_log` (`created_at` DESC);
DROP INDEX `idx_created_at` ON `audit_log`;
