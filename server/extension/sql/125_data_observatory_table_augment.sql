--
-- Temporary server functions which should live in OBS.
--

CREATE OR REPLACE FUNCTION _wipe_user_augmented_table(fdw_schema text, table_name text)
RETURNS boolean AS $$
DECLARE
  drop_query text;
  users text;
BEGIN
  SELECT session_user INTO users;
  RAISE NOTICE 'USER: % [DS Server] Dropping augmented table %.%', users, fdw_schema, table_name;
  drop_query := 'DROP TABLE IF EXISTS ' || fdw_schema || '.' || table_name;
  RETURN true;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION _OBS_AugmentWithMeasureFDW(username text, useruuid text, input_schema text, dbname text, host text, table_name text, column_name text, tag_name text, normalize text default null, timespan text DEFAULT null, geometry_level text DEFAULT null)
RETURNS table_augment_metadata
AS $$
DECLARE
  temp_table_name text;
  fdw_server text;
  fdw_schema text;
  qualified_temp_table text;
  connection_str json;
  query_import text;
  schema_q text;
  grant_query text;
  grant2_query text;
  return_query text;
  obs_result boolean;
BEGIN

  temp_table_name := 'aug_' || table_name || '_tmp';
  fdw_server := 'fdw_server' || username;
  fdw_schema:= 'fdw_' || username;

  connection_str := '{"server":{"extensions":"postgis", "dbname":"'
    || dbname ||'", "host":"' || host ||'", "port":"5432"}, "users":{"public"'
    || ':{"user":"' || useruuid ||'", "password":""} } }';

  RAISE NOTICE 'connection string: %', connection_str;
  RAISE NOTICE '[DS Server] SETUPPPP';

  -- Configure FDW
  EXECUTE 'SELECT cartodb._CDB_Setup_FDW(''' || fdw_server || ''', $2::json)' USING fdw_server, connection_str ;

  schema_q := 'CREATE SCHEMA ' || fdw_schema;
  EXECUTE schema_q;

  -- Import target table
  query_import := 'IMPORT FOREIGN SCHEMA public LIMIT TO ('
                || table_name
                || ') FROM SERVER "' || fdw_server || '" INTO "'
                || fdw_schema
                || '";';

  RAISE NOTICE '[DS Server] IMPORTTT';

  EXECUTE query_import;

  -- Call to Observatory function that will generate a table with a given name
  RAISE NOTICE '[DS Server] Augmenting data in the Observatory';

  SELECT observatory._OBS_AugmentWithMeasureFDW(fdw_schema, table_name, temp_table_name, column_name, tag_name, normalize, timespan, geometry_level) INTO obs_result;

  IF obs_result THEN
    -- TODO: add index on cartodb_id
    grant_query = 'GRANT SELECT ON "' || fdw_schema || '".' || temp_table_name || ' TO fdw_user;';
    grant2_query = 'GRANT USAGE ON SCHEMA "' || fdw_schema || '" TO fdw_user;';
    EXECUTE grant_query;
    EXECUTE grant2_query;
  END IF;

  RAISE NOTICE '[DS Server] OBS result: %', obs_result;

  -- Disconnect user table
  RAISE NOTICE '[DS Server] Dropping foreign table';
  EXECUTE 'DROP FOREIGN TABLE IF EXISTS "' || fdw_schema || '".' || table_name;

  -- Return server and table information
  RETURN (fdw_schema, temp_table_name);

EXCEPTION
  WHEN others THEN
    RAISE NOTICE '[DS Server] Something failed (errcode: %, errm: %)', SQLSTATE, SQLERRM;
    RAISE NOTICE '[DS Server] Dropping foreign table';
    EXECUTE 'DROP FOREIGN TABLE IF EXISTS "' || fdw_schema || '".' || table_name;
    RETURN (null, null);

END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
