-- DROP FUNCTION IF EXISTS content.export_osm_xml(text);

CREATE OR REPLACE FUNCTION content.export_osm_xml(
	dataset_id text)
    RETURNS text
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    osm_output text;
    operation_start_time timestamp;
BEGIN
    operation_start_time := clock_timestamp();
    -- Create temporary table for datasettoexport
    CREATE TEMPORARY TABLE temp_datasettoexport (
        tdei_dataset_id TEXT PRIMARY KEY
    ) ON COMMIT DROP;
    INSERT INTO temp_datasettoexport
    SELECT d.tdei_dataset_id
    FROM content.dataset d
    WHERE d.tdei_dataset_id = dataset_id;
    CREATE INDEX idx_temp_datasettoexport ON temp_datasettoexport(tdei_dataset_id);
    RAISE NOTICE 'processing datasettoexport() completed in {%}', clock_timestamp() - operation_start_time;

    operation_start_time := clock_timestamp();
    -- Create temporary table for parsed_nodes
    CREATE TEMPORARY TABLE temp_parsed_nodes (
        node_id VARCHAR,
        geom GEOMETRY(POINT, 4326),
        lat NUMERIC,
        lon NUMERIC,
        feature_json JSONB
    ) ON COMMIT DROP;
    INSERT INTO temp_parsed_nodes
    SELECT 
        n.node_id,
        n.node_loc AS geom,
        ST_Y(n.node_loc)::NUMERIC AS lat,
        ST_X(n.node_loc)::NUMERIC AS lon,
        n.feature::JSONB AS feature_json
    FROM content.node n
    JOIN temp_datasettoexport d ON n.tdei_dataset_id = d.tdei_dataset_id;
    CREATE INDEX idx_temp_parsed_nodes_geom ON temp_parsed_nodes USING GIST (geom);
    CREATE INDEX idx_temp_parsed_nodes_node_id ON temp_parsed_nodes(node_id);
    RAISE NOTICE 'processing temp_parsed_nodes() {%}', clock_timestamp() - operation_start_time;

    operation_start_time := clock_timestamp();
    -- Create temporary table for raw_edges
    CREATE TEMPORARY TABLE temp_raw_edges (
        edge_id VARCHAR,
        feature_json JSONB
    ) ON COMMIT DROP;
    INSERT INTO temp_raw_edges
    SELECT
        e.edge_id,
        e.feature::JSONB AS feature_json
    FROM content.edge e
    JOIN temp_datasettoexport d ON e.tdei_dataset_id = d.tdei_dataset_id;
    CREATE INDEX idx_temp_raw_edges_edge_id ON temp_raw_edges(edge_id);
    RAISE NOTICE 'processing temp_raw_edges() {%}', clock_timestamp() - operation_start_time;

    operation_start_time := clock_timestamp();
    -- Create temporary table for edge_points
    CREATE TEMPORARY TABLE temp_edge_points (
        edge_id VARCHAR,
        point_index BIGINT,
        lon TEXT,
        lat TEXT,
        geom GEOMETRY(POINT, 4326)
    ) ON COMMIT DROP;
    INSERT INTO temp_edge_points
    SELECT
        el.edge_id,
        coords_index AS point_index,
        coords->>0 AS lon,
        coords->>1 AS lat,
        ST_SetSRID(ST_MakePoint((coords->>0)::DOUBLE PRECISION, (coords->>1)::DOUBLE PRECISION), 4326) AS geom
    FROM temp_raw_edges el,
        jsonb_array_elements(el.feature_json::jsonb #> '{geometry,coordinates}') WITH ORDINALITY AS coords(coords, coords_index);
    CREATE INDEX idx_temp_edge_points_edge_id ON temp_edge_points(edge_id);
    CREATE INDEX idx_temp_edge_points_geom ON temp_edge_points USING GIST (geom);
    RAISE NOTICE 'processing temp_edge_points() {%}', clock_timestamp() - operation_start_time;

    operation_start_time := clock_timestamp();
    -- Create temporary table for parsed_edge_points
    CREATE TEMPORARY TABLE temp_parsed_edge_points (
        edge_id VARCHAR,
        point_index BIGINT,
        lon TEXT,
        lat TEXT,
        geom GEOMETRY(POINT, 4326),
        final_node_id VARCHAR,
        is_new BOOLEAN
    ) ON COMMIT DROP;
    INSERT INTO temp_parsed_edge_points
    SELECT 
        ep.*,
        COALESCE(
            pn.node_id, 
            (-1 * (ABS(HASHTEXT(ep.lat || ':' || ep.lon)) + (SELECT COALESCE(ABS(MAX(CAST(node_id AS BIGINT))), 0) FROM temp_parsed_nodes)))::VARCHAR
        ) AS final_node_id,
        pn.node_id IS NULL AS is_new
    FROM temp_edge_points ep
    LEFT JOIN temp_parsed_nodes pn
        ON ST_DWithin(ST_SetSRID(ST_MakePoint(ep.lon::DOUBLE PRECISION, ep.lat::DOUBLE PRECISION), 4326), pn.geom, 1e-9);
    CREATE INDEX idx_temp_parsed_edge_points_edge_id ON temp_parsed_edge_points(edge_id);
    CREATE INDEX idx_temp_parsed_edge_points_final_node_id ON temp_parsed_edge_points(final_node_id);
    RAISE NOTICE 'processing temp_parsed_edge_points() {%}', clock_timestamp() - operation_start_time;

    operation_start_time := clock_timestamp();
    -- Create temporary table for extension_points
    CREATE TEMPORARY TABLE temp_extension_points (
        point_id VARCHAR,
        lat NUMERIC,
        lon NUMERIC,
        feature_json JSONB
    ) ON COMMIT DROP;
    INSERT INTO temp_extension_points
    SELECT 
        n.point_id,
        ST_Y(point_loc)::NUMERIC AS lat,
        ST_X(point_loc)::NUMERIC AS lon,
        n.feature::JSONB AS feature_json
    FROM content.extension_point n
    JOIN temp_datasettoexport d ON n.tdei_dataset_id = d.tdei_dataset_id;
    CREATE INDEX idx_temp_extension_points_point_id ON temp_extension_points(point_id);
    RAISE NOTICE 'processing temp_extension_points() {%}', clock_timestamp() - operation_start_time;

    operation_start_time := clock_timestamp();
    -- Create temporary table for parsed_extension_points
    CREATE TEMPORARY TABLE temp_parsed_extension_points (
        is_new BOOLEAN,
        final_node_id VARCHAR,
        lat NUMERIC,
        lon NUMERIC,
        feature_json JSONB
    ) ON COMMIT DROP;
    INSERT INTO temp_parsed_extension_points
    SELECT 
        pn.node_id IS NULL AS is_new,
        COALESCE(pn.node_id, '-1' || ROW_NUMBER() OVER (ORDER BY pp.point_id)) AS final_node_id,
        pp.lat,
        pp.lon,
        jsonb_build_object(
            'type', 'Feature',
            'geometry', jsonb_build_object(
                'type', 'Point',
                'coordinates', jsonb_build_array(pp.lon, pp.lat)
            ),
            'properties',
            (
                COALESCE((pn.feature_json->'properties'), '{}'::JSONB) - '_id' || 
                COALESCE((pp.feature_json->'properties'), '{}'::JSONB) - '_id' ||
                jsonb_build_object('_id', COALESCE(pn.node_id, '-1' || ROW_NUMBER() OVER (ORDER BY pp.point_id)))
            )
        ) AS feature_json
    FROM temp_extension_points pp
    LEFT JOIN temp_parsed_nodes pn
        ON pp.lat = pn.lat AND pp.lon = pn.lon;
    CREATE INDEX idx_temp_parsed_extension_points_final_node_id ON temp_parsed_extension_points(final_node_id);
    RAISE NOTICE 'processing temp_parsed_extension_points() {%}', clock_timestamp() - operation_start_time;

    operation_start_time := clock_timestamp();
    -- Create temporary table for raw_extension_lines
    CREATE TEMPORARY TABLE temp_raw_extension_lines (
        line_id VARCHAR,
        feature_json JSONB
    ) ON COMMIT DROP;
    INSERT INTO temp_raw_extension_lines
    SELECT
        el.line_id,
        el.feature::JSONB AS feature_json
    FROM content.extension_line el
    JOIN temp_datasettoexport d ON el.tdei_dataset_id = d.tdei_dataset_id;
    CREATE INDEX idx_temp_raw_extension_lines_line_id ON temp_raw_extension_lines(line_id);
    RAISE NOTICE 'processing temp_raw_extension_lines() {%}', clock_timestamp() - operation_start_time;

    operation_start_time := clock_timestamp();
    -- Create temporary table for extension_lines_points
    CREATE TEMPORARY TABLE temp_extension_lines_points (
        line_id VARCHAR,
        point_index BIGINT,
        lon TEXT,
        lat TEXT,
        geom GEOMETRY(POINT, 4326)
    ) ON COMMIT DROP;
    INSERT INTO temp_extension_lines_points
    SELECT
        el.line_id,
        coords_index AS point_index,
        coords->>0 AS lon,
        coords->>1 AS lat,
        ST_SetSRID(ST_MakePoint((coords->>0)::DOUBLE PRECISION, (coords->>1)::DOUBLE PRECISION), 4326) AS geom
    FROM temp_raw_extension_lines el,
        jsonb_array_elements(el.feature_json #> '{geometry,coordinates}') WITH ORDINALITY AS coords(coords, coords_index);
    CREATE INDEX idx_temp_extension_lines_points_line_id ON temp_extension_lines_points(line_id);
    CREATE INDEX idx_temp_extension_lines_points_geom ON temp_extension_lines_points USING GIST (geom);
    RAISE NOTICE 'processing temp_extension_lines_points() {%}', clock_timestamp() - operation_start_time;

    operation_start_time := clock_timestamp();
    -- Create temporary table for parsed_extension_lines
    CREATE TEMPORARY TABLE temp_parsed_extension_lines (
        line_id VARCHAR,
        point_index BIGINT,
        lon TEXT,
        lat TEXT,
        geom GEOMETRY(POINT, 4326),
        final_node_id VARCHAR,
        is_new BOOLEAN
    ) ON COMMIT DROP;
    INSERT INTO temp_parsed_extension_lines
    SELECT
        ep.*,
        COALESCE(
            pn.node_id,
            (-1 * ABS(HASHTEXT(ep.lat || ':' || ep.lon)))::VARCHAR
        ) AS final_node_id,
        pn.node_id IS NULL AS is_new
    FROM temp_extension_lines_points ep
    LEFT JOIN temp_parsed_nodes pn
        ON ST_DWithin(ST_SetSRID(ST_MakePoint(ep.lon::DOUBLE PRECISION, ep.lat::DOUBLE PRECISION), 4326), pn.geom, 1e-9);
    CREATE INDEX idx_temp_parsed_extension_lines_line_id ON temp_parsed_extension_lines(line_id);
    CREATE INDEX idx_temp_parsed_extension_lines_final_node_id ON temp_parsed_extension_lines(final_node_id);
    RAISE NOTICE 'processing temp_parsed_extension_lines() {%}', clock_timestamp() - operation_start_time;

    operation_start_time := clock_timestamp();
    -- Create temporary table for extension_polygons
    CREATE TEMPORARY TABLE temp_extension_polygons (
        polygon_id VARCHAR,
        feature_json JSONB
    ) ON COMMIT DROP;
    INSERT INTO temp_extension_polygons
    SELECT 
        p.polygon_id,
        p.feature::JSONB AS feature_json
    FROM content.extension_polygon p
    JOIN temp_datasettoexport d ON p.tdei_dataset_id = d.tdei_dataset_id;
    CREATE INDEX idx_temp_extension_polygons_polygon_id ON temp_extension_polygons(polygon_id);
    RAISE NOTICE 'processing temp_extension_polygons() {%}', clock_timestamp() - operation_start_time;

    operation_start_time := clock_timestamp();
    -- Create temporary table for single_ring_polygons
    CREATE TEMPORARY TABLE temp_single_ring_polygons (
        polygon_id VARCHAR,
        ring_index INTEGER,
        point_index BIGINT,
        lon TEXT,
        lat TEXT,
        is_multipolygon BOOLEAN,
        geom GEOMETRY(POINT, 4326)
    ) ON COMMIT DROP;
    INSERT INTO temp_single_ring_polygons
    SELECT 
        pf.polygon_id,
        1 AS ring_index,
        point_idx AS point_index,
        coord->>0 AS lon,
        coord->>1 AS lat,
        FALSE AS is_multipolygon,
        ST_SetSRID(ST_MakePoint((coord->>0)::DOUBLE PRECISION, (coord->>1)::DOUBLE PRECISION), 4326) AS geom
    FROM temp_extension_polygons pf
    CROSS JOIN LATERAL jsonb_array_elements(pf.feature_json #> '{geometry,coordinates,0}') WITH ORDINALITY AS coord(coord, point_idx)
    WHERE jsonb_array_length(pf.feature_json #> '{geometry,coordinates}') = 1;
    CREATE INDEX idx_temp_single_ring_polygons_polygon_id ON temp_single_ring_polygons(polygon_id);
    CREATE INDEX idx_temp_single_ring_polygons_geom ON temp_single_ring_polygons USING GIST (geom);
    RAISE NOTICE 'processing temp_single_ring_polygons() {%}', clock_timestamp() - operation_start_time;

    operation_start_time := clock_timestamp();
    -- Create temporary table for multi_ring_polygons
    CREATE TEMPORARY TABLE temp_multi_ring_polygons (
        polygon_id VARCHAR,
        ring_index BIGINT,
        point_index BIGINT,
        lon TEXT,
        lat TEXT,
        is_multipolygon BOOLEAN,
        geom GEOMETRY(POINT, 4326)
    ) ON COMMIT DROP;
    INSERT INTO temp_multi_ring_polygons
    SELECT 
        pf.polygon_id,
        ring_idx,
        point_idx AS point_index,
        coord->>0 AS lon,
        coord->>1 AS lat,
        TRUE AS is_multipolygon,
        ST_SetSRID(ST_MakePoint((coord->>0)::DOUBLE PRECISION, (coord->>1)::DOUBLE PRECISION), 4326) AS geom
    FROM temp_extension_polygons pf
    CROSS JOIN LATERAL jsonb_array_elements(pf.feature_json #> '{geometry,coordinates}') WITH ORDINALITY AS ring(ring_coords, ring_idx)
    CROSS JOIN LATERAL jsonb_array_elements(ring_coords) WITH ORDINALITY AS coord(coord, point_idx)
    WHERE jsonb_array_length(pf.feature_json #> '{geometry,coordinates}') > 1;
    CREATE INDEX idx_temp_multi_ring_polygons_polygon_id ON temp_multi_ring_polygons(polygon_id);
    CREATE INDEX idx_temp_multi_ring_polygons_geom ON temp_multi_ring_polygons USING GIST (geom);
    RAISE NOTICE 'processing temp_multi_ring_polygons() {%}', clock_timestamp() - operation_start_time;

    operation_start_time := clock_timestamp();
    -- Create temporary table for flattened_polygon_coords
    CREATE TEMPORARY TABLE temp_flattened_polygon_coords (
        polygon_id VARCHAR,
        ring_index BIGINT,
        point_index BIGINT,
        lon TEXT,
        lat TEXT,
        is_multipolygon BOOLEAN,
        geom GEOMETRY(POINT, 4326)
    ) ON COMMIT DROP;
    INSERT INTO temp_flattened_polygon_coords
    SELECT * FROM temp_single_ring_polygons
    UNION ALL
    SELECT * FROM temp_multi_ring_polygons;
    CREATE INDEX idx_temp_flattened_polygon_coords_polygon_id ON temp_flattened_polygon_coords(polygon_id);
    CREATE INDEX idx_temp_flattened_polygon_coords_geom ON temp_flattened_polygon_coords USING GIST (geom);
    RAISE NOTICE 'processing temp_flattened_polygon_coords() {%}', clock_timestamp() - operation_start_time;

    operation_start_time := clock_timestamp();
    -- Create temporary table for parsed_extension_polygons
    CREATE TEMPORARY TABLE temp_parsed_extension_polygons (
        polygon_id VARCHAR,
        ring_index BIGINT,
        point_index BIGINT,
        lon TEXT,
        lat TEXT,
        is_multipolygon BOOLEAN,
        geom GEOMETRY(POINT, 4326),
        final_node_id VARCHAR,
        is_new BOOLEAN
    ) ON COMMIT DROP;
    INSERT INTO temp_parsed_extension_polygons
    SELECT 
        fc.*,
        (-1 * ABS(HASHTEXT(fc.lat || ':' || fc.lon)))::VARCHAR AS final_node_id,
        pn.node_id IS NULL AS is_new
    FROM temp_flattened_polygon_coords fc
    LEFT JOIN temp_parsed_nodes pn 
        ON ST_DWithin(pn.geom, ST_SetSRID(ST_MakePoint(fc.lon::DOUBLE PRECISION, fc.lat::DOUBLE PRECISION), 4326), 1e-9);
    CREATE INDEX idx_temp_parsed_extension_polygons_polygon_id ON temp_parsed_extension_polygons(polygon_id);
    CREATE INDEX idx_temp_parsed_extension_polygons_final_node_id ON temp_parsed_extension_polygons(final_node_id);
    RAISE NOTICE 'processing temp_parsed_extension_polygons() {%}', clock_timestamp() - operation_start_time;

    operation_start_time := clock_timestamp();
    -- Create temporary table for single_ring_zones
    CREATE TEMPORARY TABLE temp_single_ring_zones (
        zone_id VARCHAR,
        ring_index INTEGER,
        point_index BIGINT,
        lon TEXT,
        lat TEXT,
        is_multipolygon BOOLEAN,
        geom GEOMETRY(POINT, 4326)
    ) ON COMMIT DROP;
    INSERT INTO temp_single_ring_zones
    SELECT 
        z.zone_id,
        1 AS ring_index,
        point_idx AS point_index,
        coord->>0 AS lon,
        coord->>1 AS lat,
        FALSE AS is_multipolygon,
        ST_SetSRID(ST_MakePoint((coord->>0)::DOUBLE PRECISION, (coord->>1)::DOUBLE PRECISION), 4326) AS geom
    FROM content.zone z
    JOIN temp_datasettoexport d ON z.tdei_dataset_id = d.tdei_dataset_id
    CROSS JOIN LATERAL jsonb_array_elements(z.feature::jsonb #> '{geometry,coordinates,0}') WITH ORDINALITY AS coord(coord, point_idx)
    WHERE jsonb_array_length(z.feature::jsonb #> '{geometry,coordinates}') = 1;
    CREATE INDEX idx_temp_single_ring_zones_zone_id ON temp_single_ring_zones(zone_id);
    CREATE INDEX idx_temp_single_ring_zones_geom ON temp_single_ring_zones USING GIST (geom);
    RAISE NOTICE 'processing temp_single_ring_zones() {%}', clock_timestamp() - operation_start_time;

    operation_start_time := clock_timestamp();
	CREATE TEMPORARY TABLE temp_parsed_zones (
        zone_id VARCHAR,
        node_ids TEXT[],
        feature_json JSONB,
        is_multipolygon BOOLEAN
    ) ON COMMIT DROP;
    INSERT INTO temp_parsed_zones
    SELECT
        z.zone_id,
        z.node_ids,
        z.feature::JSONB AS feature_json,
        CASE
            WHEN JSONB_ARRAY_LENGTH(z.feature::JSONB #> '{geometry,coordinates}') > 1 THEN TRUE
            ELSE FALSE
        END AS is_multipolygon
    FROM content.zone z
    JOIN temp_datasettoexport d ON z.tdei_dataset_id = d.tdei_dataset_id;
    CREATE INDEX idx_temp_parsed_zones_zone_id ON temp_parsed_zones(zone_id);
	RAISE NOTICE 'processing temp_parsed_zones() {%}', clock_timestamp() - operation_start_time;
	
    operation_start_time := clock_timestamp();
    -- Create temporary table for multi_ring_zones
    CREATE TEMPORARY TABLE temp_multi_ring_zones (
        zone_id VARCHAR,
        ring_index BIGINT,
        point_index BIGINT,
        lon TEXT,
        lat TEXT,
        is_multipolygon BOOLEAN,
        geom GEOMETRY(POINT, 4326)
    ) ON COMMIT DROP;
    INSERT INTO temp_multi_ring_zones
    SELECT 
        z.zone_id,
        ring_idx,
        point_idx AS point_index,
        coord->>0 AS lon,
        coord->>1 AS lat,
        TRUE AS is_multipolygon,
        ST_SetSRID(ST_MakePoint((coord->>0)::DOUBLE PRECISION, (coord->>1)::DOUBLE PRECISION), 4326) AS geom
    FROM content.zone z
    JOIN temp_datasettoexport d ON z.tdei_dataset_id = d.tdei_dataset_id
    CROSS JOIN LATERAL jsonb_array_elements(z.feature::jsonb #> '{geometry,coordinates}') WITH ORDINALITY AS ring(ring_coords, ring_idx)
    CROSS JOIN LATERAL jsonb_array_elements(ring_coords) WITH ORDINALITY AS coord(coord, point_idx)
    WHERE jsonb_array_length(z.feature::jsonb #> '{geometry,coordinates}') > 1;
    CREATE INDEX idx_temp_multi_ring_zones_zone_id ON temp_multi_ring_zones(zone_id);
    CREATE INDEX idx_temp_multi_ring_zones_geom ON temp_multi_ring_zones USING GIST (geom);
    RAISE NOTICE 'processing temp_multi_ring_zones() {%}', clock_timestamp() - operation_start_time;

    operation_start_time := clock_timestamp();
    -- Create temporary table for flattened_zone_coords
    CREATE TEMPORARY TABLE temp_flattened_zone_coords (
        zone_id VARCHAR,
        ring_index BIGINT,
        point_index BIGINT,
        lon TEXT,
        lat TEXT,
        is_multipolygon BOOLEAN,
        geom GEOMETRY(POINT, 4326)
    ) ON COMMIT DROP;
    INSERT INTO temp_flattened_zone_coords
    SELECT * FROM temp_single_ring_zones
    UNION ALL
    SELECT * FROM temp_multi_ring_zones;
    CREATE INDEX idx_temp_flattened_zone_coords_zone_id ON temp_flattened_zone_coords(zone_id);
    CREATE INDEX idx_temp_flattened_zone_coords_geom ON temp_flattened_zone_coords USING GIST (geom);
    RAISE NOTICE 'processing temp_flattened_zone_coords() {%}', clock_timestamp() - operation_start_time;

    operation_start_time := clock_timestamp();
    -- Create temporary table for parsed_zone_polygons
    CREATE TEMPORARY TABLE temp_parsed_zone_polygons (
        zone_id VARCHAR,
        ring_index BIGINT,
        point_index BIGINT,
        lon TEXT,
        lat TEXT,
        is_multipolygon BOOLEAN,
        geom GEOMETRY(POINT, 4326),
        final_node_id VARCHAR,
        is_new BOOLEAN
    ) ON COMMIT DROP;
    INSERT INTO temp_parsed_zone_polygons
    SELECT 
        fc.*,
        (-1 * ABS(HASHTEXT(fc.lat || ':' || fc.lon)))::VARCHAR AS final_node_id,
        pn.node_id IS NULL AS is_new
    FROM temp_flattened_zone_coords fc
    LEFT JOIN temp_parsed_nodes pn 
        ON ST_DWithin(pn.geom, ST_SetSRID(ST_MakePoint(fc.lon::DOUBLE PRECISION, fc.lat::DOUBLE PRECISION), 4326), 1e-9);
    CREATE INDEX idx_temp_parsed_zone_polygons_zone_id ON temp_parsed_zone_polygons(zone_id);
    CREATE INDEX idx_temp_parsed_zone_polygons_final_node_id ON temp_parsed_zone_polygons(final_node_id);
    RAISE NOTICE 'processing temp_parsed_zone_polygons() {%}', clock_timestamp() - operation_start_time;

    operation_start_time := clock_timestamp();
    -- Create temporary table for all_nodes
    CREATE TEMPORARY TABLE temp_all_nodes (
        node_id VARCHAR,
        lat NUMERIC,
        lon NUMERIC,
        feature_json JSONB
    ) ON COMMIT DROP;
    INSERT INTO temp_all_nodes
    SELECT node_id, ROUND(lat::NUMERIC, 7), ROUND(lon::NUMERIC, 7), feature_json
    FROM temp_parsed_nodes
    UNION ALL
    SELECT final_node_id AS node_id, ROUND(lat::NUMERIC, 7), ROUND(lon::NUMERIC, 7), feature_json
    FROM temp_parsed_extension_points
    UNION ALL
    SELECT final_node_id AS node_id, ROUND(lat::NUMERIC, 7), ROUND(lon::NUMERIC, 7), NULL::JSONB AS feature_json
    FROM temp_parsed_extension_polygons
    UNION ALL
    SELECT final_node_id AS node_id, ROUND(lat::NUMERIC, 7), ROUND(lon::NUMERIC, 7), NULL::JSONB AS feature_json
    FROM temp_parsed_zone_polygons
    UNION ALL
    SELECT final_node_id AS node_id, ROUND(lat::NUMERIC, 7), ROUND(lon::NUMERIC, 7), NULL::JSONB AS feature_json
    FROM temp_parsed_extension_lines
    UNION ALL
    SELECT final_node_id AS node_id, ROUND(lat::NUMERIC, 7), ROUND(lon::NUMERIC, 7), NULL::JSONB AS feature_json
    FROM temp_parsed_edge_points;
    CREATE INDEX idx_temp_all_nodes_lat_lon ON temp_all_nodes(lat, lon);
    CREATE INDEX idx_temp_all_nodes_node_id ON temp_all_nodes(node_id);
    RAISE NOTICE 'processing temp_all_nodes() {%}', clock_timestamp() - operation_start_time;

    operation_start_time := clock_timestamp();
    -- Create temporary table for deduplicated_nodes
    CREATE TEMPORARY TABLE temp_deduplicated_nodes (
        node_id VARCHAR,
        lat NUMERIC,
        lon NUMERIC,
        feature_json JSONB,
        CONSTRAINT unique_lat_lon UNIQUE (lat, lon)
    ) ON COMMIT DROP;
    INSERT INTO temp_deduplicated_nodes
    SELECT 
        MIN(node_id) AS node_id,
        lat,
        lon,
        CASE 
            WHEN EXISTS (
                SELECT 1 
                FROM temp_all_nodes sub 
                WHERE sub.lat = main.lat 
                AND sub.lon = main.lon 
                AND sub.feature_json IS NOT NULL 
                AND jsonb_typeof(sub.feature_json->'properties') = 'object'
            ) 
            THEN jsonb_build_object(
                'type', 'Feature',
                'geometry', jsonb_build_object(
                    'type', 'Point',
                    'coordinates', jsonb_build_array(lon, lat)
                ),
                'properties', 
                COALESCE(
                    (SELECT jsonb_object_agg(key, value)
                     FROM temp_all_nodes sub
                     CROSS JOIN LATERAL jsonb_each(COALESCE(sub.feature_json->'properties', '{}'::JSONB)) AS props(key, value)
                     WHERE sub.lat = main.lat 
                     AND sub.lon = main.lon 
                     AND sub.feature_json IS NOT NULL 
                     AND jsonb_typeof(sub.feature_json->'properties') = 'object'
                     AND key NOT IN ('_id', '_u_id', '_v_id', '_w_id')
                     AND value IS NOT NULL
                    ),
                    '{}'::JSONB
                )
            )
            ELSE NULL::JSONB
        END AS feature_json
    FROM temp_all_nodes main
    GROUP BY lat, lon;
    CREATE INDEX idx_temp_deduplicated_nodes_node_id ON temp_deduplicated_nodes(node_id);
    CREATE INDEX idx_temp_deduplicated_nodes_lat_lon ON temp_deduplicated_nodes(lat, lon);
    RAISE NOTICE 'processing temp_deduplicated_nodes() {%}', clock_timestamp() - operation_start_time;

    operation_start_time := clock_timestamp();
    -- Create temporary table for node_blocks
    CREATE TEMPORARY TABLE temp_node_blocks (
        line TEXT
    ) ON COMMIT DROP;
    INSERT INTO temp_node_blocks
    SELECT
        CASE 
            WHEN (feature_json IS NOT NULL AND jsonb_typeof(feature_json->'properties') = 'object' AND (
                SELECT COUNT(*) 
                FROM jsonb_each_text(feature_json->'properties')
                WHERE key NOT IN ('_id', '_u_id', '_v_id', '_w_id')
            ) > 0)
            THEN '<node visible="true" id="' || node_id || '" lat="' || lat || '" lon="' || lon || '">' || (
                SELECT string_agg('<tag k="' || key || '" v="' || value || '"/>', E'')
                FROM jsonb_each_text(feature_json->'properties')
                WHERE key NOT IN ('_id', '_u_id', '_v_id', '_w_id')
            ) || '</node>'
            ELSE '<node visible="true" id="' || node_id || '" lat="' || lat || '" lon="' || lon || '"/>'
        END AS line
    FROM temp_deduplicated_nodes;
    RAISE NOTICE 'processing temp_node_blocks() {%}', clock_timestamp() - operation_start_time;

    operation_start_time := clock_timestamp();
    -- Create temporary table for edge_way_blocks
    CREATE TEMPORARY TABLE temp_edge_way_blocks (
        edge_id VARCHAR,
        line TEXT
    ) ON COMMIT DROP;
    INSERT INTO temp_edge_way_blocks
    SELECT
        pep.edge_id,
        '<way visible="true" id="' || REPLACE(pep.edge_id, '_', '') || '">' ||
        STRING_AGG('<nd ref="' || final_node_id || '"/>', E'' ORDER BY point_index) ||
        COALESCE(
            (
                SELECT STRING_AGG('<tag k="' || CASE WHEN key = 'climb' THEN 'incline' ELSE key END || '" v="' || CASE 
                        WHEN key = 'width' THEN TO_CHAR(value::float8, 'FM999999990.0')::text
                        WHEN key = 'step_count' THEN CAST(value AS INTEGER)::TEXT
                        ELSE value
                    END || '"/>', E'')
                FROM jsonb_each_text((
                    SELECT re.feature_json
                    FROM temp_raw_edges re
                    WHERE re.edge_id = pep.edge_id
                    LIMIT 1
                ) -> 'properties')
                WHERE key NOT IN ('_id', '_v_id', '_u_id', 'length', 'incline')
                  AND NOT (
                    key = 'foot' AND value = 'yes' AND (
                        (
                            (SELECT re.feature_json->'properties'->>'highway'
                             FROM temp_raw_edges re
                             WHERE re.edge_id = pep.edge_id
                             LIMIT 1)
                        ) IN ('footway', 'pedestrian', 'steps', 'living_street')
                    )
                  )
            ),
            ''
        ) ||
		CASE
            WHEN (
				 SELECT 
	            (z.feature_json->'properties'->>'highway' = 'pedestrian')
	            AND (z.feature_json->'properties'->>'surface' = 'paving_stones')
		        FROM temp_raw_edges z
		        WHERE z.edge_id = pep.edge_id
		        LIMIT 1
            ) 
            THEN '<tag k="area" v="yes"/>'
            ELSE ''
        END ||
        '</way>' AS line
    FROM temp_parsed_edge_points pep
    GROUP BY pep.edge_id;
    CREATE INDEX idx_temp_edge_way_blocks_edge_id ON temp_edge_way_blocks(edge_id);
    RAISE NOTICE 'processing temp_edge_way_blocks() {%}', clock_timestamp() - operation_start_time;

    operation_start_time := clock_timestamp();
    -- Create temporary table for polygon_way_blocks
    CREATE TEMPORARY TABLE temp_polygon_way_blocks (
        polygon_id VARCHAR,
        ring_index BIGINT,
        line TEXT
    ) ON COMMIT DROP;
    INSERT INTO temp_polygon_way_blocks
    SELECT
        pep.polygon_id,
        ring_index,
        '<way visible="true" id="' || REPLACE(pep.polygon_id, '-', '') || ring_index || '">' ||
        STRING_AGG('<nd ref="' || final_node_id || '"/>', E'' ORDER BY point_index) ||
        COALESCE(
            (
                SELECT STRING_AGG('<tag k="' || CASE WHEN key = 'climb' THEN 'incline' ELSE key END || '" v="' || CASE 
                         WHEN key = 'width' THEN TO_CHAR(value::float8, 'FM999999990.0')::text
                        WHEN key = 'step_count' THEN CAST(value AS INTEGER)::TEXT
                        ELSE value
                    END || '"/>', E'')
                FROM jsonb_each_text((
                    SELECT ep.feature_json
                    FROM temp_extension_polygons ep
                    WHERE ep.polygon_id = pep.polygon_id AND is_multipolygon IS FALSE LIMIT 1
                ) -> 'properties')
                WHERE key NOT IN ('_id', 'length', 'incline')
				AND NOT (
                    key = 'foot' AND value = 'yes' AND (
                        (
                            (SELECT re.feature_json->'properties'->>'highway'
                             FROM temp_extension_polygons re
                             WHERE re.polygon_id = pep.polygon_id
                             LIMIT 1)
                        ) IN ('footway', 'pedestrian', 'steps', 'living_street')
                    )
                  )
            ),
            ''
        ) ||
		-- CASE
  --           WHEN (
  --               SELECT z.feature_json->'properties'->>'highway'
  --               FROM temp_extension_polygons z
  --               WHERE z.polygon_id = pep.polygon_id
  --               LIMIT 1
  --           ) = 'pedestrian'
  --           THEN '<tag k="area" v="yes"/>'
  --           ELSE ''
  --       END ||
        '</way>' AS line
    FROM temp_parsed_extension_polygons pep
    GROUP BY pep.polygon_id, is_multipolygon, ring_index;
    CREATE INDEX idx_temp_polygon_way_blocks_polygon_id ON temp_polygon_way_blocks(polygon_id);
    RAISE NOTICE 'processing temp_polygon_way_blocks() {%}', clock_timestamp() - operation_start_time;

    operation_start_time := clock_timestamp();
    -- Create temporary table for polygon_relation_blocks
    CREATE TEMPORARY TABLE temp_polygon_relation_blocks (
        polygon_id VARCHAR,
        line TEXT
    ) ON COMMIT DROP;
    INSERT INTO temp_polygon_relation_blocks
    SELECT
        pep.polygon_id,
        '<relation visible="true" id="' || REPLACE(pep.polygon_id, '-', '') || '">' || 
        STRING_AGG(
            DISTINCT 
            '<member type="way" ref="' || REPLACE(pep.polygon_id, '-', '') || ring_index || 
            '" role="' || CASE WHEN ring_index = 1 THEN 'outer' ELSE 'inner' END || '"/>',
            ''
        ) ||
        '<tag k="type" v="multipolygon"/>' || 
        COALESCE(
            (
                SELECT string_agg('<tag k="' || key || '" v="' || value || '"/>', '')
                FROM jsonb_each_text(
                    (
                        SELECT ep.feature_json
                        FROM temp_extension_polygons ep
                        WHERE ep.polygon_id = pep.polygon_id
                        LIMIT 1
                    )::jsonb -> 'properties'
                )
                WHERE key NOT IN ('_id', '_w_id')
            ),
            ''
        ) ||
        '</relation>' AS line
    FROM temp_parsed_extension_polygons pep
    WHERE is_multipolygon
    GROUP BY pep.polygon_id;
    CREATE INDEX idx_temp_polygon_relation_blocks_polygon_id ON temp_polygon_relation_blocks(polygon_id);
    RAISE NOTICE 'processing temp_polygon_relation_blocks() {%}', clock_timestamp() - operation_start_time;

    operation_start_time := clock_timestamp();
    -- Create temporary table for zone_way_blocks
    CREATE TEMPORARY TABLE temp_zone_way_blocks (
        zone_id VARCHAR,
        ring_index BIGINT,
        line TEXT
    ) ON COMMIT DROP;
    INSERT INTO temp_zone_way_blocks
    SELECT
        pzp.zone_id,
        ring_index,
        '<way visible="true" id="' || REPLACE(pzp.zone_id, '-', '') || ring_index || '">' ||
        STRING_AGG('<nd ref="' || final_node_id || '"/>', E'' ORDER BY point_index) ||
        COALESCE(
            (
                SELECT STRING_AGG('<tag k="' || CASE WHEN key = 'climb' THEN 'incline' ELSE key END || '" v="' || CASE 
                        WHEN key = 'width' THEN TO_CHAR(value::float8, 'FM999999990.0')::text
                        WHEN key = 'step_count' THEN CAST(value AS INTEGER)::TEXT
                        ELSE value
                    END || '"/>', E'')
                FROM jsonb_each_text((
                    SELECT z.feature_json::jsonb
                    FROM temp_parsed_zones z
                    WHERE z.zone_id = pzp.zone_id AND is_multipolygon IS FALSE LIMIT 1
                ) -> 'properties')
                WHERE key NOT IN ('_id', '_w_id', 'length', 'incline')
				AND NOT (
                    key = 'foot' AND value = 'yes' AND (
                        (
                            (SELECT re.feature_json->'properties'->>'highway'
                             FROM temp_parsed_zones re
                             WHERE re.zone_id = pzp.zone_id
                             LIMIT 1)
                        ) IN ('footway', 'pedestrian', 'steps', 'living_street')
                    )
                  )
            ),
            ''
        ) ||
		CASE
            WHEN (
			 SELECT 
	            (z.feature_json->'properties'->>'highway' = 'pedestrian')
	            AND (z.feature_json->'properties' ? '_w_id')
		        FROM temp_parsed_zones z
		        WHERE z.zone_id = pzp.zone_id and is_multipolygon is not true
		        LIMIT 1
            )
            THEN '<tag k="area" v="yes"/>'
            ELSE ''
        END ||
        '</way>' AS line
    FROM temp_parsed_zone_polygons pzp
    GROUP BY pzp.zone_id, is_multipolygon, ring_index;
    CREATE INDEX idx_temp_zone_way_blocks_zone_id ON temp_zone_way_blocks(zone_id);
    RAISE NOTICE 'processing temp_zone_way_blocks() {%}', clock_timestamp() - operation_start_time;

    operation_start_time := clock_timestamp();
    -- Create temporary table for zone_relation_blocks
    CREATE TEMPORARY TABLE temp_zone_relation_blocks (
        zone_id VARCHAR,
        line TEXT
    ) ON COMMIT DROP;
    INSERT INTO temp_zone_relation_blocks
    SELECT
        pzp.zone_id,
        '<relation visible="true" id="' || REPLACE(pzp.zone_id, '-', '') || '">' || 
        STRING_AGG(
            DISTINCT 
            '<member type="way" ref="' || REPLACE(pzp.zone_id, '-', '') || ring_index || 
            '" role="' || CASE WHEN ring_index = 1 THEN 'outer' ELSE 'inner' END || '"/>',
            ''
        ) ||
        '<tag k="type" v="multipolygon"/>' || 
        COALESCE(
            (
                SELECT string_agg('<tag k="' || key || '" v="' || REPLACE(value, '"', '''') || '"/>', '')
                FROM jsonb_each_text(
                    (
                        SELECT z.feature_json
                        FROM temp_parsed_zones z
                        WHERE z.zone_id = pzp.zone_id
                        LIMIT 1
                    )::jsonb -> 'properties'
                )
                WHERE key NOT IN ('_id', '_w_id')
            ),
            ''
        ) ||
        CASE
            WHEN (
               SELECT 
	            (z.feature_json->'properties'->>'highway' = 'pedestrian')
	            AND (z.feature_json->'properties' ? '_w_id')
		        FROM temp_parsed_zones z
		        WHERE z.zone_id = pzp.zone_id
		        LIMIT 1
            ) 
            THEN '<tag k="area" v="yes"/>'
            ELSE ''
        END ||
        '</relation>' AS line
    FROM temp_parsed_zone_polygons pzp
    WHERE is_multipolygon
    GROUP BY pzp.zone_id;
    CREATE INDEX idx_temp_zone_relation_blocks_zone_id ON temp_zone_relation_blocks(zone_id);
    RAISE NOTICE 'processing temp_zone_relation_blocks() {%}', clock_timestamp() - operation_start_time;

    operation_start_time := clock_timestamp();
    -- Create temporary table for extension_lines_way_blocks
    CREATE TEMPORARY TABLE temp_extension_lines_way_blocks (
        line_id VARCHAR,
        line TEXT
    ) ON COMMIT DROP;
    INSERT INTO temp_extension_lines_way_blocks
    SELECT
        pel.line_id,
        '<way visible="true" id="' || REPLACE(pel.line_id, '-', '') || '">' ||
        STRING_AGG('<nd ref="' || final_node_id || '"/>', E'' ORDER BY point_index) ||
        COALESCE(
            (
                SELECT STRING_AGG('<tag k="' || CASE WHEN key = 'climb' THEN 'incline' ELSE key END || '" v="' || CASE 
                         WHEN key = 'width' THEN TO_CHAR(value::float8, 'FM999999990.0')::text
                        WHEN key = 'step_count' THEN CAST(value AS INTEGER)::TEXT
                        ELSE value
                    END || '"/>', E'')
                FROM jsonb_each_text((
                    SELECT rel.feature_json
                    FROM temp_raw_extension_lines rel
                    WHERE rel.line_id = pel.line_id LIMIT 1
                ) -> 'properties')
                WHERE key NOT IN ('_id', 'length', 'incline')
				AND NOT (
                    key = 'foot' AND value = 'yes' AND (
                        (
                            (SELECT re.feature_json->'properties'->>'highway'
                             FROM temp_raw_extension_lines re
                             WHERE re.line_id = pel.line_id
                             LIMIT 1)
                        ) IN ('footway', 'pedestrian', 'steps', 'living_street')
                    )
                  )
            ),
            ''
        ) || 
        '</way>' AS line
    FROM temp_parsed_extension_lines pel
    GROUP BY pel.line_id;
    CREATE INDEX idx_temp_extension_lines_way_blocks_line_id ON temp_extension_lines_way_blocks(line_id);
    RAISE NOTICE 'processing temp_extension_lines_way_blocks() {%}', clock_timestamp() - operation_start_time;

    operation_start_time := clock_timestamp();
    -- Create temporary table for exportdata
    CREATE TEMPORARY TABLE temp_exportdata (
        line TEXT
    ) ON COMMIT DROP;
    INSERT INTO temp_exportdata
    SELECT '<?xml version="1.0" encoding="UTF-8"?><osm version="0.6" generator="TDEI exporter" upload="false">' AS line
    UNION ALL
    SELECT line FROM temp_node_blocks
    UNION ALL
    SELECT line FROM temp_edge_way_blocks
    UNION ALL
    SELECT line FROM temp_polygon_way_blocks
    UNION ALL
    SELECT line FROM temp_zone_way_blocks
    UNION ALL
    SELECT line FROM temp_extension_lines_way_blocks
    UNION ALL
    SELECT line FROM temp_polygon_relation_blocks
    UNION ALL
    SELECT line FROM temp_zone_relation_blocks
    UNION ALL
    SELECT '</osm>' AS line;

    -- Aggregate the final output
    SELECT string_agg(line, E'\n') INTO osm_output
    FROM temp_exportdata;
    RAISE NOTICE 'processing temp_exportdata() {%}', clock_timestamp() - operation_start_time;

    RETURN osm_output;
END;
$BODY$;

ALTER FUNCTION content.export_osm_xml(text)
    OWNER TO tdeiadmin;
