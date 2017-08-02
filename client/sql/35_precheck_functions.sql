CREATE OR REPLACE FUNCTION cdb_dataservices_client._OBS_PreCheck(
    source_query text,
    parameters jsonb
) RETURNS boolean AS $$
DECLARE
    errors text[];
    geoms record;
BEGIN
    -- How to securize the source_query?
    errors := (ARRAY[])::TEXT[];
    FOR geoms IN
    EXECUTE FORMAT('SELECT ST_GeometryType(the_geom) as geom_type,
                    bool_and(st_isvalid(the_geom)) as valid,
                    avg(st_npoints(the_geom)) as avg_vertex
                    FROM (%s) as _source GROUP BY ST_GeometryType(the_geom)', source_query)
    LOOP
        IF geoms.geom_type NOT IN ('ST_Polygon', 'ST_MultiPolygon', 'ST_Point') THEN
            errors := array_append(errors, format($data$'Geometry type %s not supported'$data$, data.geom_type));
        END IF;

        IF geoms.valid IS FALSE THEN
            errors := array_append(errors, 'There are invalid geometries in the input data, please fix them');
        END IF;

        IF geoms.avg_vertex > 500 THEN
            errors := array_append(errors, 'The average number of geometries vertex is greater than 500, please simply them');
        END IF;
    END LOOP;

    IF CARDINALITY(errors) > 0 THEN
        RAISE EXCEPTION '%', format('%s', errors);
    END IF;

    -- Call the OBS_CheckFunction passing geometry type and parameters
END;
$$ LANGUAGE 'plpgsql';
