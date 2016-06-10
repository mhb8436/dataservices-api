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
  input_schema text;
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

  IF orgname IS NULL OR orgname = '' OR orgname = '""' THEN
    input_schema := username;
  ELSE
    input_schema := 'public';
  END IF;

  SELECT current_database() INTO dbname;
  SELECT _get_db_host() INTO hostname;

  SELECT _OBS_AugmentWithMeasure(username, input_schema, dbname, hostname, table_name, column_name, tag_name, normalize, timespan, geometry_level) INTO result;

  RETURN result;
END;
$$ LANGUAGE 'plpgsql' SECURITY DEFINER;

--
-- Internal function to augment a table with a measure column. Handles the 
-- communication with the Data Services server and updates the local table
-- of the user with data obtained through FDW.
--


CREATE OR REPLACE FUNCTION _OBS_AugmentWithMeasure(username text, input_schema text, dbname text, hostname text, table_name text, column_name text, tag_name text, normalize text default null, timespan text DEFAULT null, geometry_level text DEFAULT null)
RETURNS boolean AS $$
    try:
        local_schema = 'fdw_' + username

        # Call to augment server
        foreign_metadata = plpy.execute("SELECT server, tabname FROM _OBS_AugmentWithMeasureFDW('{0}'::text, '{1}'::text, '{2}'::text, '{3}'::text, '{4}'::text, '{5}'::text, '{6}'::text, '{7}'::text, '{8}'::text, '{9}'::text');".format(username, input_schema, dbname, hostname, table_name, column_name, tag_name, normalize, timespan, geometry_level))

        foreign_schema = foreign_metadata[0]["schema"]
        foreign_table = foreign_metadata[0]["tabname"]

        #TODO: Check for errors in _OBS_AugmentWithMeasureFDW
        if foreign_table is None:
            return False

        plpy.execute("SELECT _connect_augmented_table('{0}'::text, '{1}'::text, '{2}'::text)".format(foreign_schema, foreign_table, local_schema))

        # Get name and type of columns augmented in the server
        new_columns = plpy.execute('SELECT a.attname as name, format_type(a.atttypid, a.atttypmod) AS data_type FROM pg_attribute a, pg_class b WHERE a.attrelid = b.relfilenode AND a.attrelid = \'\"{0}\".{1}\'::regclass AND a.attnum > 0 AND NOT a.attisdropped AND a.attname NOT LIKE \'cartodb_id\' ORDER BY a.attnum;'.format(foreign_schema, foreign_table))

        plpy.warning('[Client] Connected foreign table {0}.{1}'.format(foreign_schema, foreign_table))

        # Add the augmented column to the user table
        augmented_column = plpy.execute("SELECT _add_augmented_column('{0}'::text, '{1}'::text, '{2}'::text) as name".format(table_name, new_columns[0]["name"], new_columns[0]["data_type"]))[0]["name"]

        # Update the user table with the augmented data
        plpy.execute('UPDATE {0} SET {1} = augmented.{2} FROM "{3}".{4} as augmented WHERE {0}.cartodb_id = augmented.cartodb_id;'.format(table_name, augmented_column, new_columns[0]["name"], foreign_schema, foreign_table))

    except Exception as e:
        plpy.warning('Error trying to augment table {0}'.format(e))
        return False
    finally:
        if foreign_table:
            plpy.warning('[Client] Closing and dropping foreign table {0}.{1}'.format(foreign_schema,foreign_table))
            # Clean remote table
            plpy.execute('SELECT _disconnect_foreign_table(\'\"{0}\"\'::text, \'{1}\'::text)'.format(local_schema, foreign_table))
            # Clean local table
            plpy.execute('SELECT _wipe_augmented_foreign_table(\'\"{0}\"\'::text, \'{1}\'::text)'.format(foreign_schema, foreign_table))
            return True
$$ LANGUAGE plpythonu;


--
-- Internal function to connect to a foreign table
--

CREATE OR REPLACE FUNCTION _connect_augmented_table(foreign_schema text, foreign_table text, local_schema text)
RETURNS boolean AS $$
DECLARE
  fdw_server text;
  query_import text;
  schema_query text;
  connection_str json;
BEGIN

  fdw_server := 'fdw_server_' || username;

  SELECT cdb_dataservices_client._augmentation_server_conn_json() INTO connection_str;

  -- Configure FDW to Augmentation Server
  EXECUTE 'SELECT cartodb._CDB_Setup_FDW('''|| fdw_server ||''', $1::json)' USING connection_str ;

  -- Must create schema. CHECK IF NOT NEEDED bc of CDBSetup
  schema_query := 'CREATE SCHEMA IF NOT EXISTS "' || local_schema ||'"';
  EXECUTE schema_query;

  -- Import result table
  query_import := 'IMPORT FOREIGN SCHEMA "' || foreign_schema || '" LIMIT TO ('|| foreign_table ||') '
                || ' FROM SERVER ''' || fdw_server || ''' INTO "' || local_schema || '";';
  EXECUTE query_import;

  RETURN true;
EXCEPTION
  WHEN others THEN
    RAISE NOTICE '[Client] Something failed when connecting the foreign table (errcode: %, errm: %)', SQLSTATE, SQLERRM;
    RETURN false;
END;
$$ LANGUAGE plpgsql;

--
-- Internal function to disconnect foreign table
--

CREATE OR REPLACE FUNCTION _disconnect_foreign_table(local_schema text, foreign_table text)
RETURNS boolean AS $$
DECLARE
  drop_query text;
  drop_schema text;
BEGIN
  -- Drop foreign table
  drop_query :='DROP FOREIGN TABLE IF EXISTS '|| local_schema ||'.' || foreign_table ;
  EXECUTE drop_query;
  
  -- Drop schema
  drop_schema := 'DROP SCHEMA IF EXISTS ' || local_schema;
  EXECUTE drop_schema;

  RETURN true;
EXCEPTION
  WHEN others THEN
    RAISE NOTICE '[Client] Something failed in foreign table wipe (errcode: %, errm: %)', SQLSTATE, SQLERRM;
    RETURN false;
END;
$$ LANGUAGE plpgsql;

--
-- Function to trigger augmented table deletion in the server after 
-- local augmentation has finished.
--

CREATE OR REPLACE FUNCTION _wipe_augmented_foreign_table(foreign_schema text, foreign_table text)
RETURNS boolean AS $$
    CONNECT _server_conn_str();
    SELECT * FROM _wipe_user_augmented_table(foreign_schema::text, foreign_schema::text);
$$ LANGUAGE plproxy;

--
-- Internal function that alters the user table to add a new column
--

CREATE OR REPLACE FUNCTION _add_augmented_column(table_name text, column_name text, data_type text)
RETURNS text AS $$
DECLARE
  alter_str text;
  new_column_name text;
  epoch_timestamp text;
BEGIN
  SELECT extract(epoch from now() at time zone 'utc')::int INTO epoch_timestamp;
  new_column_name := column_name || '_aug_' || epoch_timestamp;

  -- Add column to table
  alter_str := 'ALTER TABLE ' || table_name || ' ADD COLUMN ' || new_column_name || ' ' || data_type;
  EXECUTE alter_str;

  RETURN new_column_name;
EXCEPTION
  WHEN others THEN
    RAISE NOTICE '[Client] The augmented column could not be included in your table. (errcode: %, errm: %)', SQLSTATE, SQLERRM;
    RETURN null;
END;
$$ LANGUAGE plpgsql;
