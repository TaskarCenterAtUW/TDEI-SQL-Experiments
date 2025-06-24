SET SEARCH_PATH=content, public;

SELECT PostGIS_Full_Version();

SELECT ST_StraightSkeleton(ST_GeomFromText('POLYGON((0 0, 10 0, 5 10, 0 0))'));


DROP TABLE IF EXISTS test_polygons;

CREATE TABLE test_polygons (
  id SERIAL PRIMARY KEY,
  name TEXT,
  geom GEOMETRY(POLYGON, 4326)
);

INSERT INTO test_polygons (name, geom) VALUES

-- Upper left
('L-shape', ST_GeomFromText('POLYGON((0 20, 0 30, 4 30, 4 26, 8 26, 8 20, 0 20))', 4326)),

-- Lower right
('Concave', ST_GeomFromText('POLYGON((20 0, 20 5, 25 5, 25 2, 22 2, 22 0, 20 0))', 4326));

INSERT INTO test_polygons (name, geom) VALUES

-- Long narrow sidewalk (horizontal)
('Sidewalk - horizontal', ST_GeomFromText('POLYGON((40 0, 40 2, 60 2, 60 0, 40 0))', 4326)),

-- Long narrow sidewalk (vertical)
('Sidewalk - vertical', ST_GeomFromText('POLYGON((70 0, 70 20, 72 20, 72 0, 70 0))', 4326)),


-- Angled sidewalk (diagonal)
('Angled path', ST_GeomFromText('POLYGON((100 0, 101 0.5, 111 10.5, 110 10, 100 0))', 4326));


INSERT INTO test_polygons (name, geom) VALUES
-- Winding path like an S-curve
('Meandering path S-shape', ST_GeomFromText(
  'POLYGON((
    120 0, 121 0.5, 122 1.5, 123 3, 124 4.5, 125 6,
    126 7, 127 7.5, 128 8, 129 8.5, 130 9,
    131 8.5, 130 8, 129 7.5, 128 7, 127 6,
    126 4.5, 125 3, 124 1.5, 123 0.5, 122 0,
    120 0))', 4326)),

-- Zig-zag path
('Zig-zag sidewalk', ST_GeomFromText(
  'POLYGON((
    140 0, 141 1, 142 0, 143 1, 144 0,
    145 1, 146 0, 147 1, 148 0,
    148 2, 147 3, 146 2, 145 3, 144 2,
    143 3, 142 2, 141 3, 140 2,
    140 0))', 4326)),

-- Forked path (Y-junction)
('Y-junction path', ST_GeomFromText(
  'POLYGON((
    160 0, 162 0, 164 2, 165 4, 166 6,
    165 6.5, 164 6, 162.5 4.5,
    161.5 6, 160.5 6.5, 160 6,
    161 4, 160 2, 160 0))', 4326)),

-- Offset curved-style walk (polygonal approximation of a curve)
('Curved walk (poly-curve)', ST_GeomFromText(
  'POLYGON((
    180 0, 180.5 0.2, 181 0.5, 181.5 1, 182 1.7,
    182.5 2.5, 183 3.3, 183.5 4.1, 184 5,
    183.5 5.1, 183 5.2, 182.5 5.3, 182 5.4,
    181.5 5.5, 181 5.6, 180.5 5.7, 180 5.8,
    179.5 5.7, 179 5.6, 178.5 5.5, 178 5.4,
    177.5 5.3, 177 5.2, 176.5 5.1, 176 5,
    176.5 4.1, 177 3.3, 177.5 2.5, 178 1.7,
    178.5 1, 179 0.5, 179.5 0.2, 180 0))', 4326));

 

  

INSERT INTO test_polygons (name, geom) VALUES
('Complex branching sidewalk – wide fork', ST_GeomFromText(
  'POLYGON((
    0 0,
    2 0,
    2 20,
    5 25,
    4 26,
    2 22,
    2 30,
    0 30,
    0 22,
    -2 26,
    -3 25,
    0 20,
    0 0
  ))', 4326));



DROP TABLE IF EXISTS test_polygons;

CREATE TABLE test_polygons (
  id SERIAL PRIMARY KEY,
  name TEXT,
  geom GEOMETRY(POLYGON, 4326)
);

INSERT INTO test_polygons (name, geom) VALUES
('Segment 1', ST_GeomFromText(
  'POLYGON((0 0, 2 0, 3 2, 2 4, 4 6,
            3 8, 2 10, 2 12, 0 12, 0 10,
            -1 8, 0 6, -2 4, -1 2, 0 0))', 4326));

INSERT INTO test_polygons (name, geom) VALUES
('Segment 2', ST_GeomFromText(
  'POLYGON((0 12, 2 12, 3 14, 2 16, 4 18,
            3 20, 2 22, 2 24, 0 24, 0 22,
            -1 20, 0 18, -2 16, -1 14, 0 12))', 4326));

INSERT INTO test_polygons (name, geom) VALUES
('Segment 3', ST_GeomFromText(
  'POLYGON((0 24, 2 24, 3 26, 2 28, 4 30,
            3 32, 2 34, 2 36, 0 36, 0 34,
            -1 32, 0 30, -2 28, -1 26, 0 24))', 4326));



SELECT ST_IsValid(geom), ST_IsValidReason(geom) FROM test_polygons WHERE name = 'Long branching sidewalk';

SELECT
  id,
  name,
  geom
FROM test_polygons
where name like '%egment%'
UNION
SELECT
  id,
  name,
  ST_ApproximateMedialAxis(geom) AS skeleton_geom
FROM test_polygons
where name like '%egment%'




