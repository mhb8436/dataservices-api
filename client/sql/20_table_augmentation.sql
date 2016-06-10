--
-- Public function to augment a table with a new measure column.
-- This function checks that the user is authenticated and calls to 
-- the internal function which will manage the process.
--

CREATE OR REPLACE FUNCTION OBS_AugmentWithMeasure(table_name text, column_name text, tag_name text, normalize text default null, timespan text DEFAULT null, geometry_level text DEFAULT null)
RETURNS boolean AS $$
DECLARE
  username text;
  orgname text;
  dbname text;
  hostname text;
  result boolean;
BEGIN
  IF session_user = 'publicuser' OR session_user ~ 'cartodb_publicuser_*' THEN
    RAISE EXCEPTION 'The api_key must be provided';
  END IF;

  SELECT u, o INTO username, orgname FROM cdb_dataservices_client._cdb_entity_config() AS (u text, o text);
  -- JSON value stored "" is taken as literal
  IF username IS NULL OR username = '' OR username = '""' THEN
    RAISE EXCEPTION 'Username is a mandatory argument';
  END IF;

  SELECT current_database() INTO dbname;
  SELECT _get_db_host() INTO hostname;

  SELECT _OBS_AugmentWithMeasure(username, orgname, dbname, hostname, table_name, column_name, tag_name, normalize, timespan, geometry_level) INTO result;

  RETURN result;
END;
$$ LANGUAGE 'plpgsql' SECURITY DEFINER;
