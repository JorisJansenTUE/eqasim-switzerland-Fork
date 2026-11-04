#!/bin/bash
#SBATCH --job-name=feasibility_tests
#SBATCH --partition=mech-cst-mov.cpu.q
#SBATCH --cpus-per-task=1
#SBATCH --mem=32G
#SBATCH --time=02:00:00
#SBATCH --output=feasibility_tests_%j.out
#SBATCH --error=feasibility_tests_%j.err

set -euo pipefail

module purge
module load Umbrella/2024
module load Java/21.0.7

# ------------------------------------------------------------
# Paths
# ------------------------------------------------------------

BASE="$HOME/locarno_ETH_Model/REV_cut"

JAR="$HOME/eqasim-java-Fork/switzerland/target/switzerland-2.0.0.jar"

# CHANGE THIS to the exact network you want to test.
NETWORK="$BASE/locarno_network.xml.gz"

# Your mapped population
POPULATION="$BASE/locarno_population.xml.gz"

# If you have a facilities.xml.gz, put it here.
# Otherwise "-" tells the Java utility not to load a facilities file.
FACILITIES="-"

OUTPUT="$BASE/feasibility_tests"

mkdir -p "$OUTPUT"

# ------------------------------------------------------------
# Sanity checks
# ------------------------------------------------------------

echo "============================================================"
echo "Feasibility test"
echo "============================================================"
echo "JAR:        $JAR"
echo "Network:    $NETWORK"
echo "Population: $POPULATION"
echo "Facilities: $FACILITIES"
echo "Output:     $OUTPUT"
echo

test -f "$JAR" || {
    echo "ERROR: JAR does not exist: $JAR"
    exit 1
}

test -f "$NETWORK" || {
    echo "ERROR: Network does not exist: $NETWORK"
    exit 1
}

test -f "$POPULATION" || {
    echo "ERROR: Population does not exist: $POPULATION"
    exit 1
}

if [ "$FACILITIES" != "-" ]; then
    test -f "$FACILITIES" || {
        echo "ERROR: Facilities file does not exist: $FACILITIES"
        exit 1
    }
fi

# Make sure the new class is actually in the JAR
if ! jar tf "$JAR" | grep -q \
    '^org/thesis/GenerateFeasibilityTestNetworks.class$'; then

    echo "ERROR: GenerateFeasibilityTestNetworks is not inside the JAR."
    exit 1
fi

# ------------------------------------------------------------
# Run
# ------------------------------------------------------------

echo "Starting Java utility..."
echo

java \
    -Xms4G \
    -Xmx24G \
    -cp "$JAR" \
    org.thesis.GenerateFeasibilityTestNetworks \
    "$NETWORK" \
    "$POPULATION" \
    "$FACILITIES" \
    "$OUTPUT"

echo
echo "============================================================"
echo "Finished"
echo "============================================================"
echo "Results:"
ls -lh "$OUTPUT"