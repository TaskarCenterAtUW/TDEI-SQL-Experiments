SET SEARCH_PATH=content, public;

-- =========================================
--- Preparing Test; can be removed --
-- =========================================

-- Choose the pair of datasets we are unioning
-- Currently using Mahesh's naming scheme
-- Columbia and Multnomah, with naming conventions 
-- like UC5_Multnomah and UC5_Columbia 
-- you can union as many datasets as you would like 
-- (performance may be an issue)
-- Other tests to try: UC1.1, UC2, UC3, UC4, UC5, UC6
DROP TABLE IF EXISTS testdataset;
CREATE TEMP TABLE testdataset as (
	SELECT d.name, d.tdei_dataset_id 
	FROM dataset d
--	where d.name like '%UC5%'
	where d.tdei_dataset_id = '082ee4b3-40a6-484c-a19f-8a5f2fdb869b' 
	OR d.tdei_dataset_id = '9e4a9ad5-de52-4c39-a375-0307cef4cb58'

-- Dev medium-sized test:
--Portland Sidewalks | 082ee4b3-40a6-484c-a19f-8a5f2fdb869b | 43664 nodes | 45149 edges
--Multnomah County Prophet Predictions | 9e4a9ad5-de52-4c39-a375-0307cef4cb58| 178014 nodes | 193373 edges
);

-- Find the nodes in the test datsets
DROP TABLE IF EXISTS testnodes;
CREATE TEMP TABLE testnodes as (
	select 
		d.name as source, 
		n.id as element_id, 
		-- assign 0 as the sub_id
		-- for nodes and edges, there is no sub_id (it's always 0)
		-- for internal line string nodes, there is a sub_id (see below)
		0 as element_sub_id, 
		n.node_loc as geom 
	from node n, testdataset d
	where n.tdei_dataset_id = d.tdei_dataset_id
);

-- Find the edges in the test datsets
DROP TABLE IF EXISTS testedges;
CREATE TEMP TABLE testedges as (
	select 	
		d.name as source, 
		e.id as element_id, 
		e.edge_loc as geom
	from edge e, testdataset d
	where e.tdei_dataset_id = d.tdei_dataset_id
);


-- Find the *internal* nodes for the edges in the test datasets
DROP TABLE IF EXISTS testedgepoints;
CREATE TEMP TABLE testedgepoints as (
  SELECT 
  		path.source, 
  		path.element_id,
		-- sub id indicates the order or the internal nodes.  
		-- Begins with 1 (not 0, which is important)
        dp.path[1] AS element_sub_id,
		dp.geom
  FROM testedges path, ST_DumpPoints(path.geom) dp
);


-- =================================================
-- Assumed inputs: AllPoints and Paths
-- =================================================

-- Construct Allpoints to include nodes AND internal nodes of edges
-- This view/temp/table should be constructed to include ALL points 
-- (including internal points from ALL datasets that we are unioning)
-- (typically just two). 

-- source is the name of the dataset 
-- 		(not necessarily used, unless we want to favor one source over another)
-- element_id is the id of the node or edge
-- element_sub_id is the id of an internal node that indicates order; used to reconstruct edges
-- 		element_sub_id is just 0 for all nodes.
-- geom is the geometry of the node / internal node, or edge
DROP TABLE IF EXISTS AllPoints;
CREATE TEMP TABLE AllPoints AS

 -- From nodes
SELECT 
	source, 
	element_id, 
	element_sub_id, 
	geom
FROM testnodes
UNION
-- From internal linestring nodes
SELECT 
	source, 
	element_id, 
	element_sub_id, 
	geom 
FROM testedgepoints;


-- Paths is just testedges for us
DROP TABLE IF EXISTS Path;
CREATE TEMP TABLE Path as (
   SELECT * FROM testedges
);


-- =========================================
--- Start of algorithm --
-- =========================================

-- Inputs: 
-- AllPoints(source, element_id, element_sub_id, geom::Point)
-- Path(source, element_id, geom::LineString)
-- Tolerance: A distance (in degrees in this implementation) 
--  		representing the maximum distance two nodes can be apart to 
-- 			still be considered the same cluster.  Friends-of-friends clustering.

-- source is the name of the dataset 
-- 		(not necessarily used, unless we want to favor one source over another)
-- element_id is the id of the node or edge
-- element_sub_id is the id of an internal node that indicates order; used to reconstruct edges
-- 		element_sub_id is just 0 for non-internal nodes.
-- geom is the geometry of the node / internal node or edge

-- Outputs:
-- UnionNodes(source, id, geom)
-- UnionEdges(source, id, geom)

-- Invariants: 
-- UnionNodes contains no pair of points x,y such that dist(x.geom,y.geom) < tolerance 
--       x,y \in UnionNodes => dist(x.geom,y.geom) >= tolerance
-- UnionNodes contains no node geometry that did not appear in AllPoints (id will differ) 
--       x \in UnionNodes => x.geom \in {y.geom | y \in AllPoints}
-- For any pair of edges e,f in UnionEdges, the exists no pair of internal nodes e.x, f.y such that dist(e.x,e.y) < tolerance
--       e,f \in UnionEdges => ( x \in e, y \in f => dist(x.geom,y.geom) < tolerance )
-- For any edge e in UnionEdges, there exists no internal node e.x that does not appear in AllPoints
--       e \in UnionEdges => ( x \in e => x \in AllPoints)
-- Let x,y be tolerance-reachable if there exists a path P=(x,p1,p2,...,pn,y) such that 
--         pi, pj \in P, j=i+1 => dist(pi.geom,pj.geom) < tolerance
-- 		Then
-- 			Every node x in AllPoints is associated with a node witness(x) such that x is tolerance-reachable to witness(x).
-- 			x \in AllPoints <=> witness(x) \in UnionNode
-- 			If x is tolerance-reachable to y in AllPoints through (x, p1, p2, ..., pn, y), there is an 
-- 		    	edge (witness(x), c1, c2, ..., cm, witness(y)) where cj = witness(k) for some node k in AllPoints.
-- 				That is, every path consists of witnesses, but there may be fewer internal nodes in the output than the input
--
-- 
-- Notes / TODOs:
-- ** id in UnionNodes will NOT be the original id from the nodes table,
-- though geom will be one of the original nodes. So, you can join on geom 
-- to recover the original id. We will need to do so to set _u and _v properly
-- in edges. (One way to resolve is to use the cantor pairing function to combine 
-- (element_id, element_sub_id) into one number, then extract the pair. I was doing 
-- this originally, but it added some extra code that was not critical.)

-- ** UnionNodes includes only the main nodes; we filter out internal nodes as
-- those are only used to reconstruct edges.

-- ** We select a witness from among the cluster -- the minimum id from the lowest source alphabetically.
-- Other options: favor one source in particular, compute the centroid of the cluster, pick a near-centroid choice, etc.


-- ====================================================================================
-- Step 1: Materialize all points with ids, so we can index the geometry column
-- ====================================================================================

DROP TABLE IF EXISTS MaterializedPoints;
CREATE TEMP TABLE MaterializedPoints AS
  SELECT source, element_id, element_sub_id, geom,
  		 -- construct new ids for each node (could use cantor pairing function here)
         row_number() OVER (ORDER BY element_id, element_sub_id) as id
  FROM AllPoints;

-- CREATE spatial INDEX on materialized nodes -- must use for performance!
DROP INDEX IF EXISTS idx_node_geom;
CREATE INDEX idx_node_geom ON MaterializedPoints USING GIST (geom);



-- ====================================================================================
-- Step 2: Join to get pairs of nearby nodes.  Materialize.  Set tolerance here.
-- ====================================================================================

DROP TABLE IF EXISTS Neighbors;
CREATE TEMP TABLE Neighbors AS
  SELECT a.id AS id1, b.id AS id2
  FROM MaterializedPoints a
  JOIN MaterializedPoints b ON ST_DWithin(a.geom, b.geom, 0.00004)  -- Tolerance: nodes within this distance should be clustered
  AND a.id < b.id;

DROP INDEX IF EXISTS idx_neighbors;
CREATE INDEX idx_neighbors ON Neighbors (id1, id2);


-- ====================================
-- Step 3: Recursive friend-of-friend closure: keep joining until 
-- the result does not change. Materialize.
-- ====================================

DROP TABLE IF EXISTS Clusters;
CREATE TEMP TABLE Clusters AS
WITH RECURSIVE
Clusters(id1, id2) AS (
  SELECT id1, id2 FROM Neighbors
  UNION
  SELECT c.id1, p.id2
  FROM Clusters c
  JOIN Neighbors p ON c.id2 = p.id1 AND c.id1 < p.id2
)
SELECT * FROM Clusters;

--DROP INDEX IF EXISTS idx_clusters_id2;
--CREATE INDEX idx_clusters_id2 ON Clusters (id2, id1);

-- ====================================
-- Step 4: Assign cluster representatives
-- ====================================

DROP TABLE IF EXISTS PointToWitness;
CREATE TEMP TABLE PointToWitness AS

WITH
-- Assign each point a single cluster representative -- remove hierarchical subclusters.
-- That is, each point is a part of multiple clusters; we only want the biggest.
-- For example, Clusters contains {(2,1), (3,1), (4,1), (3,2), (4,2), (4,3).}
-- We only want the biggest cluster with id 1: (2,1), (3,1), (4,1)
-- Also include singleton clusters that were not nearby any other points.
Canonical AS (
  SELECT id2 AS id, MIN(id1) AS cluster_id
  FROM Clusters
  GROUP BY id2
  UNION ALL
  -- include singleton clusters (points that are not within tolerance of any other point)
  SELECT id, id FROM (
	  SELECT id FROM MaterializedPoints
	  EXCEPT 
	  SELECT id2 FROM Clusters
  ) x
),
-- Determine one witness point per cluster 
-- (chooses minimum source currently. Could do centroid, or any other conditions)
Witness AS (
  SELECT DISTINCT ON (c.cluster_id) cluster_id, s.geom as cluster_geom
        --c.cluster_id, ST_Centroid(ST_Collect(s.geom)) AS cluster_geom
  FROM Canonical c
  JOIN MaterializedPoints s ON c.id = s.id
  ORDER BY c.cluster_id, s.source --
  --GROUP BY c.cluster_id
),
-- Step 3.5: Map every point to its witness point
-- source, id, element_id, and element_sub_id are the original point
-- cluster_id, cluster_geom are the new cluster witness which replaces the original 
-- SELECT DISTINCT cluster_id, cluster_geom FROM PointToWitness
-- returns all points (including internal) in the entire unioned dataset.
PointToWitness AS (
  SELECT 
    s.source,
    s.id,
	s.element_id,
	s.element_sub_id,
    s.geom,
	w.cluster_id,
    w.cluster_geom AS cluster_geom
  FROM MaterializedPoints s
  JOIN Canonical c ON s.id = c.id
  JOIN Witness w ON c.cluster_id = w.cluster_id
)
-- Return result
SELECT * FROM PointToWitness;


-- ====================================
-- Step 5: Return output nodes and edges
-- ====================================


-- get all the points associated with an edge (we tracked element_id for this purpose)
DROP TABLE IF EXISTS UnionEdges;
CREATE TEMP TABLE UnionEdges AS
  SELECT p.source, p.element_id, 
         p.geom as oldgeom,
         ST_MakeLine(ARRAY_AGG(w.cluster_geom ORDER BY w.element_sub_id)) AS newgeom
  FROM Path p, PointToWitness w
  WHERE p.element_id = w.element_id
  GROUP BY p.source, p.element_id,p.geom
;

--========================================
-- Return all witness nodes (with new ids)
--========================================
DROP TABLE IF EXISTS UnionNodes;
CREATE TEMP Table UnionNodes AS
SELECT DISTINCT 
    pw.source,
	pw.cluster_id as element_id,
    pw.cluster_geom AS geom
FROM PointToWitness pw
;
 --=====================================

-- Zones are considered distinct from edges and nodes:
-- there is no requirement that they share nodes.
-- So we can simply compute the union of all zones that overlap
-- That is: For each input zone, find all zones that intersect it. 
-- Then compute the union of those zones.  This strategy is not the only
-- one appropriate, but it's reasonable to avoid overlaps. 

-- Invariant: UnionZones will contain no intersecting zones in the output, even 
-- if a single dataset included intersecting zones in the input.
-- 
 DROP TABLE IF EXISTS UnionZones;
 CREATE TEMP TABLE UnionZones AS 
 WITH testzones as (
	SELECT d.name, z.id, z.zone_loc
	FROM testdataset d, zone z 
	where d.tdei_dataset_id = z.tdei_dataset_id 
)
SELECT z1.id, z1.zone_loc, ST_UNION(z2.zone_loc)
FROM testzones z1, testzones z2
WHERE ST_intersects(z1.zone_loc, z2.zone_loc)
GROUP BY z1.id, z1.zone_loc;

-- show test output
 SELECT * FROM UnionEdges;
