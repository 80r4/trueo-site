# How to Use the GIS Map Component

## Quick Start

Replace the mock `ClusterMap` component with the real GIS-enabled map:

### 1. Update InspectorPage.tsx

```tsx
// Import the GIS map instead of mock map
import { GISClusterMap } from './GISClusterMap';
import { clusterGeoData } from '../gis-data-example';

// In the InspectorPage component:
<GISClusterMap
  clusters={clusters}
  geoData={clusterGeoData}
  selectedIndex={selectedClusterIndex}
  onSelectCluster={setSelectedClusterIndex}
/>
```

### 2. Add Leaflet CSS to your app

In `src/index.css` or `src/App.tsx`, add:

```tsx
import 'leaflet/dist/leaflet.css';
```

### 3. Connect to Real Backend Data

Replace the mock `gis-data-example.ts` with API calls:

```tsx
// src/app/hooks/useClusterGeoData.ts
import { useState, useEffect } from 'react';
import { ClusterGeoData } from '../gis-types';

export function useClusterGeoData(district: string) {
  const [geoData, setGeoData] = useState<ClusterGeoData[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    async function fetchGeoData() {
      try {
        const response = await fetch(
          `/api/clusters/geo?district=${encodeURIComponent(district)}`
        );
        const data = await response.json();
        setGeoData(data);
      } catch (error) {
        console.error('Failed to fetch GIS data:', error);
      } finally {
        setLoading(false);
      }
    }

    fetchGeoData();
  }, [district]);

  return { geoData, loading };
}

// Usage in InspectorPage:
const { geoData, loading } = useClusterGeoData('Gràcia');

if (loading) return <div>Loading map...</div>;

return (
  <GISClusterMap
    clusters={clusters}
    geoData={geoData}
    selectedIndex={selectedClusterIndex}
    onSelectCluster={setSelectedClusterIndex}
  />
);
```

## Advanced Features

### 1. Heat Map Layer

Add a heat map overlay showing cluster density:

```tsx
import L from 'leaflet';
import 'leaflet.heat';

// In GISClusterMap.tsx:
useEffect(() => {
  if (!mapRef.current) return;

  const heatData = clusters.map(cluster => {
    const geo = geoData.find(g => g.id === cluster.id);
    if (!geo) return null;
    return [geo.centroid.lat, geo.centroid.lng, cluster.score];
  }).filter(Boolean);

  L.heatLayer(heatData as any, {
    radius: 25,
    blur: 15,
    maxZoom: 17,
  }).addTo(mapRef.current);
}, [clusters, geoData]);
```

### 2. Custom Marker Clusters

Group nearby clusters when zoomed out:

```bash
pnpm add leaflet.markercluster
```

```tsx
import 'leaflet.markercluster';

const markerClusterGroup = L.markerClusterGroup();

clusters.forEach((cluster, index) => {
  const geo = geoData.find(g => g.id === cluster.id);
  if (!geo) return;

  const marker = L.marker([geo.centroid.lat, geo.centroid.lng])
    .bindPopup(`${cluster.id} - ${cluster.props} properties`)
    .on('click', () => onSelectCluster(index));

  markerClusterGroup.addLayer(marker);
});

mapRef.current.addLayer(markerClusterGroup);
```

### 3. Layer Controls (Toggle Data Sources)

```tsx
import L from 'leaflet';

const baseMaps = {
  'Street': L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png'),
  'Satellite': L.tileLayer('https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}'),
};

const overlays = {
  'Clusters': clusterLayer,
  'Heat Map': heatLayer,
  'Cadastral Parcels': cadastreLayer,
};

L.control.layers(baseMaps, overlays).addTo(map);
```

### 4. Drawing Tools (Select Custom Areas)

```bash
pnpm add leaflet-draw
```

```tsx
import 'leaflet-draw';

const drawnItems = new L.FeatureGroup();
map.addLayer(drawnItems);

const drawControl = new L.Control.Draw({
  draw: {
    polygon: true,
    rectangle: true,
    circle: false,
    marker: false,
    polyline: false,
  },
  edit: {
    featureGroup: drawnItems,
  },
});

map.addControl(drawControl);

map.on(L.Draw.Event.CREATED, (event) => {
  const layer = event.layer;
  drawnItems.addLayer(layer);

  // Get clusters within drawn polygon
  const bounds = layer.getBounds();
  const clustersInArea = clusters.filter(c => {
    const geo = geoData.find(g => g.id === c.id);
    return geo && bounds.contains([geo.centroid.lat, geo.centroid.lng]);
  });

  console.log('Clusters in selected area:', clustersInArea);
});
```

### 5. Geocoding (Search by Address)

```bash
pnpm add leaflet-geosearch
```

```tsx
import { GeoSearchControl, OpenStreetMapProvider } from 'leaflet-geosearch';
import 'leaflet-geosearch/dist/geosearch.css';

const provider = new OpenStreetMapProvider();
const searchControl = new GeoSearchControl({
  provider,
  style: 'bar',
  searchLabel: 'Search address in Barcelona...',
});

map.addControl(searchControl);
```

### 6. Distance Measurement Tool

```bash
pnpm add leaflet-measure
```

```tsx
import 'leaflet-measure';
import 'leaflet-measure/dist/leaflet-measure.css';

L.control.measure({
  primaryLengthUnit: 'meters',
  secondaryLengthUnit: 'kilometers',
  primaryAreaUnit: 'sqmeters',
  secondaryAreaUnit: 'hectares',
}).addTo(map);
```

## Backend API Integration

### Example API Response Format

```json
GET /api/clusters/geo?district=Gràcia

Response:
[
  {
    "id": "C-001",
    "centroid": {
      "lat": 41.4120,
      "lng": 2.1520
    },
    "boundary": {
      "type": "Polygon",
      "coordinates": [[
        [2.1500, 41.4130],
        [2.1540, 41.4130],
        [2.1540, 41.4110],
        [2.1500, 41.4110],
        [2.1500, 41.4130]
      ]]
    },
    "properties": {
      "area_sqm": 185000,
      "district": "Gràcia",
      "neighborhood": "Vila de Gràcia N"
    }
  }
]
```

### Example API Client

```tsx
// src/app/services/gis-api.ts
export class GISAPIClient {
  private baseURL = process.env.REACT_APP_API_URL || '/api';

  async getClusters(params: {
    district?: string;
    bbox?: [number, number, number, number]; // [west, south, east, north]
    type?: string;
    minConfidence?: string;
  }) {
    const url = new URL(`${this.baseURL}/clusters/geo`);

    if (params.district) url.searchParams.set('district', params.district);
    if (params.bbox) url.searchParams.set('bbox', params.bbox.join(','));
    if (params.type) url.searchParams.set('type', params.type);
    if (params.minConfidence) url.searchParams.set('min_confidence', params.minConfidence);

    const response = await fetch(url);
    if (!response.ok) throw new Error('Failed to fetch clusters');

    return response.json();
  }

  async getClusterDetails(clusterId: string) {
    const response = await fetch(`${this.baseURL}/clusters/${clusterId}`);
    if (!response.ok) throw new Error('Failed to fetch cluster details');

    return response.json();
  }

  async logQuery(data: {
    clusterId: string;
    queryType: string;
    confidenceFilter: string;
  }) {
    const response = await fetch(`${this.baseURL}/audit/query`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(data),
    });

    if (!response.ok) throw new Error('Failed to log query');

    return response.json();
  }
}

export const gisAPI = new GISAPIClient();
```

## Performance Tips

### 1. Use Vector Tiles for Large Datasets

Instead of loading all polygons at once, use vector tiles:

```tsx
import maplibregl from 'maplibre-gl';

const map = new maplibregl.Map({
  container: 'map',
  style: 'https://demotiles.maplibre.org/style.json',
  center: [2.1564, 41.4036],
  zoom: 14,
});

map.addSource('clusters', {
  type: 'vector',
  tiles: ['https://your-api.com/tiles/{z}/{x}/{y}.mvt'],
  minzoom: 10,
  maxzoom: 16,
});

map.addLayer({
  id: 'clusters-fill',
  type: 'fill',
  source: 'clusters',
  'source-layer': 'clusters',
  paint: {
    'fill-color': [
      'match',
      ['get', 'confidence'],
      'high', '#C0392B',
      'medium', '#8B6000',
      'watch', '#2E5496',
      '#cccccc'
    ],
    'fill-opacity': 0.3,
  },
});
```

### 2. Lazy Load Map

Only load the map when the user navigates to the Inspector page:

```tsx
import { lazy, Suspense } from 'react';

const GISClusterMap = lazy(() => import('./GISClusterMap'));

<Suspense fallback={<div>Loading map...</div>}>
  <GISClusterMap {...props} />
</Suspense>
```

### 3. Debounce Map Updates

```tsx
import { useMemo } from 'react';
import debounce from 'lodash/debounce';

const debouncedUpdate = useMemo(
  () => debounce((clusters) => {
    updateMapMarkers(clusters);
  }, 300),
  []
);

useEffect(() => {
  debouncedUpdate(clusters);
}, [clusters, debouncedUpdate]);
```

## Testing GIS Components

```tsx
// src/app/components/__tests__/GISClusterMap.test.tsx
import { render } from '@testing-library/react';
import { GISClusterMap } from '../GISClusterMap';

// Mock Leaflet
jest.mock('leaflet', () => ({
  map: jest.fn(() => ({
    setView: jest.fn(),
    addLayer: jest.fn(),
  })),
  tileLayer: jest.fn(() => ({
    addTo: jest.fn(),
  })),
  polygon: jest.fn(() => ({
    addTo: jest.fn(),
    bindPopup: jest.fn(),
    on: jest.fn(),
    setStyle: jest.fn(),
  })),
}));

test('renders GIS map with clusters', () => {
  const { container } = render(
    <GISClusterMap
      clusters={mockClusters}
      geoData={mockGeoData}
      selectedIndex={null}
      onSelectCluster={jest.fn()}
    />
  );

  expect(container.querySelector('#gis-map')).toBeInTheDocument();
});
```

## Next Steps

1. ✅ Install Leaflet: `pnpm add react-leaflet leaflet`
2. ✅ Import `GISClusterMap` component
3. ✅ Add Leaflet CSS to your app
4. 🔄 Set up backend API with PostGIS
5. 🔄 Replace mock data with API calls
6. 🔄 Add advanced features (heat maps, drawing tools, etc.)
7. 🔄 Deploy tile server for production

For questions, see the main `GIS_INTEGRATION_GUIDE.md`.
