#!/usr/bin/env bash
#SBATCH --job-name=locarno_full_first
#SBATCH --partition=tue.cpu2.q
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=24
#SBATCH --mem=128G
#SBATCH --time=3:00:00
#SBATCH --output=locarno_full_first_%j.out
#SBATCH --error=locarno_full_first_%j.err

set -Eeuo pipefail
trap 'status=$?; echo "[$(date "+%F %T")] ERROR at line $LINENO (exit $status)" >&2' ERR

# ======================================================================
# LOCARNO / REV-CINTURA: FULL-SWITZERLAND PREPARATION -> ONE CUT
#   0. (Optional) build eqasim-java Switzerland JAR
#   1. Use/generate full mapped Switzerland network and PT inputs
#   2. Read ORIGINAL full ETH population/facilities from ETH_CONFIG
#   3. Unroute the full ETH population
#   4. Relink full population/facilities to full mapped network
#   5. Reroute full population on prepared full mapped network
#   6. CUT ONCE to REV-Cintura; cutter cleans per-mode network
#
# Same classes, arguments, and auxiliary resources as the final build.
# WARNING: Preparation/routing of FULL Switzerland is far more costly
# than the first-cut workflow. No MATSim simulation is run here.
# ======================================================================

# ------------------------------ PATHS ---------------------------------
JAVA_REPO="/home/20201733/eqasim-java-Fork"
PIPELINE_REPO="/home/20201733/eqasim-switzerland-Fork"
PIPELINE_CONFIG="$PIPELINE_REPO/conf_network_v2.yml"
PYTHON_VENV="$PIPELINE_REPO/.venv"

# ORIGINAL complete FULL-SWITZERLAND ETH scenario configuration.
ETH_CONFIG="/home/20201733/lucarno/lucarno_config.xml"
# Leave these empty to resolve inputPlansFile/inputFacilitiesFile from ETH_CONFIG.
# Alternatively set absolute paths if the ETH config uses unusual locations.
ETH_POP=""
ETH_FAC=""
SHAPE="/home/20201733/locarno_ETH_Model/shapes/REV_Cintura_project.shp"

# Optionally set a specific mapped-network XML/XML.GZ to bypass discovery.
# Leave empty to discover it within synpp's mapped-stage cache.
MAPPED_NETWORK="/home/20201733/locarno_ETH_Model/Updated_network/mapped_network.xml.gz"
PT_SCHEDULE="/home/20201733/locarno_ETH_Model/Updated_network/mapped_schedule.xml.gz"
PT_VEHICLES="/home/20201733/locarno_ETH_Model/Updated_network/transit_vehicles.xml.gz"

# Set to the `working_directory:` from Conf_network_v2.yml.
# Override if your pipeline config uses a different cache location.
SYNPP_CACHE_DIR="/home/20201733/eqasim_cache/network_freeze" # EDIT

# Mapped PT schedule and vehicles must match the mapped network.

RUN_ROOT="/home/20201733/locarno_ETH_Model/rebuilds"
FINAL_PREFIX="locarno_"

# Default eqasim configurator for all Java processes
export eqasim_configurator="org.eqasim.switzerland.ch_cmdp.SwitzerlandConfigurator"

# ------------------------- OPTIONAL SWITCHES -------------------------
BUILD_JAR=0        # 1 = Maven build first; 0 = reuse existing Switzerland JAR
RUN_SYNPP=0        # 1 = run Conf_network_v2.yml; 0 = use existing mapped network

THREADS="${SLURM_CPUS_PER_TASK:-24}"
HEAP="100G"       # headroom left for native memory and the OS
MAVEN_HOME="$HOME/software/apache-maven-3.9.6"

# Custom utility. Update only if you used another package or CLI.
UNROUTE_MAIN="org.thesis.UnroutePopulation"

# -------------------------- DIRECTORIES ------------------------------
JOB_TAG="${SLURM_JOB_ID:-manual_$(date +%Y%m%d_%H%M%S)}"
RUN_DIR="$RUN_ROOT/Full_$JOB_TAG"
STAGE_DIR="$RUN_DIR/04_05_prepared"   # contains FULL Switzerland intermediates
FINAL_CUT="$RUN_DIR/06_final_cut"
mkdir -p "$RUN_DIR" "$STAGE_DIR"

log() { echo "[$(date '+%F %T')] $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }
require_file() { [[ -s "$1" ]] || fail "Missing/empty file: $1"; }

ETH_DIR="$(dirname "$ETH_CONFIG")"

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
    local mode="$1"        # link or copy
    local target_dir="$2"
    local source_dir
    source_dir="$(dirname "$ETH_CONFIG")"

    mkdir -p "$target_dir"

    for file in "${AUX_FILES[@]}"; do
        require_file_or_dir="$source_dir/$file"

        [[ -e "$require_file_or_dir" ]] || fail "Missing ETH resource: $require_file_or_dir"

        # Preserve any existing files
        [[ -e "$target_dir/$file" || -L "$target_dir/$file" ]] && continue

        if [[ "$mode" == "link" ]]; then
            ln -s "$source_dir/$file" "$target_dir/$file"
        else
            cp -a "$source_dir/$file" "$target_dir/"
        fi
    done

    log "ETH auxiliary resources: $mode -> $target_dir"
}

run_java() {
    java -Xmx"$HEAP" -XX:ActiveProcessorCount="$THREADS" -cp "$JAR" "$@"
}

setup_java() {
    module purge
    module load EESSI/2026.06
    module load Java/25.36

    # Reuse Maven 3.9.6 installed in your home directory.
    export MAVEN_HOME
    export PATH="$MAVEN_HOME/bin:$PATH"

    # Save an absolute JDK 25 location; used by the Python pipeline as well
    # when that pipeline launches Java (e.g., PT2MATSim).
    JAVA25_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
    export JAVA_HOME="$JAVA25_HOME"
    export PATH="$JAVA_HOME/bin:$PATH"
    [[ "$(java -XshowSettings:properties -version 2>&1 | awk '/java.specification.version =/ {print $3}')" == 25 ]] \
        || fail "Java 25 was not loaded correctly"

    log "Java: $(java -version 2>&1 | head -1)"
    if [[ "$BUILD_JAR" == 1 ]]; then
        [[ -x "$MAVEN_HOME/bin/mvn" ]] || fail "Maven missing at $MAVEN_HOME/bin/mvn"
        mvn -version
    fi
}

setup_python() {
    # Existing Python 3.10.13 venv needs its Umbrella/2024 shared libraries.
    module purge
    module load Umbrella/2024
    module load Python/3.10.13-GCCcore-11.3.0
    [[ -f "$PYTHON_VENV/bin/activate" ]] || fail "Python venv missing: $PYTHON_VENV"
    source "$PYTHON_VENV/bin/activate"

    # The synpp network stages can launch Java; force JDK 25 even after
    # switching the module stack. Check it works in this environment.
    export JAVA_HOME="$JAVA25_HOME"
    export PATH="$JAVA_HOME/bin:$PATH"
    [[ "$(java -XshowSettings:properties -version 2>&1 | awk '/java.specification.version =/ {print $3}')" == 25 ]] \
        || fail "Java 25 unavailable while running the Python pipeline"
    log "Python: $(python --version 2>&1)"
    log "Pipeline Java: $(java -version 2>&1 | head -1)"
}

# ----------------------------- PREFLIGHT -----------------------------
require_file "$ETH_CONFIG"
require_file "$SHAPE"
if [[ "$RUN_SYNPP" == 1 ]]; then require_file "$PIPELINE_CONFIG"; fi
[[ -d "$JAVA_REPO" && -d "$PIPELINE_REPO" ]] || fail "Missing Java or synpp repository"
log "Run directory: $RUN_DIR"
log "Java commit: $(git -C "$JAVA_REPO" rev-parse --short HEAD)"

setup_java

# ------------------------- 0. COMPILE JAR ----------------------------
if [[ "$BUILD_JAR" == 1 ]]; then
    log "STEP 0/6: Build Switzerland JAR (Java 25 / Maven 3.9.6)"
    (cd "$JAVA_REPO" && mvn -B -pl switzerland -am clean package -Pstandalone -DskipTests -T 8)
fi

# Use the standalone Switzerland JAR
JAR="$JAVA_REPO/switzerland/target/switzerland.jar"

require_file "$JAR"
log "Using JAR: $JAR"
ls -lh "$JAR"

# Verify that the cutter is included
if ! jar tf "$JAR" | grep -Fx \
    'org/eqasim/core/scenario/cutter/RunScenarioCutter.class' >/dev/null; then
    fail "RunScenarioCutter is missing from $JAR"
fi

# ------------------------ 1. FULL MAPPED NETWORK ---------------------
if [[ "$RUN_SYNPP" == 1 ]]; then
    log "STEP 1/6: Rebuild full Switzerland mapped network with synpp"
    setup_python
    (cd "$PIPELINE_REPO" && python -m synpp "$PIPELINE_CONFIG") 2>&1 | tee "$RUN_DIR/synpp.log"
    deactivate
    setup_java
else
    log "STEP 1/6: Skip synpp, reuse existing full mapped network"
fi
# Synpp names each stage cache with a configuration-specific hash.
# Never rename the cache folder. Resolve the actual network XML within it.
if [[ -z "$MAPPED_NETWORK" ]]; then
    # Identify the exact mapped-network stage from the current synpp run
    STAGE_NAME="$(grep -oE 'matsim[.]scenario[.]network[.]mapped__[[:xdigit:]]+' \
        "$RUN_DIR/synpp.log" | tail -1 || true)"

    [[ -n "$STAGE_NAME" ]] || fail "Could not identify mapped-network stage from synpp log"

    MAPPED_NETWORK="$SYNPP_CACHE_DIR/${STAGE_NAME}.cache/mapped_network.xml.gz"
fi

require_file "$MAPPED_NETWORK"
log "Mapped network: $MAPPED_NETWORK"
require_file "$PT_SCHEDULE"
require_file "$PT_VEHICLES"
log "Mapped PT schedule: $PT_SCHEDULE"


# ------------------------ 2. ORIGINAL ETH INPUTS ----------------------
# Get the original FULL Swiss population and facilities, not any cut
# inputs. Resolve MATSim config paths relative to ETH_CONFIG's directory.
log "STEP 2/6: Resolve ORIGINAL full ETH population and facilities"
if [[ -z "$ETH_POP" || -z "$ETH_FAC" ]]; then
    setup_python
    ETH_PATHS="$(python - "$ETH_CONFIG" <<'PY_RESOLVE'
import pathlib
import sys
import xml.etree.ElementTree as ET

config_path = pathlib.Path(sys.argv[1]).expanduser().resolve()
root = ET.parse(config_path).getroot()
params = {}
for module in root.iter('module'):
    module_name = module.get('name')
    if module_name in ('plans', 'facilities'):
        for param in module.findall('param'):
            params[(module_name, param.get('name'))] = param.get('value', '')

for module_name, name in (
    ('plans', 'inputPlansFile'),
    ('facilities', 'inputFacilitiesFile'),
):
    value = params.get((module_name, name), '')
    if not value or value.lower() == 'null':
        raise SystemExit(f'Missing {module_name}.{name} in {config_path}')
    path = pathlib.Path(value).expanduser()
    if not path.is_absolute():
        path = config_path.parent / path
    print(path.resolve())
PY_RESOLVE
    )" || fail "Cannot determine ETH population/facilities from ETH config"
    mapfile -t ETH_INPUTS <<< "$ETH_PATHS"
    [[ "${#ETH_INPUTS[@]}" -eq 2 ]] || fail "Expected two input paths in ETH config"
    [[ -n "$ETH_POP" ]] || ETH_POP="${ETH_INPUTS[0]}"
    [[ -n "$ETH_FAC" ]] || ETH_FAC="${ETH_INPUTS[1]}"
    deactivate
    setup_java
fi
require_file "$ETH_POP"
require_file "$ETH_FAC"
log "Original ETH population: $ETH_POP"
log "Original ETH facilities: $ETH_FAC"

# ------------------------ 3. UNROUTE POPULATION ----------------------
UNROUTED_POP="$STAGE_DIR/population_unrouted.xml.gz"

log "STEP 3/6: Remove routes from ORIGINAL full ETH population"

run_java "$UNROUTE_MAIN" \
    "$ETH_POP" \
    "$UNROUTED_POP"

require_file "$UNROUTED_POP"

# ------------------------ 4. RELINK ----------------------------------
# RunPreparation takes the full ETH population/facilities and full
# MAPPED network. It can adjust network link lengths.
PREP_NET="$STAGE_DIR/network_prepared.xml.gz"
PREP_FAC="$STAGE_DIR/facilities_prepared.xml.gz"
PREP_POP="$STAGE_DIR/population_prepared.xml.gz"
log "STEP 4/6: Relink ORIGINAL FULL ETH facilities/population to mapped network"
run_java org.eqasim.core.scenario.preparation.RunPreparation \
    --input-network-path "$MAPPED_NETWORK" \
    --output-network-path "$PREP_NET" \
    --input-facilities-path "$ETH_FAC" \
    --output-facilities-path "$PREP_FAC" \
    --input-population-path "$UNROUTED_POP" \
    --output-population-path "$PREP_POP" \
    --threads "$THREADS"
for f in "$PREP_NET" "$PREP_FAC" "$PREP_POP"; do require_file "$f"; done

# ------------------------ 5. REROUTE ---------------------------------
# Use the ORIGINAL FULL ETH config and its household/vehicle/auxiliary
# inputs; override population, facilities, network, and mapped PT inputs.
ROUTED_POP="$STAGE_DIR/population_routed.xml.gz"
log "STEP 5/6: Reroute FULL Swiss population on prepared FULL mapped network"
run_java org.eqasim.core.scenario.routing.RunPopulationRouting \
    --config-path "$ETH_CONFIG" \
    --config:network.inputNetworkFile "$PREP_NET" \
    --config:facilities.inputFacilitiesFile "$PREP_FAC" \
    --config:plans.inputPlansFile "$PREP_POP" \
    --config:transit.transitScheduleFile "$PT_SCHEDULE" \
    --config:transit.vehiclesFile "$PT_VEHICLES" \
    --config:routing.networkRouteConsistencyCheck disable \
    --output-path "$ROUTED_POP" \
    --threads "$THREADS"
require_file "$ROUTED_POP"

# ------------------------ 6. SINGLE REV CUT --------------------------
# Cut the fully prepared/routed Swiss scenario ONCE. The cutter cleans
# modal subnetworks, including bike. As in the original final build,
# cutter routing is enabled so it can repair/fill routes after cutting.
log "STEP 6/6: Single cut FULL rerouted scenario to REV-Cintura"
run_java org.eqasim.core.scenario.cutter.RunScenarioCutter \
    --config-path "$ETH_CONFIG" \
    --config:network.inputNetworkFile "$PREP_NET" \
    --config:facilities.inputFacilitiesFile "$PREP_FAC" \
    --config:plans.inputPlansFile "$ROUTED_POP" \
    --config:transit.transitScheduleFile "$PT_SCHEDULE" \
    --config:transit.vehiclesFile "$PT_VEHICLES" \
    --extent-path "$SHAPE" \
    --output-path "$FINAL_CUT" \
    --prefix "$FINAL_PREFIX" \
    --threads "$THREADS"

FINAL_CONFIG="$FINAL_CUT/${FINAL_PREFIX}config.xml"
FINAL_NET="$FINAL_CUT/${FINAL_PREFIX}network.xml.gz"
FINAL_POP="$FINAL_CUT/${FINAL_PREFIX}population.xml.gz"
FINAL_FAC="$FINAL_CUT/${FINAL_PREFIX}facilities.xml.gz"
for f in "$FINAL_CONFIG" "$FINAL_NET" "$FINAL_POP" "$FINAL_FAC"; do require_file "$f"; done
setup_aux_files copy "$FINAL_CUT"

# Ensure the cutter produced the complete runnable scenario bundle.
for part in households transit_schedule transit_vehicles vehicles; do
    require_file "$FINAL_CUT/${FINAL_PREFIX}${part}.xml.gz"
done

# Counts: full ETH population, full rerouted population, final REV cut.
count_people() {
    if [[ "$1" == *.gz ]]; then
        gzip -dc "$1" | awk '/<person id=/{count++} END{print count+0}'
    else
        awk '/<person id=/{count++} END{print count+0}' "$1"
    fi
}
N_ORIGINAL="$(count_people "$ETH_POP")"
N_ROUTED="$(count_people "$ROUTED_POP")"
N_FINAL="$(count_people "$FINAL_POP")"
log "Persons: original full ETH=$N_ORIGINAL; rerouted full ETH=$N_ROUTED; final REV cut=$N_FINAL"
if [[ "$N_ORIGINAL" != "$N_ROUTED" ]]; then
    log "WARNING: Person counts changed during full Switzerland preparation/routing."
fi

log "DONE: single-cut scenario"
log "Original ETH population: $ETH_POP"
log "Prepared FULL scenario: $STAGE_DIR"
log "Final REV scenario:    $FINAL_CUT"
log "Final config:          $FINAL_CONFIG"
log "Final network:         $FINAL_NET"
log "Final population:      $FINAL_POP"
log "Final facilities:      $FINAL_FAC"
log "IMPORTANT: Check PT link compatibility, final activity links, outside trips, and network calibration before simulation."
