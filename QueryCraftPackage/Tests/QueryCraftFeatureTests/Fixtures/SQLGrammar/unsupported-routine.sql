DELIMITER $$
CREATE PROCEDURE rebuild_cache()
BEGIN
  DELETE FROM cache_entries;
  INSERT INTO cache_entries (`key`) VALUES ('all');
END$$
DELIMITER ;
