SELECT
    u.id,
    u.name,
    COUNT(o.id) AS order_count
FROM
    users AS u
LEFT JOIN orders AS o
    ON o.user_id = u.id
WHERE
    u.status = 'active'
    AND u.deleted_at IS NULL
GROUP BY
    u.id,
    u.name
ORDER BY
    order_count DESC
LIMIT
    100;
