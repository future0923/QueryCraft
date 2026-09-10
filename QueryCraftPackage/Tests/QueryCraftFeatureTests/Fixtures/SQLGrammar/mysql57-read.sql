SELECT
  u.`id`,
  u.`name`,
  JSON_EXTRACT(u.`settings`, '$.locale') AS `locale`
FROM `test_estate_business`.`admin_user` AS u
LEFT JOIN `test_estate_business`.`admin_role` AS r
  ON r.`id` = u.`role_id`
WHERE u.`status` = 1
ORDER BY u.`id` DESC
LIMIT 20 OFFSET 10;

SELECT `id`, `name`
FROM `admin_user`
LIMIT 10, 20;

SHOW FULL TABLES FROM `test_estate_business`;
DESCRIBE `test_estate_business`.`admin_user`;
EXPLAIN SELECT * FROM `admin_user` WHERE `id` = 1;
