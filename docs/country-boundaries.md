# Offline country lookup

`CountryBoundaries.json` supplies a country/territory code when Apple geocoding
returns no ISO code. City names still require the online geocoder. Valid online
country codes take precedence. Ocean points and unassigned areas remain unknown.

Source: Natural Earth 1:10m Admin 0 Countries, downloaded 2026-10-19:
https://github.com/nvkelso/natural-earth-vector/blob/master/geojson/ne_10m_admin_0_countries.geojson

License: public domain, https://www.naturalearthdata.com/about/terms-of-use/

Generate with `scripts/build_country_boundaries.py source.geojson daymark/CountryBoundaries.json`.
The output records the source SHA-256. It retains polygon holes and islands,
uses `ISO_A2_EH`, excludes features without a two-letter code, and rounds
coordinates to five decimal places without simplifying geometries. These are
cartographic boundaries, not a precise border or shoreline authority; coastal
reclamation, very small islands and border locations can remain unresolved.

The bundled resource is loaded once. Polygon bounding boxes filter candidates
before a point-in-polygon check. No photos or coordinates go to a new service.
