-- The purpose of this function is to obtain the DB host
-- that a FDW server would require to connect with a user DB.

-- TODO: Move DB host information to CDB_Conf to avoid this function.
CREATE OR REPLACE FUNCTION _get_db_host()
RETURNS text AS $$
DECLARE
  host text;
BEGIN
  EXECUTE 'CREATE TEMP TABLE IF NOT EXISTS db_host_temp (host text) ON COMMIT DROP';
  EXECUTE 'COPY db_host_temp from ''/etc/hostname''';
  EXECUTE 'SELECT host FROM db_host_temp' INTO host;
  RETURN host;
END;
$$ LANGUAGE plpgsql;
