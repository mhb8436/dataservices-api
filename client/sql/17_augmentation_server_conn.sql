--
-- Augmentation server connection config
--
-- The purpose of this function is provide to the FDW setup function a JSON with
-- the connection and user mapping details to connect with the server.

CREATE OR REPLACE FUNCTION cdb_dataservices_client._augmentation_server_conn_json()
RETURNS json AS $$
DECLARE
  db_connection_json text;
BEGIN
  SELECT cartodb.cdb_conf_getconf('fdws')->'augment' INTO db_connection_json;
  RETURN db_connection_json;
END;
$$ LANGUAGE 'plpgsql';

--
-- Augmentation server connection string for Pl/Proxy connection intended to drop temporary table.
--

CREATE OR REPLACE FUNCTION _augmentation_server_conn_str()
RETURNS text AS $$
DECLARE
  db_connection_str text;
BEGIN
  SELECT cartodb.cdb_conf_getconf('fdw_server_config')->'connection_str' INTO db_connection_str;
  SELECT trim(both '"' FROM db_connection_str) INTO db_connection_str;
  RETURN db_connection_str;
END;
$$ LANGUAGE 'plpgsql';
