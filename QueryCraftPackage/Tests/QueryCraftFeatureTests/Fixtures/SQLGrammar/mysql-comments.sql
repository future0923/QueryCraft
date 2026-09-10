# MySQL hash comment
SELECT 'semi;colon', "double;quoted", `odd;identifier`
FROM `admin_user`; -- ordinary comment

/* block comment containing ; and SELECT */
SELECT /*+ MAX_EXECUTION_TIME(1000) */ COUNT(*)
FROM `admin_user`;

/*!80000 SET SESSION sql_mode = 'STRICT_TRANS_TABLES' */;
