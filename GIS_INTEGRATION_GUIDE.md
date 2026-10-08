# GIS Data Integration Guide for TrueOccupancy

This guide explains how to integrate real GIS (Geographic Information System) data into the TrueOccupancy dashboard.

## Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│                  Frontend (React)                   │
│  ┌──────────────┐      ┌─────────────────────┐    │
│  │  Leaflet Map │◄─────│  Cluster Polygons   │    │
│  └──────────────┘      └─────────────────────┘    │
│         ▲                                           │
│         │                                           │
│         ▼                                           │
│  ┌──────────────────────────────────────────┐      │
│  │      Privacy Layer (500+ properties)      │      │
│  │  - Aggregate to clusters                  │      │
│  │  - Spatial blur (50m noise)               │      │
│  │  - No individual addresses shown          │      │
│  └──────────────────────────────────────────┘      │
└─────────────────────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────┐
│                  Backend API                         │
│  ┌──────────────────────────────────────────┐      │
│  │  Spatial Aggregation Service             │      │
│  │  - PostGIS queries                        │      │
│  │  - Cluster generation (k-means, DBSCAN)  │      │
│  │  - Privacy enforcement                    │      │
│  └──────────────────────────────────────────┘      │
└─────────────────────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────┐
│                  Data Sources                        │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐   │
│  │  Cadastre  │  │   Utility  │  │  Listings  │   │
│  │   (WFS)    │  │    Data    │  │  (Scraped) │   │
│  └────────────┘  └────────────┘  └────────────┘   │
└─────────────────────────────────────────────────────┘
```

## 1. Data Sources

### A. Cadastral Data (Property Boundaries)
```typescript
// Example: Fetch from Barcelona Open Data Portal
const fetchCadastralData = async (bbox: BoundingBox) => {
  const response = await fetch(
    `https://opendata-ajuntament.barcelona.cat/data/api/3/action/datastore_search?` +
    `resource_id=cadastre&` +
    `filters={"bbox":"${bbox.west},${bbox.south},${bbox.east},${bbox.north}"}`
  );
  return response.json();
};
```

### B. INSPIRE WFS (European Spatial Data)
```typescript
// Example: Query INSPIRE-compliant Web Feature Service
const queryINSPIREData = async (layer: string, bbox: BoundingBox) => {
  const url = new URL('https://idebarcelona.cat/geoserver/wfs');
  url.searchParams.set('service', 'WFS');
  url.searchParams.set('version', '2.0.0');
  url.searchParams.set('request', 'GetFeature');
  url.searchParams.set('typeName', layer);
  url.searchParams.set('bbox', `${bbox.west},${bbox.south},${bbox.east},${bbox.north}`);
  url.searchParams.set('outputFormat', 'application/json');

  const response = await fetch(url);
  return response.json();
};
```

### C. Utility Company Data
```typescript
// Example: Internal API with privacy-preserving aggregation
const fetchAggregatedUtilityData = async (clusterId: string) => {
  const response = await fetch(`/api/clusters/${clusterId}/utility-stats`);
  // Returns aggregated stats for 500+ properties only
  return response.json();
};
```

## 2. Backend Spatial Processing (PostgreSQL + PostGIS)

### Create Spatial Tables
```sql
-- Enable PostGIS extension
CREATE EXTENSION IF NOT EXISTS postgis;

-- Properties table with spatial data
CREATE TABLE properties (
  id SERIAL PRIMARY KEY,
  parcel_id VARCHAR(50) UNIQUE,
  address TEXT,
  geom GEOMETRY(Point, 4326), -- WGS84 coordinates
  zoning VARCHAR(50),
  water_consumption_avg DECIMAL(10,2),
  has_listing BOOLEAN,
  registered_residents INTEGER,
  created_at TIMESTAMP DEFAULT NOW()
);

-- Create spatial index
CREATE INDEX idx_properties_geom ON properties USING GIST(geom);

-- Clusters table
CREATE TABLE clusters (
  id VARCHAR(20) PRIMARY KEY,
  centroid GEOMETRY(Point, 4326),
  boundary GEOMETRY(Polygon, 4326),
  property_count INTEGER,
  district VARCHAR(100),
  neighborhood VARCHAR(100),
  confidence_level VARCHAR(20),
  misuse_type VARCHAR(100),
  created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_clusters_boundary ON clusters USING GIST(boundary);
```

### Spatial Clustering Query
```sql
-- Generate clusters using ST_ClusterDBSCAN
-- Groups properties within 100m, minimum 500 properties per cluster
WITH property_clusters AS (
  SELECT 
    id,
    geom,
    ST_ClusterDBSCAN(geom, eps := 100, minpoints := 500) OVER() AS cluster_id,
    water_consumption_avg,
    has_listing,
    registered_residents
  FROM properties
  WHERE 
    -- Filter by area (e.g., Gràcia district)
    ST_Within(geom, ST_GeomFromText('POLYGON((...))', 4326))
),
cluster_stats AS (
  SELECT 
    cluster_id,
    COUNT(*) as property_count,
    ST_Centroid(ST_Collect(geom)) as centroid,
    ST_ConvexHull(ST_Collect(geom)) as boundary,
    AVG(water_consumption_avg) as avg_water,
    SUM(CASE WHEN has_listing THEN 1 ELSE 0 END)::DECIMAL / COUNT(*) * 100 as pct_listings,
    SUM(CASE WHEN registered_residents = 0 THEN 1 ELSE 0 END)::DECIMAL / COUNT(*) * 100 as pct_no_residents
  FROM property_clusters
  WHERE cluster_id IS NOT NULL
  GROUP BY cluster_id
  HAVING COUNT(*) >= 500 -- Privacy threshold
)
SELECT 
  'C-' || LPAD(cluster_id::TEXT, 3, '0') as id,
  ST_AsGeoJSON(centroid)::json as centroid,
  ST_AsGeoJSON(boundary)::json as boundary,
  property_count,
  avg_water,
  pct_listings,
  pct_no_residents,
  -- Classify confidence level
  CASE 
    WHEN pct_no_residents > 90 AND avg_water < 5 THEN 'high'
    WHEN pct_listings > 60 OR pct_no_residents > 70 THEN 'medium'
    ELSE 'watch'
  END as confidence_level
FROM cluster_stats
ORDER BY property_count DESC;
```

## 3. Privacy-Preserving Techniques

### A. K-Anonymity (Minimum Cluster Size)
```typescript
// Enforce 500+ properties per cluster
const MINIMUM_CLUSTER_SIZE = 500;

function filterPrivacyCompliantClusters(clusters: Cluster[]) {
  return clusters.filter(c => c.props >= MINIMUM_CLUSTER_SIZE);
}
```

### B. Spatial Blurring
```typescript
// Add random noise to exact coordinates (±50 meters)
function addSpatialNoise(coord: GeoCoordinate): GeoCoordinate {
  const BLUR_METERS = 50;
  const metersPerDegreeLat = 111320;
  const metersPerDegreeLng = 111320 * Math.cos(coord.lat * Math.PI / 180);

  return {
    lat: coord.lat + (Math.random() - 0.5) * (BLUR_METERS / metersPerDegreeLat),
    lng: coord.lng + (Math.random() - 0.5) * (BLUR_METERS / metersPerDegreeLng),
  };
}
```

### C. Differential Privacy (Optional Advanced)
```sql
-- Add Laplace noise to aggregate statistics
CREATE OR REPLACE FUNCTION add_laplace_noise(value DECIMAL, sensitivity DECIMAL, epsilon DECIMAL)
RETURNS DECIMAL AS $$
DECLARE
  scale DECIMAL;
  u DECIMAL;
  noise DECIMAL;
BEGIN
  scale := sensitivity / epsilon;
  u := random() - 0.5;
  noise := -scale * SIGN(u) * LN(1 - 2 * ABS(u));
  RETURN value + noise;
END;
$$ LANGUAGE plpgsql;

-- Use in queries
SELECT 
  cluster_id,
  add_laplace_noise(AVG(water_consumption_avg), 10.0, 0.1) as noisy_avg_water
FROM property_clusters
GROUP BY cluster_id;
```

## 4. Frontend Map Integration

### Option A: Leaflet (Used in example)
```tsx
import L from 'leaflet';
import 'leaflet/dist/leaflet.css';

const map = L.map('map').setView([41.4036, 2.1564], 14);
L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png').addTo(map);

// Add cluster polygons
geoData.forEach(cluster => {
  const polygon = L.geoJSON(cluster.boundary, {
    style: { color: getColorByConfidence(cluster.confidence) }
  }).addTo(map);
});
```

### Option B: MapLibre GL (Better Performance)
```bash
pnpm add maplibre-gl react-map-gl
```

```tsx
import Map, { Source, Layer } from 'react-map-gl/maplibre';

<Map
  initialViewState={{
    latitude: 41.4036,
    longitude: 2.1564,
    zoom: 14
  }}
  mapStyle="https://basemaps.cartocdn.com/gl/positron-gl-style/style.json"
>
  <Source type="geojson" data={clusterGeoJSON}>
    <Layer
      type="fill"
      paint={{
        'fill-color': ['get', 'color'],
        'fill-opacity': 0.3
      }}
    />
  </Source>
</Map>
```

## 5. Heat Maps for Density Visualization

```typescript
// Generate heat map data from cluster centroids
const heatMapData = clusters.map(c => ({
  lat: c.centroid.lat,
  lng: c.centroid.lng,
  intensity: c.score // 0-1 confidence score
}));

// Add to Leaflet
import 'leaflet.heat';
L.heatLayer(heatMapData.map(d => [d.lat, d.lng, d.intensity])).addTo(map);
```

## 6. API Design

### REST Endpoints
```typescript
// Get clusters for a geographic area
GET /api/clusters?bbox=2.15,41.39,2.17,41.41&type=vacancy&min_confidence=medium

// Get aggregate statistics (no individual data)
GET /api/clusters/C-001/stats
Response: {
  "cluster_id": "C-001",
  "property_count": 912,
  "signals": {
    "water_below_threshold_pct": 88,
    "active_listings_pct": 12,
    "no_residents_pct": 94
  },
  "boundary": { /* GeoJSON */ },
  "centroid": { "lat": 41.4120, "lng": 2.1520 }
}

// Privacy log (all queries logged)
POST /api/audit/query
Body: {
  "user_id": "hashed_user_id",
  "cluster_id": "C-001",
  "query_type": "vacancy",
  "confidence_filter": "high"
}
```

## 7. Performance Optimization

### A. Vector Tiles (for large datasets)
```typescript
// Use Mapbox Vector Tiles for efficient rendering
const vectorTileUrl = 
  'https://api.maptiler.com/tiles/v3/{z}/{x}/{y}.pbf?key=YOUR_KEY';

// Server-side: Generate MVT tiles from PostGIS
SELECT ST_AsMVT(tile, 'clusters', 4096, 'geom') FROM (
  SELECT 
    id,
    confidence_level,
    property_count,
    ST_AsMVTGeom(boundary, TileBBox(z, x, y, 3857), 4096, 256, true) as geom
  FROM clusters
  WHERE ST_Intersects(boundary, TileBBox(z, x, y, 3857))
) tile;
```

### B. Spatial Indexing
```sql
-- Use R-tree spatial index for fast queries
CREATE INDEX idx_clusters_geom ON clusters USING GIST(boundary);
CLUSTER clusters USING idx_clusters_geom;
ANALYZE clusters;
```

### C. Caching
```typescript
// Cache cluster data with Redis + geospatial commands
import { createClient } from 'redis';

const redis = createClient();

// Add cluster to geospatial index
await redis.geoAdd('clusters:locations', {
  longitude: cluster.centroid.lng,
  latitude: cluster.centroid.lat,
  member: cluster.id
});

// Find clusters within radius
const nearby = await redis.geoRadius('clusters:locations', {
  longitude: 2.1564,
  latitude: 41.4036,
  radius: 1000, // meters
  unit: 'm'
});
```

## 8. Testing GIS Functionality

```typescript
// Test spatial clustering
test('clusters have minimum 500 properties', () => {
  const clusters = generateClusters(properties);
  clusters.forEach(c => {
    expect(c.property_count).toBeGreaterThanOrEqual(500);
  });
});

// Test privacy constraints
test('individual properties not identifiable', () => {
  const cluster = getClusters('C-001');
  expect(cluster).not.toHaveProperty('individual_addresses');
  expect(cluster.property_count).toBeGreaterThan(500);
});

// Test coordinate accuracy
test('coordinates within Barcelona bounds', () => {
  clusters.forEach(c => {
    expect(c.centroid.lat).toBeGreaterThan(41.32);
    expect(c.centroid.lat).toBeLessThan(41.47);
    expect(c.centroid.lng).toBeGreaterThan(2.05);
    expect(c.centroid.lng).toBeLessThan(2.23);
  });
});
```

## 9. Next Steps

1. **Set up PostGIS database** with spatial extensions
2. **Import cadastral data** from open data portals
3. **Implement clustering algorithm** using ST_ClusterDBSCAN
4. **Create REST API** with privacy enforcement
5. **Replace mock map** with `GISClusterMap` component
6. **Add tile server** for base maps (OpenStreetMap, CartoDB, etc.)
7. **Implement audit logging** for all spatial queries
8. **Test privacy guarantees** with k-anonymity validation

## Resources

- **PostGIS Documentation**: https://postgis.net/documentation/
- **Leaflet**: https://leafletjs.com/
- **Barcelona Open Data**: https://opendata-ajuntament.barcelona.cat/
- **INSPIRE Geoportal**: https://inspire-geoportal.ec.europa.eu/
- **GeoJSON Specification**: https://geojson.org/
