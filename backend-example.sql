-- TrueOccupancy Backend: PostGIS Spatial Queries
-- This file contains example SQL queries for GIS data integration

-- ============================================
-- 1. DATABASE SETUP
-- ============================================

-- Enable PostGIS extension
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_topology;

-- ============================================
-- 2. CREATE TABLES
-- ============================================

-- Properties with full spatial data
CREATE TABLE properties (
  id SERIAL PRIMARY KEY,
  parcel_id VARCHAR(50) UNIQUE NOT NULL,
  address TEXT,
  geom GEOMETRY(Point, 4326), -- WGS84 (lat/lng)
  district VARCHAR(100),
  neighborhood VARCHAR(100),
  zoning VARCHAR(50),

  -- Privacy: No names, emails, or personal identifiers stored
  registered_residents INTEGER DEFAULT 0,

  -- Utility signals
  water_consumption_avg DECIMAL(10,2), -- L/day, 90-day rolling average
  electricity_baseline DECIMAL(10,2),  -- kWh/day

  -- Listing signals
  has_listing BOOLEAN DEFAULT FALSE,
  listing_platforms TEXT[], -- e.g., ['airbnb', 'booking.com']
  booking_days_per_year INTEGER,

  -- Timestamps
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);

-- Spatial index for fast geometric queries
CREATE INDEX idx_properties_geom ON properties USING GIST(geom);
CREATE INDEX idx_properties_district ON properties(district);
CREATE INDEX idx_properties_zoning ON properties(zoning);

-- Clusters (aggregated results, privacy-preserving)
CREATE TABLE clusters (
  id VARCHAR(20) PRIMARY KEY,
  centroid GEOMETRY(Point, 4326),
  boundary GEOMETRY(Polygon, 4326),

  -- Aggregated data
  property_count INTEGER NOT NULL,
  district VARCHAR(100),
  neighborhood VARCHAR(100),

  -- Classification
  misuse_type VARCHAR(100),
  confidence_level VARCHAR(20) CHECK (confidence_level IN ('high', 'medium', 'watch')),
  composite_score DECIMAL(3,2), -- 0.00 to 1.00

  -- Aggregate signals (percentages)
  pct_water_below_threshold DECIMAL(5,2),
  pct_active_listings DECIMAL(5,2),
  pct_residential_zoning DECIMAL(5,2),
  pct_no_residents DECIMAL(5,2),

  -- Privacy enforcement
  privacy_compliant BOOLEAN DEFAULT FALSE,

  created_at TIMESTAMP DEFAULT NOW(),

  -- Constraint: must have 500+ properties
  CONSTRAINT min_cluster_size CHECK (property_count >= 500)
);

CREATE INDEX idx_clusters_boundary ON clusters USING GIST(boundary);
CREATE INDEX idx_clusters_district ON clusters(district);

-- Audit log for all queries
CREATE TABLE audit_log (
  id SERIAL PRIMARY KEY,
  user_id_hash VARCHAR(64) NOT NULL, -- One-way hash, not reversible
  timestamp TIMESTAMP DEFAULT NOW(),
  cluster_id VARCHAR(20),
  query_type VARCHAR(50),
  confidence_filter VARCHAR(20),
  action TEXT,
  status VARCHAR(20),

  -- Flag anomalous queries
  is_anomalous BOOLEAN DEFAULT FALSE,
  anomaly_reason TEXT
);

CREATE INDEX idx_audit_log_timestamp ON audit_log(timestamp);
CREATE INDEX idx_audit_log_user ON audit_log(user_id_hash);

-- ============================================
-- 3. IMPORT CADASTRAL DATA
-- ============================================

-- Example: Import from CSV with coordinates
COPY properties (parcel_id, address, geom, district, neighborhood, zoning)
FROM '/path/to/cadastre.csv'
WITH (FORMAT csv, HEADER true);

-- Or create from lat/lng columns
INSERT INTO properties (parcel_id, address, geom, district, zoning)
SELECT
  parcel_id,
  address,
  ST_SetSRID(ST_MakePoint(longitude, latitude), 4326) as geom,
  district,
  zoning
FROM cadastre_import;

-- ============================================
-- 4. GENERATE CLUSTERS (DBSCAN Algorithm)
-- ============================================

-- Generate clusters using spatial density-based clustering
-- Parameters:
--   eps = 100 meters (properties within this distance are grouped)
--   minpoints = 500 (minimum cluster size for privacy)

WITH property_clusters AS (
  SELECT
    id,
    parcel_id,
    geom,
    district,
    neighborhood,
    water_consumption_avg,
    has_listing,
    registered_residents,
    zoning,
    -- Cluster assignment using DBSCAN
    ST_ClusterDBSCAN(geom, eps := 0.001, minpoints := 500) OVER (
      PARTITION BY district
    ) AS cluster_id
  FROM properties
  WHERE
    -- Filter by district (e.g., Gràcia)
    district = 'Gràcia'
    -- Only include properties with recent data
    AND updated_at > NOW() - INTERVAL '30 days'
),
cluster_aggregates AS (
  SELECT
    cluster_id,
    COUNT(*) as property_count,

    -- Spatial aggregation
    ST_Centroid(ST_Collect(geom)) as centroid,
    ST_ConvexHull(ST_Collect(geom)) as boundary,

    -- District/neighborhood (most common)
    MODE() WITHIN GROUP (ORDER BY district) as district,
    MODE() WITHIN GROUP (ORDER BY neighborhood) as neighborhood,

    -- Signal percentages
    (SUM(CASE WHEN water_consumption_avg < 5 THEN 1 ELSE 0 END)::DECIMAL / COUNT(*) * 100) as pct_water_below_threshold,
    (SUM(CASE WHEN has_listing THEN 1 ELSE 0 END)::DECIMAL / COUNT(*) * 100) as pct_active_listings,
    (SUM(CASE WHEN zoning LIKE '%residential%' THEN 1 ELSE 0 END)::DECIMAL / COUNT(*) * 100) as pct_residential_zoning,
    (SUM(CASE WHEN registered_residents = 0 THEN 1 ELSE 0 END)::DECIMAL / COUNT(*) * 100) as pct_no_residents
  FROM property_clusters
  WHERE cluster_id IS NOT NULL
  GROUP BY cluster_id
  HAVING COUNT(*) >= 500 -- Privacy threshold
),
classified_clusters AS (
  SELECT
    'C-' || LPAD(cluster_id::TEXT, 3, '0') as id,
    centroid,
    boundary,
    property_count,
    district,
    neighborhood,
    pct_water_below_threshold,
    pct_active_listings,
    pct_residential_zoning,
    pct_no_residents,

    -- Classify misuse type (simplified logic)
    CASE
      WHEN pct_water_below_threshold > 80 AND pct_no_residents > 90 THEN 'Structural vacancy'
      WHEN pct_active_listings > 60 THEN 'Illegal tourist use'
      WHEN pct_residential_zoning < 50 THEN 'Illegal office conversion'
      ELSE 'Speculative withholding'
    END as misuse_type,

    -- Confidence level
    CASE
      WHEN pct_water_below_threshold > 85 AND pct_no_residents > 90 THEN 'high'
      WHEN pct_active_listings > 70 OR pct_no_residents > 80 THEN 'high'
      WHEN pct_active_listings > 50 OR pct_no_residents > 60 THEN 'medium'
      ELSE 'watch'
    END as confidence_level,

    -- Composite score (weighted average)
    (
      (pct_water_below_threshold * 0.3) +
      (pct_active_listings * 0.2) +
      (pct_no_residents * 0.4) +
      ((100 - pct_residential_zoning) * 0.1)
    ) / 100 as composite_score,

    TRUE as privacy_compliant
  FROM cluster_aggregates
)
INSERT INTO clusters (
  id, centroid, boundary, property_count, district, neighborhood,
  misuse_type, confidence_level, composite_score,
  pct_water_below_threshold, pct_active_listings, pct_residential_zoning, pct_no_residents,
  privacy_compliant
)
SELECT * FROM classified_clusters;

-- ============================================
-- 5. SPATIAL QUERIES
-- ============================================

-- Find clusters within bounding box
SELECT
  id,
  ST_AsGeoJSON(centroid)::json as centroid,
  ST_AsGeoJSON(boundary)::json as boundary,
  property_count,
  misuse_type,
  confidence_level,
  composite_score
FROM clusters
WHERE ST_Intersects(
  boundary,
  ST_MakeEnvelope(2.15, 41.39, 2.17, 41.41, 4326) -- west, south, east, north
)
AND confidence_level IN ('high', 'medium')
ORDER BY composite_score DESC;

-- Find clusters within radius of a point
SELECT
  id,
  ST_Distance(centroid::geography, ST_SetSRID(ST_MakePoint(2.1564, 41.4036), 4326)::geography) as distance_meters,
  property_count,
  confidence_level
FROM clusters
WHERE ST_DWithin(
  centroid::geography,
  ST_SetSRID(ST_MakePoint(2.1564, 41.4036), 4326)::geography,
  1000 -- 1km radius
)
ORDER BY distance_meters;

-- Get detailed cluster statistics (privacy-compliant)
SELECT
  c.id,
  c.property_count,
  c.district,
  c.neighborhood,
  c.misuse_type,
  c.confidence_level,
  c.composite_score,
  c.pct_water_below_threshold,
  c.pct_active_listings,
  c.pct_residential_zoning,
  c.pct_no_residents,
  ST_AsGeoJSON(c.centroid)::json as centroid,
  ST_AsGeoJSON(c.boundary)::json as boundary,
  ST_Area(c.boundary::geography) as area_sqm
FROM clusters c
WHERE c.id = 'C-001'
AND c.privacy_compliant = TRUE;

-- ============================================
-- 6. PRIVACY ENFORCEMENT QUERIES
-- ============================================

-- Verify all clusters meet minimum size requirement
SELECT
  COUNT(*) as total_clusters,
  COUNT(*) FILTER (WHERE property_count >= 500) as privacy_compliant,
  COUNT(*) FILTER (WHERE property_count < 500) as privacy_violation
FROM clusters;

-- Find and remove clusters below threshold (should never happen due to constraint)
DELETE FROM clusters WHERE property_count < 500;

-- ============================================
-- 7. AUDIT LOGGING
-- ============================================

-- Log a query (called by API)
INSERT INTO audit_log (user_id_hash, cluster_id, query_type, confidence_filter, action, status)
VALUES (
  SHA256('user@example.com')::TEXT, -- One-way hash
  'C-001',
  'Structural vacancy',
  'high',
  'Queried — vacancy, high only',
  'logged'
);

-- Flag anomalous query (attempted to query below threshold)
INSERT INTO audit_log (
  user_id_hash, cluster_id, query_type, confidence_filter, action, status,
  is_anomalous, anomaly_reason
)
VALUES (
  SHA256('suspicious_user@example.com')::TEXT,
  NULL,
  'All types',
  '<500 props',
  'BLOCKED — below threshold',
  'blocked',
  TRUE,
  'Attempted to query cluster with fewer than 500 properties'
);

-- Get audit trail for a cluster
SELECT
  timestamp,
  LEFT(user_id_hash, 8) || '…' as user_hash_abbrev,
  action,
  status
FROM audit_log
WHERE cluster_id = 'C-001'
ORDER BY timestamp DESC
LIMIT 20;

-- Detect anomalous access patterns
SELECT
  user_id_hash,
  COUNT(*) as query_count,
  COUNT(DISTINCT cluster_id) as unique_clusters,
  COUNT(*) FILTER (WHERE is_anomalous) as anomalous_queries
FROM audit_log
WHERE timestamp > NOW() - INTERVAL '24 hours'
GROUP BY user_id_hash
HAVING COUNT(*) > 50 OR COUNT(*) FILTER (WHERE is_anomalous) > 0
ORDER BY query_count DESC;

-- ============================================
-- 8. PERFORMANCE OPTIMIZATION
-- ============================================

-- Refresh materialized view for faster queries
CREATE MATERIALIZED VIEW cluster_summary AS
SELECT
  c.id,
  c.district,
  c.confidence_level,
  c.misuse_type,
  c.property_count,
  ST_AsGeoJSON(c.centroid)::json as centroid,
  ST_AsGeoJSON(c.boundary)::json as boundary
FROM clusters c
WHERE c.privacy_compliant = TRUE;

CREATE INDEX idx_cluster_summary_boundary ON cluster_summary USING GIST(
  ST_GeomFromGeoJSON((boundary->>'coordinates')::text)
);

REFRESH MATERIALIZED VIEW CONCURRENTLY cluster_summary;

-- Vacuum and analyze for better query performance
VACUUM ANALYZE properties;
VACUUM ANALYZE clusters;
VACUUM ANALYZE audit_log;

-- ============================================
-- 9. DATA RETENTION & CLEANUP
-- ============================================

-- Purge old audit logs (keep 24 months)
DELETE FROM audit_log
WHERE timestamp < NOW() - INTERVAL '24 months';

-- Archive old property data (keep 24 months)
DELETE FROM properties
WHERE updated_at < NOW() - INTERVAL '24 months';

-- Recreate clusters after data cleanup
TRUNCATE clusters;
-- Re-run cluster generation query from section 4

-- ============================================
-- 10. EXAMPLE API QUERY
-- ============================================

-- Query that would be exposed via REST API
-- GET /api/clusters?district=Gràcia&type=vacancy&min_confidence=medium

PREPARE get_clusters_api (VARCHAR, VARCHAR, VARCHAR) AS
SELECT
  c.id,
  c.property_count,
  c.district,
  c.neighborhood,
  c.misuse_type,
  c.confidence_level,
  c.composite_score,
  c.pct_water_below_threshold,
  c.pct_active_listings,
  c.pct_residential_zoning,
  c.pct_no_residents,
  ST_AsGeoJSON(c.centroid)::json as centroid,
  ST_AsGeoJSON(c.boundary)::json as boundary
FROM clusters c
WHERE
  c.district = $1
  AND c.misuse_type = $2
  AND (
    ($3 = 'high' AND c.confidence_level = 'high') OR
    ($3 = 'medium' AND c.confidence_level IN ('high', 'medium')) OR
    ($3 = 'watch' AND c.confidence_level IN ('high', 'medium', 'watch'))
  )
  AND c.privacy_compliant = TRUE
ORDER BY c.composite_score DESC
LIMIT 100;

-- Execute example
EXECUTE get_clusters_api('Gràcia', 'Structural vacancy', 'medium');
