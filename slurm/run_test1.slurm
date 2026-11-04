#!/bin/bash
#SBATCH --job-name=test1_routecheck
#SBATCH --partition=mech-cst-mov.cpu.q
#SBATCH --cpus-per-task=24
#SBATCH --mem=128G
#SBATCH --time=02:00:00
#SBATCH --output=test1_routecheck_%j.out
#SBATCH --error=test1_routecheck_%j.err

set -euo pipefail

module purge
module load Umbrella/2024
module load Java/21.0.7

# ------------------------------------------------------------
# Paths
# ------------------------------------------------------------

BASE="/home/20201733/locarno_ETH_Model"

JAR="$BASE/switzerland_run.jar"

NETWORK="$BASE/REV_cut/feasibility_tests/test4_break_car_connectivity.xml.gz"

INPUT_POP="$BASE/REV_cut/locarno_population.xml.gz"

CLEAN_POP="$BASE/REV_cut/feasibility_tests/locarno_population_test4_routechecked.xml.gz"

BASE_CONFIG="$BASE/REV_cut/config_test1.xml"
RUN_CONFIG="$BASE/REV_cut/config_test4_routechecked.xml"

OUTPUT_DIR="simulation_out_Test3"

cd "$BASE"

echo "============================================================"
echo "TEST 1: CHECK INVALID ROUTES + RUN"
echo "============================================================"

test -f "$JAR" || {
    echo "ERROR: JAR not found: $JAR"
    exit 1
}

test -f "$NETWORK" || {
    echo "ERROR: Network not found: $NETWORK"
    exit 1
}

test -f "$INPUT_POP" || {
    echo "ERROR: Population not found: $INPUT_POP"
    exit 1
}

test -f "$BASE_CONFIG" || {
    echo "ERROR: Config not found: $BASE_CONFIG"
    exit 1
}

# ------------------------------------------------------------
# 1. Reset ONLY routes inconsistent with the modified network
# ------------------------------------------------------------

echo
echo "============================================================"
echo "STEP 1: Checking route-mode consistency"
echo "============================================================"

rm -f "$CLEAN_POP"

jshell --class-path "$JAR" <<EOF

import org.matsim.api.core.v01.Scenario;
import org.matsim.core.config.ConfigUtils;
import org.matsim.core.scenario.ScenarioUtils;
import org.matsim.core.network.io.MatsimNetworkReader;
import org.matsim.core.population.io.PopulationReader;
import org.matsim.core.population.io.PopulationWriter;
import org.matsim.core.population.PopulationUtils;

var scenario = ScenarioUtils.createScenario(ConfigUtils.createConfig());

new MatsimNetworkReader(
    scenario.getNetwork()
).readFile("$NETWORK");

new PopulationReader(
    scenario
).readFile("$INPUT_POP");

System.out.println(
    "Persons loaded: "
    + scenario.getPopulation().getPersons().size()
);

PopulationUtils.checkRouteModeAndReset(
    scenario.getPopulation(),
    scenario.getNetwork()
);

new PopulationWriter(
    scenario.getPopulation(),
    scenario.getNetwork()
).write("$CLEAN_POP");

System.out.println("Written cleaned population to:");
System.out.println("$CLEAN_POP");

/exit
EOF

test -f "$CLEAN_POP" || {
    echo "ERROR: Cleaned population was not created."
    exit 1
}

echo
echo "Created population:"
ls -lh "$CLEAN_POP"

# ------------------------------------------------------------
# 2. Prepare config
# ------------------------------------------------------------

echo
echo "============================================================"
echo "STEP 2: Preparing config"
echo "============================================================"

cp "$BASE_CONFIG" "$RUN_CONFIG"

sed -i -E \
    '/name="inputNetworkFile"/ s|value="[^"]*"|value="feasibility_tests/test4_break_car_connectivity.xml.gz"|' \
    "$RUN_CONFIG"

sed -i -E \
    '/name="inputPlansFile"/ s|value="[^"]*"|value="feasibility_tests/locarno_population_test4_routechecked.xml.gz"|' \
    "$RUN_CONFIG"

sed -i -E \
    '/name="outputDirectory"/ s|value="[^"]*"|value="simulation_out_Test4"|' \
    "$RUN_CONFIG"

echo "Population:"
grep 'name="inputPlansFile"' "$RUN_CONFIG"

echo "Network:"
grep 'name="inputNetworkFile"' "$RUN_CONFIG"

echo "Output:"
grep 'name="outputDirectory"' "$RUN_CONFIG"

# ------------------------------------------------------------
# 3. Run eqasim / MATSim
# ------------------------------------------------------------

echo
echo "============================================================"
echo "STEP 3: Running simulation"
echo "============================================================"

java \
    -Xms16G \
    -Xmx110G \
    -cp "$JAR" \
    org.eqasim.switzerland.ch_cmdp.RunSimulation \
    --config-path REV_cut/config_test4_routechecked.xml

echo
echo "============================================================"
echo "TEST 1 FINISHED"
echo "============================================================"

ls -lh "$BASE/$OUTPUT_DIR" | head