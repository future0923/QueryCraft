INSERT INTO `admin_user` (`name`, `status`)
VALUES ('Alice', 1), ('Bob', 0)
ON DUPLICATE KEY UPDATE `status` = VALUES(`status`);

UPDATE `admin_user` AS u
JOIN `admin_role` AS r ON r.`id` = u.`role_id`
SET u.`status` = 0
WHERE r.`name` = 'disabled'
LIMIT 100;

DELETE u
FROM `admin_user` AS u
JOIN `admin_role` AS r ON r.`id` = u.`role_id`
WHERE r.`name` = 'obsolete';

REPLACE INTO `settings` (`key`, `value`) VALUES ('theme', 'dark');
