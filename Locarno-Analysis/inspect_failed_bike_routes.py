import gzip
import re
import xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path

import geopandas as gpd
from shapely.geometry import LineString, Point


# ------------------------------------------------------------
# Paths
# ------------------------------------------------------------

NETWORK_FILE = Path("cut_scenario/mapped_network.xml.gz")
ERROR_FILE = Path("/home/20201733/eqasim-switzerland-Fork/slurm/locarno_prepare_cut_156175.err")
CUT_SHAPE = Path("shapes/Locarno_Agglomeration_200m.shp")

OUTPUT_ROUTES = Path("failed_bike_routes.geojson")
OUTPUT_POINTS = Path("failed_bike_nodes.geojson")
OUTPUT_CSV = Path("failed_bike_routes.csv")


# ------------------------------------------------------------
# 1. Read failed OD pairs from routing log
# ------------------------------------------------------------

pattern = re.compile(
    r"No route found from node (\d+) to node (\d+) for mode bike"
)

with open(ERROR_FILE, "r", encoding="utf-8", errors="ignore") as f:
    text = f.read()

pairs = pattern.findall(text)

counts = Counter(pairs)

print(f"Failed routing attempts: {len(pairs)}")
print(f"Unique OD pairs: {len(counts)}")


# ------------------------------------------------------------
# 2. Collect all required node IDs
# ------------------------------------------------------------

required_nodes = set()

for origin, destination in counts:
    required_nodes.add(origin)
    required_nodes.add(destination)

print(f"Unique nodes involved: {len(required_nodes)}")


# ------------------------------------------------------------
# 3. Read only those nodes from MATSim network
# ------------------------------------------------------------

node_coordinates = {}

with gzip.open(NETWORK_FILE, "rb") as f:
    for event, elem in ET.iterparse(f, events=("end",)):

        if elem.tag.endswith("node"):
            node_id = elem.attrib.get("id")

            if node_id in required_nodes:
                node_coordinates[node_id] = (
                    float(elem.attrib["x"]),
                    float(elem.attrib["y"]),
                )

        elem.clear()


print(
    f"Found {len(node_coordinates)} / "
    f"{len(required_nodes)} required nodes in network"
)

missing = required_nodes - node_coordinates.keys()

if missing:
    print("\nMissing node IDs:")
    for node_id in sorted(missing):
        print(" ", node_id)


# ------------------------------------------------------------
# 4. Read Locarno cut boundary
# ------------------------------------------------------------

boundary = gpd.read_file(CUT_SHAPE).to_crs("EPSG:2056")
cut_geometry = boundary.geometry.unary_union


# ------------------------------------------------------------
# 5. Create failed-route lines
# ------------------------------------------------------------

route_rows = []

for (origin, destination), count in counts.items():

    if origin not in node_coordinates:
        continue

    if destination not in node_coordinates:
        continue

    ox, oy = node_coordinates[origin]
    dx, dy = node_coordinates[destination]

    origin_point = Point(ox, oy)
    destination_point = Point(dx, dy)

    route_rows.append(
        {
            "origin": origin,
            "destination": destination,
            "failures": count,

            "origin_x": ox,
            "origin_y": oy,

            "destination_x": dx,
            "destination_y": dy,

            "origin_inside_cut": cut_geometry.covers(origin_point),
            "destination_inside_cut": cut_geometry.covers(destination_point),

            "geometry": LineString(
                [
                    (ox, oy),
                    (dx, dy),
                ]
            ),
        }
    )


routes = gpd.GeoDataFrame(
    route_rows,
    geometry="geometry",
    crs="EPSG:2056",
)

routes["both_inside_cut"] = (
    routes["origin_inside_cut"]
    & routes["destination_inside_cut"]
)

routes.to_file(
    OUTPUT_ROUTES,
    driver="GeoJSON",
)

routes.drop(columns="geometry").to_csv(
    OUTPUT_CSV,
    index=False,
)


# ------------------------------------------------------------
# 6. Create node layer
# ------------------------------------------------------------

point_rows = []

for node_id, (x, y) in node_coordinates.items():

    point = Point(x, y)

    point_rows.append(
        {
            "node_id": node_id,
            "inside_cut": cut_geometry.covers(point),
            "geometry": point,
        }
    )


points = gpd.GeoDataFrame(
    point_rows,
    geometry="geometry",
    crs="EPSG:2056",
)

points.to_file(
    OUTPUT_POINTS,
    driver="GeoJSON",
)


# ------------------------------------------------------------
# 7. Summary
# ------------------------------------------------------------

print("\n----------------------------------------")
print("Routing failure summary")
print("----------------------------------------")

print(
    "Unique routes with both ends inside cut:",
    int(routes["both_inside_cut"].sum()),
)

print(
    "Unique routes with at least one end outside:",
    int((~routes["both_inside_cut"]).sum()),
)

print("\nMost frequent failures:")

print(
    routes.sort_values(
        "failures",
        ascending=False,
    )[
        [
            "origin",
            "destination",
            "failures",
            "origin_inside_cut",
            "destination_inside_cut",
        ]
    ].head(20).to_string(index=False)
)

print("\nCreated:")
print(" ", OUTPUT_ROUTES)
print(" ", OUTPUT_POINTS)
print(" ", OUTPUT_CSV)