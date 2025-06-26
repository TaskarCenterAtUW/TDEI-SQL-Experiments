SET SEARCH_PATH=content, public;

CREATE OR REPLACE FUNCTION geom_intersection_accum(geom1 geometry, geom2 geometry)
RETURNS geometry AS $$
BEGIN
  IF geom1 IS NULL THEN
    RETURN geom2;
  ELSIF geom2 IS NULL THEN
    RETURN geom1;
  ELSE
    RETURN ST_Intersection(geom1, geom2);
  END IF;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE AGGREGATE ST_Intersection_Agg(geometry) (
  SFUNC = geom_intersection_accum,
  STYPE = geometry
);

WITH testzones as (
SELECT *
FROM dataset d, zone z 
where d.tdei_dataset_id = z.tdei_dataset_id 
and (d.name = 'Cloned_San Jose_Island Transit - Orch_v2'
or d.name = 'Clone_Cloned_San Jose_Island Transit - Orch_v2')
)
SELECT z1.zone_loc, ST_Union(z2.zone_loc)
FROM testzones z1, testzones z2
WHERE ST_DWithin(z1.zone_loc, z2.zone_loc, 0.0004)
GROUP BY z1.zone_loc
HAVING ST_Area(ST_Intersection_Agg(z2.zone_loc)) / ST_Area(ST_Union(z2.zone_loc)) > 0.8


