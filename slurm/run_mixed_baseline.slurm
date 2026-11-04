#!/usr/bin/env bash
#SBATCH --job-name=locarno_reprepare
#SBATCH --partition=mech-cst-mov.cpu.q
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=24
#SBATCH --mem=256G
#SBATCH --time=18:00:00
#SBATCH --output=mixed_run_%j.out
#SBATCH --error=mixed_run_%j.err

set -Eeuo pipefail
trap 'status=$?; echo "[$(date "+%F %T")] ERROR at line $LINENO (exit $status)" >&2' ERR

# ======================================================================
# REPREPARE AND SIMULATE THE EXISTING LOCARNO SCENARIO
#   Inputs:
#     06_final_cut/locarno_network.xml.gz
#     04_05_prepared/population_routed.xml.gz
#     04_05_prepared/facilities_prepared.xml.gz
#   Steps (same Java tools and CLI as rebuild_locarno_scenario):
#     1. Copy all final-cut scenario files + ETH auxiliary resources
#     2. Unroute population
#     3. RunPreparation (relink population/facilities to final network)
#     4. RunPopulationRouting
#     5. Replace network/population/facilities in copied scenario
#     6. RunSimulation
#   No rebuilding, synpp, cutting, or custom Python relinking.
# ======================================================================

# ------------------------------- PATHS --------------------------------
JAVA_REPO="/home/20201733/eqasim-java-Fork"
ETH_CONFIG="/home/20201733/lucarno/lucarno_config.xml"
RUN_ROOT="/home/20201733/locarno_ETH_Model/rebuilds"
FINAL_PREFIX="locarno_"

# Original rebuild directory name is the SLURM job ID of the build.
# Submit with: sbatch --export=ALL,REBUILD_ID=123456 reprepare_locarno_scenario.slurm
REBUILD_ID="${REBUILD_ID:?Submit with --export=ALL,REBUILD_ID=<original_rebuild_job_id>}"
SOURCE="$RUN_ROOT/$REBUILD_ID"
SOURCE_FINAL="$SOURCE/06_final_cut"
SOURCE_PREP="$SOURCE/04_05_prepared"

FINAL_NET="$SOURCE_FINAL/${FINAL_PREFIX}network.xml.gz"
SOURCE_POP="$SOURCE_PREP/population_routed.xml.gz"
SOURCE_FAC="$SOURCE_PREP/facilities_prepared.xml.gz"

THREADS="${SLURM_CPUS_PER_TASK:-24}"
HEAP="200G"
JAR="$JAVA_REPO/switzerland/target/switzerland.jar"
UNROUTE_MAIN="org.thesis.UnroutePopulation"

JOB_TAG="${SLURM_JOB_ID:-manual_$(date +%Y%m%d_%H%M%S)}"
RUN_DIR="$SOURCE/reprepared_$JOB_TAG"
STAGE_DIR="$RUN_DIR/04_05_prepared"
SCENARIO_DIR="$RUN_DIR/06_final_scenario"
OUTPUT_DIR="$RUN_DIR/simulation_output"

export eqasim_configurator="org.eqasim.switzerland.ch_cmdp.SwitzerlandConfigurator"

log() { echo "[$(date '+%F %T')] $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }
require_file() { [[ -s "$1" ]] || fail "Missing/empty file: $1"; }

run_java() {
    java -Xmx"$HEAP" -XX:ActiveProcessorCount="$THREADS" -cp "$JAR" "$@"
}

# Exactly the auxiliary resource list from the final rebuild SLURM.
AUX_FILES=(
    calibrated_dmc_parameters.yml
    dmc_parameters.yml
    cost_parameters.yml
    cantonal_target_mode_shares.csv
    global_target_mode_shares.csv
    gtfs_zones.csv
    lucarno_network_geometry.csv
    pricingDescription.xml
    SBB_all_distances.csv
    network_calibration_files
)

setup_aux_files() {
    local target_dir="$1"
    local source_dir
    source_dir="$(dirname "$ETH_CONFIG")"
    local file

    for file in "${AUX_FILES[@]}"; do
        [[ -e "$source_dir/$file" ]] || fail "Missing ETH resource: $source_dir/$file"
        # Keep the copied final-cut version when one already exists.
        if [[ ! -e "$target_dir/$file" && ! -L "$target_dir/$file" ]]; then
            cp -a "$source_dir/$file" "$target_dir/"
        fi
    done
    log "Copied/verified ETH auxiliary resources in $target_dir"
}

# ----------------------------- PREFLIGHT ------------------------------
module purge
module load EESSI/2026.06
module load Java/25.36

JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"

[[ "$(java -XshowSettings:properties -version 2>&1 | awk '/java.specification.version =/ {print $3}')" == 25 ]] \
    || fail "Java 25 was not loaded correctly"

[[ -d "$SOURCE_FINAL" && -d "$SOURCE_PREP" ]] || fail "Original rebuild folders not found: $SOURCE"
require_file "$ETH_CONFIG"
require_file "$JAR"
for f in "$FINAL_NET" "$SOURCE_POP" "$SOURCE_FAC" \
         "$SOURCE_FINAL/${FINAL_PREFIX}config.xml"; do
    require_file "$f"
done

mkdir -p "$STAGE_DIR" "$SCENARIO_DIR"
log "Java: $(java -version 2>&1 | head -1)"
log "JAR: $JAR"
log "Original network: $FINAL_NET"
log "Source population: $SOURCE_POP"
log "Source facilities: $SOURCE_FAC"
log "Work directory: $RUN_DIR"

# ------------------------ 1. COPY SCENARIO FILES ----------------------
# Copy the COMPLETE final-cut folder (config, households, vehicles,
# transit schedule/vehicles, network/population/facilities, etc.).
# The copied configuration stays alongside its relative file references.
log "STEP 1/6: Copy complete final-cut scenario and auxiliary resources"
cp -a "$SOURCE_FINAL/." "$SCENARIO_DIR/"
setup_aux_files "$SCENARIO_DIR"

CONFIG="$SCENARIO_DIR/${FINAL_PREFIX}config.xml"
SCENARIO_NET="$SCENARIO_DIR/${FINAL_PREFIX}network.xml.gz"
SCENARIO_POP="$SCENARIO_DIR/${FINAL_PREFIX}population.xml.gz"
SCENARIO_FAC="$SCENARIO_DIR/${FINAL_PREFIX}facilities.xml.gz"
PT_SCHEDULE="$SCENARIO_DIR/${FINAL_PREFIX}transit_schedule.xml.gz"
PT_VEHICLES="$SCENARIO_DIR/${FINAL_PREFIX}transit_vehicles.xml.gz"
HOUSEHOLDS="$SCENARIO_DIR/${FINAL_PREFIX}households.xml.gz"
VEHICLES="$SCENARIO_DIR/${FINAL_PREFIX}vehicles.xml.gz"

for f in "$CONFIG" "$SCENARIO_NET" "$SCENARIO_POP" "$SCENARIO_FAC" \
         "$PT_SCHEDULE" "$PT_VEHICLES" "$HOUSEHOLDS" "$VEHICLES"; do
    require_file "$f"
done

# ------------------------ 2. UNROUTE POPULATION -----------------------
# Use the exact positional CLI from the uploaded final build script.
UNROUTED_POP="$STAGE_DIR/population_unrouted.xml.gz"
log "STEP 2/6: Remove old routes from the before-second-cut population"
run_java "$UNROUTE_MAIN" "$SOURCE_POP" "$UNROUTED_POP"
require_file "$UNROUTED_POP"

# ------------------------ 3. RELINK (RunPreparation) ------------------
PREP_NET="$STAGE_DIR/network_prepared.xml.gz"
PREP_FAC="$STAGE_DIR/facilities_prepared.xml.gz"
PREP_POP="$STAGE_DIR/population_prepared.xml.gz"

log "STEP 3/6: Relink facilities/population to the final-cut network"
run_java org.eqasim.core.scenario.preparation.RunPreparation \
    --input-network-path "$FINAL_NET" \
    --output-network-path "$PREP_NET" \
    --input-facilities-path "$SOURCE_FAC" \
    --output-facilities-path "$PREP_FAC" \
    --input-population-path "$UNROUTED_POP" \
    --output-population-path "$PREP_POP" \
    --threads "$THREADS"
for f in "$PREP_NET" "$PREP_FAC" "$PREP_POP"; do require_file "$f"; done

# ------------------------ 4. REROUTE ---------------------------------
# Reuse the FINAL CUT configuration/its associated small scenario files,
# including cut PT schedule and vehicles (not the full mapped PT network).
ROUTED_POP="$STAGE_DIR/population_routed.xml.gz"
log "STEP 4/6: Route prepared population on the prepared final network"
run_java org.eqasim.core.scenario.routing.RunPopulationRouting \
    --config-path "$CONFIG" \
    --config:network.inputNetworkFile "$PREP_NET" \
    --config:facilities.inputFacilitiesFile "$PREP_FAC" \
    --config:plans.inputPlansFile "$PREP_POP" \
    --config:transit.transitScheduleFile "$PT_SCHEDULE" \
    --config:transit.vehiclesFile "$PT_VEHICLES" \
    --output-path "$ROUTED_POP" \
    --threads "$THREADS"
require_file "$ROUTED_POP"

# ------------------------ 5. ASSEMBLE RUNNABLE SCENARIO --------------
# Replace only the three core scenario files in the COPIED folder.
# Keep their original prefix/name, so config-relative paths keep working.
log "STEP 5/6: Assemble the runnable scenario"
cp -f "$PREP_NET" "$SCENARIO_NET"
cp -f "$PREP_FAC" "$SCENARIO_FAC"
cp -f "$ROUTED_POP" "$SCENARIO_POP"
for f in "$SCENARIO_NET" "$SCENARIO_FAC" "$SCENARIO_POP"; do require_file "$f"; done

# ------------------------ 6. SIMULATE --------------------------------
log "STEP 6/6: Run MATSim using the assembled scenario"
run_java org.eqasim.switzerland.ch_cmdp.RunSimulation \
    --config-path "$CONFIG" \
    --config:network.inputNetworkFile "$SCENARIO_NET" \
    --config:facilities.inputFacilitiesFile "$SCENARIO_FAC" \
    --config:plans.inputPlansFile "$SCENARIO_POP" \
    --config:transit.transitScheduleFile "$PT_SCHEDULE" \
    --config:transit.vehiclesFile "$PT_VEHICLES" \
    --config:controller.outputDirectory "$OUTPUT_DIR"

log "DONE"
log "Runnable scenario: $SCENARIO_DIR"
log "Population:        $SCENARIO_POP"
log "Network:           $SCENARIO_NET"
log "Facilities:        $SCENARIO_FAC"
log "Simulation output: $OUTPUT_DIR"
