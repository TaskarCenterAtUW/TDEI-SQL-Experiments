SET SEARCH_PATH=content, public;


-- Determine dataset(s) to export
DROP TABLE IF EXISTS exportdata;
CREATE TABLE exportdata AS 
WITH datasettoexport as (
	SELECT d.tdei_dataset_id, d.name, d.version
	FROM dataset d 
	WHERE d.name LIKE 'Island Transit - Orch_v2%'  and version like '%1.5%'
)

-- fix ids to match ogr2osm API
parsed_edges AS (
  SELECT 
    replace(e.edge_id, '_', '') AS cleaned_edge_id,
    e.orig_node_id,
    e.dest_node_id,
    ((e.feature::json) #>> '{}')::json AS feature_json
  FROM edge e
  JOIN datasettoexport d ON e.tdei_dataset_id = d.tdei_dataset_id
)

-- output XML header
SELECT '<?xml version="1.0" encoding="UTF-8"?>
<osm version="0.6" generator="ogr2osm 1.2.0" upload="false">' as line

UNION ALL

-- output nodes, along with their list of tags (skipping _id)
SELECT 
'<node visible="true" id="' || n.node_id 
			|| '" lat="' || trim_scale(round(ST_Y(node_loc)::numeric, 9))
			|| '" lon="' || trim_scale(round(ST_X(node_loc)::numeric, 9)) || '"/>' ||
  COALESCE(tag_xml, '') ||
  '</node>' AS way_xml
FROM node n join datasettoexport d on n.tdei_dataset_id = d.tdei_dataset_id  
LEFT JOIN LATERAL (
  SELECT string_agg(
           '<tag k="' || key || '" v="' ||
           replace(replace(replace(value, '&', '&amp;'), '"', '&quot;'), '<', '&lt;') || '"/>',
           ''
         ) AS tag_xml
  FROM jsonb_each_text((n.feature->'properties')::jsonb) AS tags(key, value)
  WHERE key != '_id'
) t ON true

UNION ALL

/*
-- old way: hardcoding tags instead of pulling all available.  
SELECT 
  '<way visible="true" id="' || cleaned_edge_id || '">' ||
  '<nd ref="' || orig_node_id || '"/>' ||
  '<nd ref="' || dest_node_id || '"/>' ||
  COALESCE('<tag k="highway" v="' || (feature_json->'properties'->>'highway') || '"/>', '') ||
  COALESCE('<tag k="footway" v="' || (feature_json->'properties'->>'footway') || '"/>', '') ||
  COALESCE('<tag k="ext:sw_id" v="' || (feature_json->'properties'->>'ext:sw_id') || '"/>', '') ||
  COALESCE('<tag k="ext:confidence" v="' || (feature_json->'properties'->>'ext:confidence') || '"/>', '') ||
  COALESCE('<tag k="ext:from_intersection" v="' || (feature_json->'properties'->>'ext:from_intersection') || '"/>', '') ||
  COALESCE('<tag k="ext:to_intersection" v="' || (feature_json->'properties'->>'ext:to_intersection') || '"/>', '') ||
  COALESCE('<tag k="ext:side" v="' || (feature_json->'properties'->>'ext:side') || '"/>', '') ||
  COALESCE('<tag k="ext:at_intersection" v="' || (feature_json->'properties'->>'ext:at_intersection') || '"/>', '') ||
  COALESCE('<tag k="ext:node_description" v="' || (feature_json->'properties'->>'ext:node_description') || '"/>', '') ||
  COALESCE('<tag k="ext:corner_id" v="' || (feature_json->'properties'->>'ext:corner_id') || '"/>', '') ||
  COALESCE('<tag k="ext:line_description" v="' || (feature_json->'properties'->>'ext:line_description') || '"/>', '') ||
  COALESCE('<tag k="ext:line_type" v="' || (feature_json->'properties'->>'ext:line_type') || '"/>', '') ||
  '</way>' AS way_xml
FROM parsed_edges
*/

-- emit ways from edges (not currently emitting internal nodes; unclear if ogr2osm does so
SELECT 
  '<way visible="true" id="' || cleaned_edge_id || '">' ||
  '<nd ref="' || orig_node_id || '"/>' ||
  '<nd ref="' || dest_node_id || '"/>' ||
  COALESCE(tag_xml, '') ||
  '</way>' AS way_xml
FROM parsed_edges pe
LEFT JOIN LATERAL (
  SELECT string_agg(
           '<tag k="' || key || '" v="' ||
           replace(replace(replace(value, '&', '&amp;'), '"', '&quot;'), '<', '&lt;') || '"/>',
           ''
         ) AS tag_xml
  FROM jsonb_each_text((pe.feature_json->'properties')::jsonb) AS tags(key, value)
  WHERE key != '_id'
) t ON true


UNION ALL

-- skipping polygons for now; TODO

-- closing tag
SELECT '</osm>';


-- aggregate the lines into on XML value
SELECT string_agg(line, E'\n') AS osm_output
FROM exportdata;
