#!/bin/bash
#SBATCH --job-name=cutter
#SBATCH --partition=mech-cst-mov.cpu.q
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=24
#SBATCH --mem=192G
#SBATCH --time=5:00:00
#SBATCH --output=locarno_prepare_cut_%j.out
#SBATCH --error=locarno_prepare_cut_%j.err

set -euo pipefail

module purge
module load Umbrella/2024
module load Java/21.0.7

cd /home/20201733/locarno_ETH_Model

# ------------------------------------------------------------
# Paths
# ------------------------------------------------------------

JAR="switzerland_run.jar"

NEW_NETWORK="locarno_new_cut/mapped_network_bike_fixed.xml.gz"

ORIGINAL_POPULATION="old_locarno_cut/locarno_population.xml.gz"
ORIGINAL_FACILITIES="old_locarno_cut/locarno_facilities.xml.gz"

RELINK_DIR="relinked"
CUT_DIR="baseline"

UNROUTED_POPULATION="${RELINK_DIR}/locarno_population_unrouted.xml.gz"

BASE_CUTTER_CONFIG="cut_config.xml"
RELINKED_CUTTER_CONFIG="locarno_cutter_relinked_config.xml"

CUT_SHAPE="shapes/Locarno_Agglomeration_200m.shp"

rm -rf "${RELINK_DIR}"
mkdir -p "${RELINK_DIR}"

echo "============================================================"
echo "Java"
echo "============================================================"
which java
java -version


# ============================================================
# STEP 1: Remove existing routed trip structure
# ============================================================

echo
echo "============================================================"
echo "STEP 1: Unrouting existing ETH population"
echo "============================================================"

java -Xmx32G \
  -cp "${JAR}:." \
  UnroutePopulation \
  "${ORIGINAL_POPULATION}" \
  "${UNROUTED_POPULATION}"

echo
echo "Unrouting completed."


# ============================================================
# STEP 2: Relink facilities + population to the NEW network
# ============================================================

echo
echo "============================================================"
echo "STEP 2: Relinking population and facilities"
echo "============================================================"

java -Xmx160G \
  -cp "${JAR}" \
  org.eqasim.core.scenario.preparation.RunPreparation \
  --input-facilities-path "${ORIGINAL_FACILITIES}" \
  --output-facilities-path "${RELINK_DIR}/locarno_facilities.xml.gz" \
  --input-population-path "${UNROUTED_POPULATION}" \
  --output-population-path "${RELINK_DIR}/locarno_population.xml.gz" \
  --input-network-path "${NEW_NETWORK}" \
  --output-network-path "${RELINK_DIR}/full_network.xml.gz" \
  --threads 24

echo
echo "Relinking completed."


# ============================================================
# STEP 3: Create cutter config using the relinked files
# ============================================================

echo
echo "============================================================"
echo "STEP 3: Creating cutter config"
echo "============================================================"

cp "${BASE_CUTTER_CONFIG}" "${RELINKED_CUTTER_CONFIG}"

sed -i \
  's|value="locarno_new_cut/mapped_network_bike_fixed.xml.gz"|value="relinked/full_network.xml.gz"|' \
  "${RELINKED_CUTTER_CONFIG}"

sed -i \
  's|value="old_locarno_cut/locarno_population.xml.gz"|value="relinked/locarno_population.xml.gz"|' \
  "${RELINKED_CUTTER_CONFIG}"

sed -i \
  's|value="old_locarno_cut/locarno_facilities.xml.gz"|value="relinked/locarno_facilities.xml.gz"|' \
  "${RELINKED_CUTTER_CONFIG}"
  
  
if grep -q 'name="networkRouteConsistencyCheck"' "${RELINKED_CUTTER_CONFIG}"; then
    sed -i \
      's|<param name="networkRouteConsistencyCheck" value="[^"]*" */>|<param name="networkRouteConsistencyCheck" value="disable" />|' \
      "${RELINKED_CUTTER_CONFIG}"
else
    sed -i \
      '/<module name="routing"/a\    <param name="networkRouteConsistencyCheck" value="disable" />' \
      "${RELINKED_CUTTER_CONFIG}"
fi

echo "Cutter config created:"
echo "${RELINKED_CUTTER_CONFIG}"
grep 'networkRouteConsistencyCheck' "${RELINKED_CUTTER_CONFIG}"

echo "============================================================"
echo "STEP 3.5: Rerouting population for cutter"
echo "============================================================"


java -Xmx160G \
  -cp "${JAR}" \
  org.eqasim.core.scenario.routing.RunPopulationRouting \
  --config-path "${RELINKED_CUTTER_CONFIG}" \
  --output-path "${RELINK_DIR}/locarno_population_routed.xml.gz" \
  --threads 24 \
  --eqasim-configurator org.eqasim.switzerland.ch_cmdp.SwitzerlandConfigurator

sed -i \
  's|value="relinked/locarno_population.xml.gz"|value="relinked/locarno_population_routed.xml.gz"|' \
  "${RELINKED_CUTTER_CONFIG}"

# ============================================================
# STEP 4: Cut the prepared scenario to Locarno
# ============================================================

echo
echo "============================================================"
echo "STEP 4: Cutting scenario"
echo "============================================================"

rm -rf "${CUT_DIR}"
mkdir -p "${CUT_DIR}"

java -Xmx160G \
  -cp "${JAR}" \
  org.eqasim.core.scenario.cutter.RunScenarioCutter \
  --config-path "${RELINKED_CUTTER_CONFIG}" \
  --output-path "${CUT_DIR}" \
  --extent-path "${CUT_SHAPE}" \
  --prefix locarno_ \
  --threads 24 \
  --skip-routing true \
  --eqasim-configurator org.eqasim.switzerland.ch_cmdp.SwitzerlandConfigurator

echo
echo "============================================================"
echo "Unrouting + relinking + cutting completed successfully."
echo "Output:"
echo "${CUT_DIR}"
echo "============================================================"