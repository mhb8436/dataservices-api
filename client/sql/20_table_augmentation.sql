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
        # Call to augment server
        # TODO: Edit signature to call to data_services_server explicitly
        foreign_metadata = plpy.execute("SELECT server, tabname FROM _OBS_AugmentWithMeasureServer('{0}'::text, '{1}'::text, '{2}'::text, '{3}'::text, '{4}'::text, '{5}'::text, '{6}'::text, '{7}'::text, '{8}'::text, '{9}'::text');".format(username, input_schema, dbname, hostname, table_name, column_name, tag_name, normalize, timespan, geometry_level))

        foreign_schema = foreign_metadata[0]["schema"]
        foreign_table = foreign_metadata[0]["tabname"]

        #TODO: Check for errors in _OBS_AugmentWithMeasureFDW
        if foreign_table is None:
          return False

        plpy.execute("SELECT _connect_augmented_table('{0}'::text, '{1}'::text)".format(foreign_schema, foreign_table))

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
          plpy.execute('SELECT _wipe_augmented_local_table(\'\"{0}\"\'::text, \'{1}\'::text)'.format(foreign_schema, foreign_table))
          # Clean local table
          plpy.execute('SELECT _wipe_augmented_foreign_table(\'\"{0}\"\'::text, \'{1}\'::text)'.format(foreign_schema, foreign_table))
          return True
$$ LANGUAGE plpythonu;
