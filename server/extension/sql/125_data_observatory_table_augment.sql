--
-- Temporary server functions which should live in OBS.
--
CREATE TYPE table_augment_data as (schemaname text, tabname text, servername text, colnames text[], coltypes text[]);


CREATE OR REPLACE FUNCTION _OBS_AugmentMeasureServer2(username text, useruuid text, input_schema text, dbname text, host text, table_name text, column_name text, tag_name text, normalize text default null, timespan text DEFAULT null, geometry_level text DEFAULT null)
RETURNS table_augment_data
AS $$
DECLARE
  fdw_server text;
  fdw_import_schema text;
  connection_str json;
  import_foreign_schema_q text;
  epoch_timestamp text;
  grant_local_table_q text;
  grant_local_schema_q text;
BEGIN

  SELECT extract(epoch from now() at time zone 'utc')::int INTO epoch_timestamp;
  fdw_server := 'fdw_server_' || username || '_' || epoch_timestamp;
  fdw_import_schema:= fdw_server;

  -- Build connection string to import table from client
  connection_str := '{"server":{"extensions":"postgis", "dbname":"'
    || dbname ||'", "host":"' || host ||'", "port":"5432"}, "users":{"public"'
    || ':{"user":"' || useruuid ||'", "password":""} } }';

  -- Configure FDW for the client
  EXECUTE 'SELECT cartodb._CDB_Setup_FDW(''' || fdw_server || ''', $2::json)' USING fdw_server, connection_str ;

  -- Temporary schema created for each user import to avoid table name collisions
  EXECUTE 'CREATE SCHEMA IF NOT EXISTS ' || fdw_import_schema;

  -- Import target table
  import_foreign_schema_q := 'IMPORT FOREIGN SCHEMA "'|| input_schema ||'" LIMIT TO ('
                || table_name || ') FROM SERVER "' || fdw_server || '" INTO '
                || fdw_import_schema || ';';
  EXECUTE import_foreign_schema_q;

  grant_local_table_q = 'GRANT SELECT ON "' || fdw_import_schema || '".' || table_name || ' TO fdw_user;';
  grant_local_schema_q = 'GRANT USAGE ON SCHEMA "' || fdw_import_schema || '" TO fdw_user;';
  EXECUTE grant_local_table_q;
  EXECUTE grant_local_schema_q;

  RETURN (fdw_import_schema::text, table_name::text, fdw_server::text, Array['total_pop']::text[],Array['double precision']::text[]);

EXCEPTION
  WHEN others THEN
    RAISE NOTICE '[DS Server] Something failed (errcode: %, errm: %)', SQLSTATE, SQLERRM;
    -- Disconnect user imported table. Delete schema and FDW server.
    EXECUTE 'DROP FOREIGN TABLE IF EXISTS ' || fdw_import_schema || '.' || table_name;
    EXECUTE 'DROP SCHEMA IF EXISTS ' || fdw_import_schema || ' CASCADE';
    EXECUTE 'DROP SERVER ' || fdw_server || ' CASCADE;';
    RETURN (null, null, null, null, null);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


CREATE OR REPLACE FUNCTION _OBS_AugmentMeasureServer2Results(table_schema text, table_name text, tag_name text, normalize text default null, timespan text DEFAULT null, geometry_level text DEFAULT null)
RETURNS SETOF record
AS $$
DECLARE
  data_query text;
  rec RECORD;
BEGIN

    data_query := '(WITH _areas AS(SELECT ST_Area(a.the_geom::geography)'
        || '/ (1000 * 1000) as fraction, a.geoid, b.cartodb_id FROM '
        || 'observatory.obs_85328201013baa14e8e8a4a57a01e6f6fbc5f9b1 as a, '
        || table_schema || '.' || table_name || ' AS b '
        || 'WHERE b.the_geom && a.the_geom ), values AS (SELECT geoid, '
        || tag_name
        || ' FROM observatory.obs_3e7cc9cfd403b912c57b42d5f9195af9ce2f3cdb ) '
        || 'SELECT sum('
        || tag_name
        || '/fraction)::numeric as '
        || tag_name
        || ', cartodb_id::int FROM _areas, values '
        || 'WHERE values.geoid = _areas.geoid GROUP BY cartodb_id);';

    FOR rec IN EXECUTE data_query
    LOOP
        RETURN NEXT rec;
    END LOOP;
    RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


CREATE OR REPLACE FUNCTION _OBS_DropForeignData(table_schema text, table_name text, servername text)
RETURNS boolean
AS $$
BEGIN
    EXECUTE 'DROP FOREIGN TABLE IF EXISTS "' || table_schema || '".' || table_name;
    EXECUTE 'DROP SCHEMA IF EXISTS ' || table_schema || ' CASCADE';
    EXECUTE 'DROP SERVER ' || servername || ' CASCADE;';
    RETURN true;
EXCEPTION
    WHEN others THEN
        RAISE NOTICE '----- OOPS: SOMETHING FAILED IN SERVER WHEN WIPING FDW DATA %, errm: %)', SQLSTATE, SQLERRM;
        RETURN false;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
