WITH ranked_users AS (
  SELECT
    u.`id`,
    u.`department_id`,
    ROW_NUMBER() OVER (
      PARTITION BY u.`department_id`
      ORDER BY u.`created_at` DESC
    ) AS `row_number`
  FROM `admin_user` AS u
)
SELECT `id`, `department_id`
FROM ranked_users
WHERE `row_number` <= 3;

WITH RECURSIVE category_tree AS (
  SELECT `id`, `parent_id`, 0 AS `depth`
  FROM `category`
  WHERE `parent_id` IS NULL
  UNION ALL
  SELECT c.`id`, c.`parent_id`, p.`depth` + 1
  FROM `category` AS c
  JOIN category_tree AS p ON p.`id` = c.`parent_id`
)
SELECT * FROM category_tree;

SELECT
  payload -> '$.customer.id' AS customer_json,
  payload ->> '$.customer.name' AS customer_name
FROM `audit_log`;
