from pathlib import Path

import gzip
import xml.etree.ElementTree as ET

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
import geopandas as gpd

from shapely.geometry import LineString
from shapely.prepared import prep

from matplotlib.collections import LineCollection
from matplotlib.colors import Normalize
from matplotlib.cm import ScalarMappable
from matplotlib.widgets import Slider
from matplotlib.animation import FuncAnimation, PillowWriter


# ------------------------------------------------------------------
# Settings
# ------------------------------------------------------------------

SCENARIO = Path(
    "/home/20201733/locarno_ETH_Model/simulation_output_long"
)

NETWORK_FILE = SCENARIO / "output_network.xml.gz"
FLOW_FILE = SCENARIO / "output_traffic_flow.csv"

ANALYSIS_BOUNDARY = None

# Use this instead to plot the full network:
# ANALYSIS_BOUNDARY = None


# ------------------------------------------------------------------
# Output settings
# ------------------------------------------------------------------

# Options:
#   "interactive" -> interactive Matplotlib plot with hour slider
#   "gif"         -> save hourly animation as GIF
OUTPUT_MODE = "gif"

# GIF output location
GIF_FILE = SCENARIO / "traffic_flow_animation.gif"

# Duration between frames when constructing animation [milliseconds]
FRAME_INTERVAL = 500

# Frames per second in saved GIF
GIF_FPS = 1

# GIF resolution
GIF_DPI = 120


# ------------------------------------------------------------------
# Visualization settings
# ------------------------------------------------------------------

# Thickness of links
MIN_LINEWIDTH = 0.25
MAX_LINEWIDTH = 5.0

# Colormap
CMAP = "turbo"

# None -> use maximum flow across all 24 hours.
# You can manually set e.g. 500 if desired.
FLOW_MAX = None


# ------------------------------------------------------------------
# Read analysis boundary
# ------------------------------------------------------------------

def read_analysis_boundary(boundary_file):
    """Read and prepare the analysis boundary."""

    if boundary_file is None:
        print("No analysis boundary specified. Using full network.")
        return None

    print("Reading analysis boundary...")

    boundary = gpd.read_file(boundary_file)

    if boundary.empty:
        raise ValueError(
            f"Analysis boundary contains no features: {boundary_file}"
        )

    print(f"  Original CRS: {boundary.crs}")

    if boundary.crs is None:
        raise ValueError("Analysis boundary has no CRS defined.")

    # Combine all features into one geometry
    geometry = boundary.geometry.union_all()

    print(f"  Boundary features: {len(boundary):,}")

    return prep(geometry)


# ------------------------------------------------------------------
# Read MATSim network
# ------------------------------------------------------------------

def read_network(network_file):
    """
    Read nodes and links from a MATSim network.

    Returns
    -------
    nodes : dict
        node_id -> (x, y)

    links : dict
        link_id -> (from_node, to_node)
    """

    print("Reading MATSim network...")

    nodes = {}
    links = {}

    with gzip.open(network_file, "rb") as f:
        for _, elem in ET.iterparse(f, events=("end",)):

            tag = elem.tag.split("}")[-1]

            if tag == "node":
                nodes[elem.attrib["id"]] = (
                    float(elem.attrib["x"]),
                    float(elem.attrib["y"]),
                )

            elif tag == "link":
                links[elem.attrib["id"]] = (
                    elem.attrib["from"],
                    elem.attrib["to"],
                )

            elem.clear()

    print(f"  Nodes: {len(nodes):,}")
    print(f"  Links: {len(links):,}")

    return nodes, links


# ------------------------------------------------------------------
# Read traffic flow
# ------------------------------------------------------------------

def read_flows(flow_file):
    """
    Read MATSim output_traffic_flow.csv.

    The file has:
        linkId;bin0;bin1;...;bin23

    with decimal commas.
    """

    print("Reading traffic flows...")

    df = pd.read_csv(
        flow_file,
        sep=";",
        decimal=",",
        dtype={"linkId": str},
    )

    hour_columns = [
        f"bin{i}"
        for i in range(24)
        if f"bin{i}" in df.columns
    ]

    print(f"  Links with flow data: {len(df):,}")
    print(f"  Hour bins: {len(hour_columns)}")

    return df, hour_columns


# ------------------------------------------------------------------
# Prepare network geometry and flow matrix
# ------------------------------------------------------------------

def prepare_data(
    nodes,
    links,
    flows,
    hour_columns,
    analysis_geometry,
):
    """
    Match flow data to links and optionally restrict them
    to the analysis area.
    """

    flow_lookup = flows.set_index("linkId")

    segments = []
    flow_values = []
    matched_link_ids = []

    missing_flow = 0
    outside_boundary = 0

    for link_id, (from_node, to_node) in links.items():

        if from_node not in nodes or to_node not in nodes:
            continue

        x1, y1 = nodes[from_node]
        x2, y2 = nodes[to_node]

        segment = [(x1, y1), (x2, y2)]

        if analysis_geometry is not None:

            line = LineString(segment)

            if not analysis_geometry.intersects(line):
                outside_boundary += 1
                continue

        segments.append(segment)
        matched_link_ids.append(link_id)

        if link_id in flow_lookup.index:
            values = flow_lookup.loc[
                link_id,
                hour_columns
            ].to_numpy(dtype=float)

        else:
            values = np.zeros(len(hour_columns))
            missing_flow += 1

        flow_values.append(values)

    flow_values = np.asarray(flow_values)

    print(f"  Network segments used: {len(segments):,}")

    if analysis_geometry is not None:
        print(f"  Links outside boundary: {outside_boundary:,}")

    print(f"  Links without flow data: {missing_flow:,}")

    if len(segments) == 0:
        raise ValueError(
            "No MATSim links found in the selected analysis area."
        )

    return segments, flow_values, matched_link_ids


# ------------------------------------------------------------------
# Convert flows to line widths
# ------------------------------------------------------------------

def calculate_linewidths(values, flow_max):
    """
    Scale line thickness using sqrt(flow).

    Square-root scaling makes low/moderate flows visible without
    letting the busiest links become excessively thick.
    """

    values = np.clip(values, 0, flow_max)

    scaled = np.sqrt(values / flow_max)

    return MIN_LINEWIDTH + scaled * (
        MAX_LINEWIDTH - MIN_LINEWIDTH
    )


# ------------------------------------------------------------------
# Shared plotting setup
# ------------------------------------------------------------------

def create_base_plot(segments, flow_values, hour_columns):
    """
    Create the common figure used by both interactive and GIF modes.
    """

    if FLOW_MAX is None:
        flow_max = np.nanmax(flow_values)
    else:
        flow_max = FLOW_MAX

    if not np.isfinite(flow_max) or flow_max <= 0:
        raise ValueError(
            f"Invalid maximum flow: {flow_max}. "
            "Check the traffic-flow input file."
        )

    print(f"Maximum displayed flow: {flow_max:.1f} veh/h")

    norm = Normalize(
        vmin=0,
        vmax=flow_max,
        clip=True,
    )

    cmap = plt.get_cmap(CMAP)

    initial_hour = 7

    if initial_hour >= len(hour_columns):
        initial_hour = 0

    initial_flows = flow_values[:, initial_hour]

    fig, ax = plt.subplots(
        figsize=(12, 10)
    )

    collection = LineCollection(
        segments,
        cmap=cmap,
        norm=norm,
        linewidths=calculate_linewidths(
            initial_flows,
            flow_max,
        ),
    )

    collection.set_array(initial_flows)

    ax.add_collection(collection)

    # Fit view to network
    ax.autoscale()

    ax.set_aspect(
        "equal",
        adjustable="box",
    )

    ax.axis("off")

    title = ax.set_title(
        f"MATSim traffic flow — "
        f"{initial_hour:02d}:00–{initial_hour + 1:02d}:00",
        fontsize=15,
    )

    # Colorbar
    sm = ScalarMappable(
        norm=norm,
        cmap=cmap,
    )

    sm.set_array([])

    cbar = fig.colorbar(
        sm,
        ax=ax,
        fraction=0.035,
        pad=0.02,
    )

    cbar.set_label(
        "Traffic flow [vehicles/hour]"
    )

    return (
        fig,
        ax,
        collection,
        title,
        flow_max,
        initial_hour,
    )


# ------------------------------------------------------------------
# Interactive plot
# ------------------------------------------------------------------

def plot_interactive(
    segments,
    flow_values,
    hour_columns,
):
    """
    Show an interactive plot with a slider for selecting the hour.

    Intended mainly for local use.
    """

    print("\nOutput mode: INTERACTIVE")

    (
        fig,
        ax,
        collection,
        title,
        flow_max,
        initial_hour,
    ) = create_base_plot(
        segments,
        flow_values,
        hour_columns,
    )

    # Leave room underneath for slider
    plt.subplots_adjust(
        bottom=0.13,
        right=0.90,
    )

    # --------------------------------------------------------------
    # Slider
    # --------------------------------------------------------------

    slider_ax = fig.add_axes(
        [0.15, 0.045, 0.65, 0.03]
    )

    hour_slider = Slider(
        ax=slider_ax,
        label="Hour",
        valmin=0,
        valmax=len(hour_columns) - 1,
        valinit=initial_hour,
        valstep=1,
    )

    # --------------------------------------------------------------
    # Update function
    # --------------------------------------------------------------

    def update(value):

        hour = int(hour_slider.val)

        current_flows = flow_values[:, hour]

        # Update colours
        collection.set_array(current_flows)

        # Update thickness
        collection.set_linewidths(
            calculate_linewidths(
                current_flows,
                flow_max,
            )
        )

        # Update title
        title.set_text(
            f"MATSim traffic flow — "
            f"{hour:02d}:00–{hour + 1:02d}:00"
        )

        fig.canvas.draw_idle()

    hour_slider.on_changed(update)

    # --------------------------------------------------------------
    # Keyboard controls
    # --------------------------------------------------------------

    def key_press(event):

        current = int(hour_slider.val)

        if event.key == "right":

            hour_slider.set_val(
                min(
                    current + 1,
                    len(hour_columns) - 1,
                )
            )

        elif event.key == "left":

            hour_slider.set_val(
                max(
                    current - 1,
                    0,
                )
            )

    fig.canvas.mpl_connect(
        "key_press_event",
        key_press,
    )

    print("Opening interactive plot...")
    print("Use the slider or left/right arrow keys.")

    plt.show()


# ------------------------------------------------------------------
# GIF
# ------------------------------------------------------------------

def create_flow_gif(
    segments,
    flow_values,
    hour_columns,
):
    """
    Create and save an animated GIF containing one frame per hour.

    Intended mainly for HPC/headless use.
    """

    print("\nOutput mode: GIF")

    (
        fig,
        ax,
        collection,
        title,
        flow_max,
        initial_hour,
    ) = create_base_plot(
        segments,
        flow_values,
        hour_columns,
    )

    plt.subplots_adjust(
        right=0.90
    )

    # --------------------------------------------------------------
    # Animation update function
    # --------------------------------------------------------------

    def update(hour):

        current_flows = flow_values[:, hour]

        # Update colours
        collection.set_array(current_flows)

        # Update thickness
        collection.set_linewidths(
            calculate_linewidths(
                current_flows,
                flow_max,
            )
        )

        # Update title
        title.set_text(
            f"MATSim traffic flow — "
            f"{hour:02d}:00–{hour + 1:02d}:00"
        )

        return collection, title

    # --------------------------------------------------------------
    # Create animation
    # --------------------------------------------------------------

    animation = FuncAnimation(
        fig,
        update,
        frames=range(len(hour_columns)),
        interval=FRAME_INTERVAL,
        blit=False,
        repeat=True,
    )

    # Make sure output directory exists
    GIF_FILE.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    print(
        f"Creating GIF with "
        f"{len(hour_columns)} hourly frames..."
    )

    print(f"Output: {GIF_FILE}")

    writer = PillowWriter(
        fps=GIF_FPS
    )

    animation.save(
        GIF_FILE,
        writer=writer,
        dpi=GIF_DPI,
    )

    plt.close(fig)

    print("GIF created successfully.")


# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------

def main():

    print("=" * 60)
    print("MATSim hourly traffic-flow visualization")
    print("=" * 60)

    print(f"Scenario:    {SCENARIO}")
    print(f"Output mode: {OUTPUT_MODE}")

    # --------------------------------------------------------------
    # Validate output mode
    # --------------------------------------------------------------

    valid_modes = {
        "interactive",
        "gif",
    }

    if OUTPUT_MODE not in valid_modes:
        raise ValueError(
            f"Unknown OUTPUT_MODE '{OUTPUT_MODE}'. "
            f"Choose from: {sorted(valid_modes)}"
        )

    # --------------------------------------------------------------
    # Read input data
    # --------------------------------------------------------------

    analysis_geometry = read_analysis_boundary(
        ANALYSIS_BOUNDARY
    )

    nodes, links = read_network(
        NETWORK_FILE
    )

    flows, hour_columns = read_flows(
        FLOW_FILE
    )

    # --------------------------------------------------------------
    # Prepare plotting data
    # --------------------------------------------------------------

    segments, flow_values, link_ids = prepare_data(
        nodes,
        links,
        flows,
        hour_columns,
        analysis_geometry,
    )

    # --------------------------------------------------------------
    # Output
    # --------------------------------------------------------------

    if OUTPUT_MODE == "interactive":

        plot_interactive(
            segments,
            flow_values,
            hour_columns,
        )

    elif OUTPUT_MODE == "gif":

        create_flow_gif(
            segments,
            flow_values,
            hour_columns,
        )


# ------------------------------------------------------------------
# Run
# ------------------------------------------------------------------

if __name__ == "__main__":
    main()