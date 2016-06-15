CREATE TYPE table_augment_data as (schemaname text, tabname text, servername text, colnames text[], coltypes text[]);

--
-- Public function to augment a table with a new measure column.
-- This function checks that the user is authenticated and calls to 
-- the internal function which will manage the process.
--

CREATE OR REPLACE FUNCTION OBS_AugmentMeasure2(table_name text, column_name text, tag_name text, normalize text default null, timespan text DEFAULT null, geometry_level text DEFAULT null)
RETURNS boolean AS $$
DECLARE
  username text;
  useruuid text;
  orgname text;
  dbname text;
  hostname text;
  input_schema text;
  result boolean;
BEGIN
  IF session_user = 'publicuser' OR session_user ~ 'cartodb_publicuser_*' THEN
    RAISE EXCEPTION 'The api_key must be provided';
  END IF;

  SELECT session_user INTO useruuid;

  SELECT u, o INTO username, orgname FROM cdb_dataservices_client._cdb_entity_config() AS (u text, o text);
  -- JSON value stored "" is taken as literal
  IF username IS NULL OR username = '' OR username = '""' THEN
    RAISE EXCEPTION 'Username is a mandatory argument';
  END IF;

  IF orgname IS NULL OR orgname = '' OR orgname = '""' THEN
    input_schema := 'public';
  ELSE
    input_schema := username;
  END IF;

  SELECT current_database() INTO dbname;
  SELECT _get_db_host() INTO hostname;

  SELECT _OBS_AugmentMeasure2(username::text, useruuid::text, input_schema::text, dbname::text, hostname::text, table_name::text, column_name::text, tag_name::text, normalize::text, timespan::text, geometry_level::text) INTO result;

  RETURN true;
END;
$$ LANGUAGE 'plpgsql' SECURITY DEFINER;

--
-- Internal function to augment a table with a measure column. Handles the 
-- communication with the Data Services server and updates the local table
-- of the user with data obtained through FDW.
--



CREATE OR REPLACE FUNCTION _OBS_AugmentMeasure2(username text, useruuid text, input_schema text, dbname text, hostname text, table_name text, column_name text, tag_name text, normalize text default null, timespan text DEFAULT null, geometry_level text DEFAULT null)
RETURNS boolean AS $$
    try:
        # Call to augment server, colnames and coltypes are arrays
        #fdw_metadata, connectUserTable
        augment_metadata = plpy.execute("SELECT schemaname, tabname, servername, colnames, coltypes FROM _OBS_AugmentMeasureServer2('{0}'::text, '{1}'::text, '{2}'::text, '{3}'::text, '{4}'::text, '{5}'::text, '{6}'::text, '{7}'::text, '{8}'::text, '{9}'::text, '{10}'::text);".format(username, useruuid, input_schema, dbname, hostname, table_name, column_name, tag_name, normalize, timespan, geometry_level))
        # divide in setup fdw + metadata
        epoch_timestamp = plpy.execute("SELECT extract(epoch from now() at time zone 'utc')::int as epoch")[0]["epoch"]
        schemaname = augment_metadata[0]["schemaname"]
        tabname = augment_metadata[0]["tabname"]
        servername = augment_metadata[0]["servername"]
        colnames_array = augment_metadata[0]["colnames"]
        coltypes_array = augment_metadata[0]["coltypes"]
        new_table_name = table_name + '_augmented_' + str(epoch_timestamp)

        plpy.execute("CREATE TABLE {0} AS (SELECT results.{1}, user_table.* FROM {3} as user_table, _OBS_AugmentMeasureServer2Results('{2}'::text, '{3}'::text, '{4}'::text, '{5}'::text, '{6}'::text, '{7}'::text) as results({1} numeric, cartodb_id int) WHERE results.cartodb_id = user_table.cartodb_id)".format(new_table_name, colnames_array[0] ,schemaname, tabname, tag_name, normalize, timespan, geometry_level))
        plpy.execute('ALTER TABLE {0} OWNER TO "{1}";'.format(new_table_name, useruuid))
        wiped = plpy.execute("SELECT _OBS_DropForeignData('{0}'::text, '{1}'::text, '{2}'::text)".format(schemaname, tabname, servername))

        return True
    except Exception as e:
        plpy.warning('Error trying to augment table {0}'.format(e))
        if tabname:
            wiped = plpy.execute("SELECT _OBS_DropForeignData('{0}'::text, '{1}'::text, '{2}'::text)".format(schemaname, tabname, servername))
        return False
$$ LANGUAGE plpythonu;


CREATE OR REPLACE FUNCTION _OBS_AugmentMeasureServer2(username text, useruuid text, input_schema text, dbname text, hostname text, table_name text, column_name text, tag_name text, normalize text, timespan text, geometry_level text)
RETURNS table_augment_data AS $$
    CONNECT _server_conn_str();
    SELECT schemaname, tabname, servername, colnames, coltypes FROM _OBS_AugmentMeasureServer2(username::text, useruuid::text, input_schema::text, dbname:: text, hostname::text, table_name::text, column_name::text, tag_name::text, normalize::text, timespan::text, geometry_level::text);
$$ LANGUAGE plproxy;

CREATE OR REPLACE FUNCTION _OBS_AugmentMeasureServer2Results(table_schema text, table_name text, tag_name text, normalize text, timespan text, geometry_level text)
RETURNS SETOF record AS $$
    CONNECT _server_conn_str();
$$ LANGUAGE plproxy;

CREATE OR REPLACE FUNCTION _OBS_DropForeignData(table_schema text, table_name text, server_name text)
RETURNS boolean AS $$
    CONNECT _server_conn_str();
$$ LANGUAGE plproxy;
