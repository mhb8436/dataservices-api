--
-- Temporary server functions which should live in OBS.
--

CREATE TYPE table_augment_metadata as (schemaname text, tabname text);


CREATE TABLE augmented_datasets (table_schema text, table_name text, created_at timestamp, can_be_deleted boolean);

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
  idx_query text;
  return_query text;
  epoch_timestamp text;
  obs_result boolean;
BEGIN

  SELECT extract(epoch from now() at time zone 'utc')::int INTO epoch_timestamp;

  temp_table_name := 'aug_' || table_name || '_tmp_' || epoch_timestamp;
  fdw_server := 'fdw_server' || username;
  fdw_schema:= 'fdw_' || username;

  connection_str := '{"server":{"extensions":"postgis", "dbname":"'
    || dbname ||'", "host":"' || host ||'", "port":"5432"}, "users":{"public"'
    || ':{"user":"' || useruuid ||'", "password":""} } }';

  -- Configure FDW
  EXECUTE 'SELECT cartodb._CDB_Setup_FDW(''' || fdw_server || ''', $2::json)' USING fdw_server, connection_str ;

  schema_q := 'CREATE SCHEMA IF NOT EXISTS ' || fdw_schema;
  EXECUTE schema_q;

  -- Import target table
  query_import := 'IMPORT FOREIGN SCHEMA "'|| input_schema ||'" LIMIT TO ('
                || table_name
                || ') FROM SERVER "' || fdw_server || '" INTO "'
                || fdw_schema
                || '";';
  EXECUTE query_import;

  -- Call to Observatory function that will generate a table with a given name
  RAISE NOTICE '[DS Server] Augmenting data in the Observatory';

  SELECT observatory._OBS_AugmentWithMeasureFDW(fdw_schema, table_name, temp_table_name, column_name, tag_name, normalize, timespan, geometry_level) INTO obs_result;

  IF obs_result THEN
    INSERT INTO augmented_datasets (table_schema, table_name, created_at) VALUES (fdw_schema, temp_table_name, now());

    idx_query = 'CREATE UNIQUE INDEX cartodb_id_idx ON "' || fdw_schema || '".' || temp_table_name || ' (cartodb_id)';
    grant_query = 'ALTER TABLE "' || fdw_schema || '".' || temp_table_name || ' OWNER TO fdw_user;';
    grant2_query = 'GRANT USAGE ON SCHEMA "' || fdw_schema || '" TO fdw_user;';
    EXECUTE idx_query;
    EXECUTE grant_query;
    EXECUTE grant2_query;
  END IF;

  RAISE NOTICE '[DS Server] OBS result: %', obs_result;

  -- Disconnect user table
  EXECUTE 'DROP FOREIGN TABLE IF EXISTS "' || fdw_schema || '".' || table_name;
  -- Return server and table information
  IF obs_result THEN
    RETURN (fdw_schema, temp_table_name);
  ELSE
    RETURN (''::text, ''::text);
  END IF;

EXCEPTION
  WHEN others THEN
    RAISE NOTICE '[DS Server] Something failed (errcode: %, errm: %)', SQLSTATE, SQLERRM;
    EXECUTE 'DROP FOREIGN TABLE IF EXISTS "' || fdw_schema || '".' || table_name;
    RETURN (''::text, ''::text);

END;
$$ LANGUAGE plpgsql SECURITY DEFINER;



CREATE OR REPLACE FUNCTION _mark_user_augmented_table_deletion(fdw_schema text, tablename text)
RETURNS boolean AS $$
BEGIN
  UPDATE augmented_datasets SET can_be_deleted = true WHERE table_name = $2;
  RETURN true;
EXCEPTION
  WHEN others THEN
    RAISE NOTICE '(errcode: %, errm: %)', SQLSTATE, SQLERRM;
    RETURN false;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

