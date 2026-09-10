-- active users
SELECT
    `name`,
    'from where',
    CASE WHEN enabled = 1 THEN 'yes' ELSE 'no' END AS state
FROM
    `user`;
