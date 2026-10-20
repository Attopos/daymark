"""Extract ISO country polygons without simplifying borders or coastlines.

Input: Natural Earth 1:10m admin-0 countries GeoJSON, public domain.
https://github.com/nvkelso/natural-earth-vector/blob/master/geojson/ne_10m_admin_0_countries.geojson
Usage: python3 scripts/build_country_boundaries.py source.geojson output.json
"""
import hashlib
import json
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_bytes()
polygons = []
for feature in json.loads(source)['features']:
    code = feature['properties'].get('ISO_A2_EH', '')
    if len(code) != 2 or not code.isascii() or not code.isalpha():
        continue  # Unassigned/disputed areas are not guessed.
    geometry = feature['geometry']
    parts = [geometry['coordinates']] if geometry['type'] == 'Polygon' else geometry['coordinates']
    for rings in parts:
        # Five decimal places retain roughly metre-level coordinate precision.
        rings = [[[round(x, 5), round(y, 5)] for x, y, *_ in ring] for ring in rings]
        exterior = rings[0]
        polygons.append({'code': code, 'bounds': [min(p[0] for p in exterior), min(p[1] for p in exterior), max(p[0] for p in exterior), max(p[1] for p in exterior)], 'rings': rings})
output = {'sourceSHA256': hashlib.sha256(source).hexdigest(), 'polygons': polygons}
Path(sys.argv[2]).write_text(json.dumps(output, separators=(',', ':'))+'\n')
print(f'{len(polygons)} polygons; {Path(sys.argv[2]).stat().st_size:,} bytes; source SHA256 {output["sourceSHA256"]}')
