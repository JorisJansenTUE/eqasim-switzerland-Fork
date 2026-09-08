import argparse
import logging
from pathlib import Path
from typing import Mapping

import osmium


# ---------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------

BIKE_ACCESS_VALUES = {
    "yes",
    "designated",
}

BIKE_SUITED_HIGHWAY_VALUE = "bike_suited"
ORIGINAL_HIGHWAY_TAG = "original_highway"


# ---------------------------------------------------------------------
# Bike suitability rules
# ---------------------------------------------------------------------

def contains_golf_tag(tags: Mapping[str, str]) -> bool:
    """Return whether any tag key or value contains 'golf'."""
    return any(
        "golf" in key.lower() or "golf" in value.lower()
        for key, value in tags.items()
    )


def is_bike_suited_track(tags: Mapping[str, str]) -> bool:
    """
    Select highway=track ways when either:

    - tracktype=grade1; or
    - bicycle=yes/designated.

    Ways containing a golf-related key or value are excluded.
    """
    if tags.get("highway") != "track":
        return False

    if contains_golf_tag(tags):
        return False

    return (
        tags.get("tracktype") == "grade1"
        or tags.get("bicycle") in BIKE_ACCESS_VALUES
    )


def is_bike_suited_path(tags: Mapping[str, str]) -> bool:
    """
    Select highway=path ways explicitly designated for bicycles.

    Golf-related paths are excluded as well.
    """
    return (
        tags.get("highway") == "path"
        and tags.get("bicycle") == "designated"
        and not contains_golf_tag(tags)
    )


def is_bike_suited_way(tags: Mapping[str, str]) -> bool:
    """Return whether an OSM way should be reclassified."""
    return (
        is_bike_suited_track(tags)
        or is_bike_suited_path(tags)
    )


# ---------------------------------------------------------------------
# OSM writer
# ---------------------------------------------------------------------

class BikeSuitableWayWriter(osmium.SimpleHandler):
    """Copy an OSM dataset while reclassifying suitable bike ways."""

    def __init__(self, output_path: Path) -> None:
        super().__init__()

        self.writer = osmium.SimpleWriter(str(output_path))

        self.changed_tracks = 0
        self.changed_paths = 0
        self.changed_way_ids: list[int] = []

    def node(self, node: osmium.osm.Node) -> None:
        self.writer.add_node(node)

    def way(self, way: osmium.osm.Way) -> None:
        tags = dict(way.tags)

        if not is_bike_suited_way(tags):
            self.writer.add_way(way)
            return

        original_highway = tags["highway"]

        # Keep track of the original classification.
        tags[ORIGINAL_HIGHWAY_TAG] = original_highway

        # PT2MATSim can now treat this as its own highway type.
        tags["highway"] = BIKE_SUITED_HIGHWAY_VALUE

        modified_way = way.replace(tags=tags)

        self.writer.add_way(modified_way)

        self.changed_way_ids.append(way.id)

        if original_highway == "track":
            self.changed_tracks += 1

        elif original_highway == "path":
            self.changed_paths += 1

    def relation(self, relation: osmium.osm.Relation) -> None:
        self.writer.add_relation(relation)

    def close(self) -> None:
        self.writer.close()


# ---------------------------------------------------------------------
# Processing
# ---------------------------------------------------------------------

def classify_bike_suitable_ways(
    input_path: Path,
    output_path: Path,
) -> None:
    """
    Reclassify selected tracks and paths as highway=bike_suited.
    """

    if not input_path.exists():
        raise FileNotFoundError(
            f"Input OSM file does not exist: {input_path}"
        )

    if input_path.resolve() == output_path.resolve():
        raise ValueError(
            "Input and output OSM paths must be different."
        )

    output_path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    # SimpleWriter refuses to overwrite.
    if output_path.exists():
        logging.info(
            "Removing existing output file: %s",
            output_path,
        )
        output_path.unlink()

    handler = BikeSuitableWayWriter(output_path)

    logging.info(
        "Processing OSM file: %s",
        input_path,
    )

    try:
        handler.apply_file(
            str(input_path),
            locations=False,
        )

    finally:
        handler.close()

    total_changed = (
        handler.changed_tracks
        + handler.changed_paths
    )

    logging.info(
        "Bike-suitable OSM reclassification completed."
    )

    logging.info(
        "Tracks changed: %s",
        f"{handler.changed_tracks:,}",
    )

    logging.info(
        "Paths changed:  %s",
        f"{handler.changed_paths:,}",
    )

    logging.info(
        "Total changed:  %s",
        f"{total_changed:,}",
    )

    logging.info(
        "Output: %s",
        output_path,
    )

    if handler.changed_way_ids:
        logging.info(
            "Example changed way IDs: %s",
            handler.changed_way_ids[:20],
        )


# ---------------------------------------------------------------------
# Command line interface
# ---------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Reclassify bicycle-suitable OSM tracks and paths "
            "as highway=bike_suited."
        )
    )

    parser.add_argument(
        "input",
        type=Path,
        help="Input OSM file (.osm, .osm.gz, or .osm.pbf)",
    )

    parser.add_argument(
        "output",
        type=Path,
        help="Output OSM file (.osm, .osm.gz, or .osm.pbf)",
    )

    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s | %(levelname)s | %(message)s",
    )

    classify_bike_suitable_ways(
        args.input,
        args.output,
    )


if __name__ == "__main__":
    main()