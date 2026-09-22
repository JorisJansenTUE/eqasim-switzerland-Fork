#!/bin/bash
#SBATCH --job-name=clean_bike
#SBATCH --partition=mech-cst-mov.cpu.q
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=24
#SBATCH --mem=96G
#SBATCH --time=2:00:00
#SBATCH --output=clean_bike_%j.out
#SBATCH --error=clean_bike_%j.err

set -euo pipefail

module purge
module load Umbrella/2024
module load Java/21.0.7

cd /home/20201733/locarno_ETH_Model

# ============================================================
# Paths
# ============================================================

JAR="switzerland_run.jar"

# Original cutter outputs
INPUT_NETWORK="baseline/locarno_network.xml.gz"
INPUT_POPULATION="baseline/locarno_population.xml.gz"
INPUT_FACILITIES="baseline/locarno_facilities.xml.gz"

# Cleaned intermediate network
CLEANED_NETWORK="baseline/locarno_network_cleaned.xml.gz"

# Population after routes/stage activities are removed
UNROUTED_POPULATION="baseline/locarno_population_unrouted.xml.gz"

# Final prepared files
FINAL_DIR="baseline/final"

FINAL_NETWORK="${FINAL_DIR}/locarno_network.xml.gz"
FINAL_FACILITIES="${FINAL_DIR}/locarno_facilities.xml.gz"
FINAL_POPULATION="${FINAL_DIR}/locarno_population.xml.gz"
FINAL_ROUTED_POPULATION="${FINAL_DIR}/locarno_population_routed.xml.gz"

# Configs
BASE_CONFIG="baseline/locarno_config.xml"
ROUTING_CONFIG="baseline/locarno_final_routing_config.xml"
RUN_CONFIG="baseline/locarno_run_config.xml"


mkdir -p "${FINAL_DIR}"


# ============================================================
# STEP 1: Compile helper classes
# ============================================================

echo
echo "============================================================"
echo "STEP 1: Compiling helper classes"
echo "============================================================"

javac -cp "${JAR}" CleanBikeNetwork.java
javac -cp "${JAR}" UnroutePopulation.java


# ============================================================
# STEP 2: Clean bicycle network
# ============================================================

echo
echo "============================================================"
echo "STEP 2: Cleaning bicycle network"
echo "============================================================"

java -Xmx32G \
  -cp "${JAR}:." \
  CleanBikeNetwork \
  "${INPUT_NETWORK}" \
  "${CLEANED_NETWORK}"

echo
echo "Cleaned network:"
echo "  ${CLEANED_NETWORK}"


# ============================================================
# STEP 3: Remove old routes from population
# ============================================================

echo
echo "============================================================"
echo "STEP 3: Unrouting population"
echo "============================================================"

java -Xmx32G \
  -cp "${JAR}:." \
  UnroutePopulation \
  "${INPUT_POPULATION}" \
  "${UNROUTED_POPULATION}"

echo
echo "Unrouted population:"
echo "  ${UNROUTED_POPULATION}"


# ============================================================
# STEP 4: Relink facilities + activities to cleaned network
# ============================================================

echo
echo "============================================================"
echo "STEP 4: Relinking population and facilities"
echo "============================================================"

java -Xmx80G \
  -cp "${JAR}" \
  org.eqasim.core.scenario.preparation.RunPreparation \
  --input-facilities-path "${INPUT_FACILITIES}" \
  --output-facilities-path "${FINAL_FACILITIES}" \
  --input-population-path "${UNROUTED_POPULATION}" \
  --output-population-path "${FINAL_POPULATION}" \
  --input-network-path "${CLEANED_NETWORK}" \
  --output-network-path "${FINAL_NETWORK}" \
  --threads 24

echo
echo "Relinking completed."


# ============================================================
# STEP 5: Create routing config
# ============================================================

echo
echo "============================================================"
echo "STEP 5: Creating final routing config"
echo "============================================================"

cp "${BASE_CONFIG}" "${ROUTING_CONFIG}"

# Config lives inside baseline/, therefore final/... is relative
# to baseline/.

sed -i -E \
  '/name="inputNetworkFile"/ s|value="[^"]*"|value="final/locarno_network.xml.gz"|' \
  "${ROUTING_CONFIG}"

sed -i -E \
  '/name="inputPlansFile"/ s|value="[^"]*"|value="final/locarno_population.xml.gz"|' \
  "${ROUTING_CONFIG}"

sed -i -E \
  '/name="inputFacilitiesFile"/ s|value="[^"]*"|value="final/locarno_facilities.xml.gz"|' \
  "${ROUTING_CONFIG}"


# Restore route consistency checking
if grep -q 'name="networkRouteConsistencyCheck"' "${ROUTING_CONFIG}"; then

    sed -i -E \
      '/name="networkRouteConsistencyCheck"/ s|value="[^"]*"|value="abortOnInconsistency"|' \
      "${ROUTING_CONFIG}"

fi


echo
echo "Routing config inputs:"
grep -E \
  'inputNetworkFile|inputPlansFile|inputFacilitiesFile|networkRouteConsistencyCheck' \
  "${ROUTING_CONFIG}"


# ============================================================
# STEP 6: Reroute final population
# ============================================================

echo
echo "============================================================"
echo "STEP 6: Routing final population"
echo "============================================================"

java -Xmx80G \
  -cp "${JAR}" \
  org.eqasim.core.scenario.routing.RunPopulationRouting \
  --config-path "${ROUTING_CONFIG}" \
  --output-path "${FINAL_ROUTED_POPULATION}" \
  --threads 24 \
  --eqasim-configurator org.eqasim.switzerland.ch_cmdp.SwitzerlandConfigurator

echo
echo "Final routed population:"
echo "  ${FINAL_ROUTED_POPULATION}"


# ============================================================
# STEP 7: Create final simulation config
# ============================================================

echo
echo "============================================================"
echo "STEP 7: Creating final run config"
echo "============================================================"

cp "${BASE_CONFIG}" "${RUN_CONFIG}"

sed -i -E \
  '/name="inputNetworkFile"/ s|value="[^"]*"|value="final/locarno_network.xml.gz"|' \
  "${RUN_CONFIG}"

sed -i -E \
  '/name="inputPlansFile"/ s|value="[^"]*"|value="final/locarno_population_routed.xml.gz"|' \
  "${RUN_CONFIG}"

sed -i -E \
  '/name="inputFacilitiesFile"/ s|value="[^"]*"|value="final/locarno_facilities.xml.gz"|' \
  "${RUN_CONFIG}"

if grep -q 'name="networkRouteConsistencyCheck"' "${RUN_CONFIG}"; then

    sed -i -E \
      '/name="networkRouteConsistencyCheck"/ s|value="[^"]*"|value="abortOnInconsistency"|' \
      "${RUN_CONFIG}"

fi


# ============================================================
# STEP 8: Final checks
# ============================================================

echo
echo "============================================================"
echo "FINAL FILES"
echo "============================================================"

ls -lh \
  "${FINAL_NETWORK}" \
  "${FINAL_FACILITIES}" \
  "${FINAL_ROUTED_POPULATION}" \
  "${RUN_CONFIG}"

echo
echo "Final simulation config inputs:"

grep -E \
  'inputNetworkFile|inputPlansFile|inputFacilitiesFile|networkRouteConsistencyCheck' \
  "${RUN_CONFIG}"

echo
echo "============================================================"
echo "FINAL BASELINE PREPARATION COMPLETED SUCCESSFULLY"
echo "============================================================"