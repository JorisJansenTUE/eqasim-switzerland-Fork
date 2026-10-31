#!/usr/bin/env bash
#SBATCH --job-name=locarno_rebuild_movement
#SBATCH --partition=mech-cst-mov.cpu.q
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=24
#SBATCH --mem=256G
#SBATCH --time=18:00:00
#SBATCH --output=locarno_rebuild_%j.out
#SBATCH --error=locarno_rebuild_%j.err

set -Eeuo pipefail
trap 'echo "[$(date "+%F %T")] ERROR at line $LINENO (exit $?)" >&2' ERR

# ======================================================================
# LOCARNO / REV-CINTURA: TWO-CUT REBUILD
#   0. (Optional) build eqasim-java Switzerland JAR
#   1. Cut ORIGINAL ETH scenario to REV-Cintura (population-size reduction)
#   2. Generate a NEW full mapped network with synpp
#   3. Unroute the population from the FIRST cut
#   4. Relink first-cut population and facilities to the NEW network
#   5. Reroute this smaller population on the NEW network
#   6. Cut the prepared/routed scenario again; cutter cleans bike network
#
# No separate CleanBikeNetwork step: RunScenarioCutter already cleans
# the largest connected component per network mode AFTER network cutting.
# ======================================================================

# ------------------------------ PATHS ---------------------------------
JAVA_REPO="/home/20201733/eqasim-java-Fork"
PIPELINE_REPO="/home/20201733/eqasim-switzerland-Fork"
PIPELINE_CONFIG="$PIPELINE_REPO/Conf_network_v2.yml"
PYTHON_VENV="$PIPELINE_REPO/.venv"

# Existing, complete and VALID ETH scenario configuration (Swiss model).
ETH_CONFIG="/home/20201733/lucarno/lucarno_config.xml"   # EDIT
SHAPE="/home/20201733/locarno_ETH_Model/shapes/REV_cintura_project.shp"           # EDIT

# Optionally set a specific mapped-network XML/XML.GZ to bypass discovery.
# Leave empty to discover it within synpp's mapped-stage cache.
MAPPED_NETWORK=""

# Set to the `working_directory:` from Conf_network_v2.yml.
# Override if your pipeline config uses a different cache location.
SYNPP_CACHE_DIR="/home/20201733/eqasim_cache/network_freeze" # EDIT

# If regenerated PT link IDs differ from the first ETH cut, this must
# be addressed separately. See notes accompanying this script.
# These are not automatically compatible just because the road network is.

RUN_ROOT="/home/20201733/locarno_ETH_Model/rebuilds"
FIRST_PREFIX="eth_rev_"
FINAL_PREFIX="locarno_"

# ------------------------- OPTIONAL SWITCHES -------------------------
BUILD_JAR=1        # 1 = Maven build first; 0 = reuse existing Switzerland JAR
RUN_SYNPP=1        # 1 = run Conf_network_v2.yml; 0 = use existing mapped network

THREADS="${SLURM_CPUS_PER_TASK:-24}"
HEAP="200G"       # headroom left for native memory and the OS
MAVEN_HOME="$HOME/software/apache-maven-3.9.6"

# Custom utility. Update only if you used another package or CLI.
UNROUTE_MAIN="org.eqasim.switzerland.thesis.UnroutePopulation"

# -------------------------- DIRECTORIES ------------------------------
JOB_TAG="${SLURM_JOB_ID:-manual_$(date +%Y%m%d_%H%M%S)}"
RUN_DIR="$RUN_ROOT/$JOB_TAG"
FIRST_CUT="$RUN_DIR/01_eth_cut"
STAGE_DIR="$RUN_DIR/04_05_prepared"
FINAL_CUT="$RUN_DIR/06_final_cut"
mkdir -p "$RUN_DIR" "$STAGE_DIR"

log() { echo "[$(date '+%F %T')] $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }
require_file() { [[ -s "$1" ]] || fail "Missing/empty file: $1"; }

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
require_file "$PIPELINE_CONFIG"
[[ -d "$JAVA_REPO" && -d "$PIPELINE_REPO" ]] || fail "Missing Java or synpp repository"
log "Run directory: $RUN_DIR"
log "Java commit: $(git -C "$JAVA_REPO" rev-parse --short HEAD)"

setup_java

# ------------------------- 0. COMPILE JAR ----------------------------
if [[ "$BUILD_JAR" == 1 ]]; then
    log "STEP 0/6: Build Switzerland JAR (Java 25 / Maven 3.9.6)"
    (cd "$JAVA_REPO" && mvn -B -pl switzerland -am -DskipTests package)
fi

# Choose the most recently built runnable jar (exclude sources/original).
JAR="$(find "$JAVA_REPO/switzerland/target" -maxdepth 1 -type f \
    -name 'switzerland-*.jar' ! -name '*-sources.jar' \
    ! -name '*-javadoc.jar' ! -name 'original-*' \
    -printf '%T@ %p\n' | sort -nr | head -1 | cut -d' ' -f2-)"
[[ -n "$JAR" ]] || fail "No runnable Switzerland jar in $JAVA_REPO/switzerland/target"
require_file "$JAR"
log "Using JAR: $JAR"

# ------------------------ 1. FIRST ETH CUT ---------------------------
# Uses ORIGINAL ETH network, facilities, population and PT from ETH_CONFIG.
# Keep original routes for later replacement, avoid extra routing now.
log "STEP 1/6: Cut original ETH scenario to REV-Cintura"
run_java org.eqasim.core.scenario.cutter.RunScenarioCutter \
    --config-path "$ETH_CONFIG" \
    --extent-path "$SHAPE" \
    --output-path "$FIRST_CUT" \
    --prefix "$FIRST_PREFIX" \
    --threads "$THREADS" \
    --skip-routing true

FIRST_CONFIG="$FIRST_CUT/${FIRST_PREFIX}config.xml"
FIRST_POP="$FIRST_CUT/${FIRST_PREFIX}population.xml.gz"
FIRST_FAC="$FIRST_CUT/${FIRST_PREFIX}facilities.xml.gz"
for f in "$FIRST_CONFIG" "$FIRST_POP" "$FIRST_FAC"; do require_file "$f"; done

# ------------------------ 2. SYNPP NETWORK ---------------------------
# ------------------------ 2. SYNPP NETWORK ---------------------------
if [[ "$RUN_SYNPP" == 1 ]]; then
    log "STEP 2/6: Rebuild Swiss mapped network with synpp"
    setup_python
    (cd "$PIPELINE_REPO" && python -m synpp "$PIPELINE_CONFIG")
    deactivate
    # Return to Java 25 environment for processing MATSim XML files.
    setup_java
else
    log "STEP 2/6: Skip synpp, reuse existing mapped network"
fi
# Synpp names each stage cache with a configuration-specific hash.
# Never rename the cache folder. Resolve the actual network XML within it.
if [[ -z "$MAPPED_NETWORK" ]]; then
    [[ -d "$SYNPP_CACHE_DIR" ]] || \
        fail "Synpp cache directory not found: $SYNPP_CACHE_DIR (set it to working_directory in the yml)"

    mapfile -t MAPPED_CACHE_DIRS < <(find "$SYNPP_CACHE_DIR" -maxdepth 1 -type d \
        -name 'matsim.scenario.network.mapped__*.cache' | sort)
    if [[ ${#MAPPED_CACHE_DIRS[@]} -ne 1 ]]; then
        printf 'Mapped-stage cache candidates (%s):\n' "${#MAPPED_CACHE_DIRS[@]}" >&2
        printf '  %s\n' "${MAPPED_CACHE_DIRS[@]}" >&2
        fail "Expected exactly one mapped-stage cache; choose explicitly if multiple hashes exist."
    fi

    mapfile -t NETWORK_FILES < <(find "${MAPPED_CACHE_DIRS[0]}" -type f \
        \( -name '*.xml' -o -name '*.xml.gz' \) | sort)
    if [[ ${#NETWORK_FILES[@]} -ne 1 ]]; then
        printf 'XML candidate files (%s):\n' "${#NETWORK_FILES[@]}" >&2
        printf '  %s\n' "${NETWORK_FILES[@]}" >&2
        fail "Could not uniquely identify a mapped-network XML. Inspect this cache, then set MAPPED_NETWORK explicitly."
    fi
    MAPPED_NETWORK="${NETWORK_FILES[0]}"
fi
require_file "$MAPPED_NETWORK"
log "Mapped network: $MAPPED_NETWORK"

# ------------------------ 3. UNROUTE POPULATION ----------------------
# IMPORTANT: This class is custom. Its --input-path / --output-path
# argument names must match your actual UnroutePopulation.java main().
UNROUTED_POP="$STAGE_DIR/population_unrouted.xml.gz"
log "STEP 3/6: Clear old routes from first-cut population"
run_java "$UNROUTE_MAIN" \
    --input-path "$FIRST_POP" \
    --output-path "$UNROUTED_POP"
require_file "$UNROUTED_POP"

# ------------------------ 4. RELINK ----------------------------------
# RunPreparation reads the small first-cut population/facilities, but
# the NEW FULL MAPPED NETWORK. It writes a network with adjusted lengths.
PREP_NET="$STAGE_DIR/network_prepared.xml.gz"
PREP_FAC="$STAGE_DIR/facilities_prepared.xml.gz"
PREP_POP="$STAGE_DIR/population_prepared.xml.gz"
log "STEP 4/6: Relink facilities/population to regenerated network"
run_java org.eqasim.core.scenario.preparation.RunPreparation \
    --input-network-path "$MAPPED_NETWORK" \
    --output-network-path "$PREP_NET" \
    --input-facilities-path "$FIRST_FAC" \
    --output-facilities-path "$PREP_FAC" \
    --input-population-path "$UNROUTED_POP" \
    --output-population-path "$PREP_POP" \
    --threads "$THREADS"
for f in "$PREP_NET" "$PREP_FAC" "$PREP_POP"; do require_file "$f"; done

# ------------------------ 5. REROUTE ---------------------------------
# Use the first CUT config to keep the compatible households, vehicles,
# and cut public transport, but OVERRIDE its population/facilities/network.
# Relative paths in FIRST_CONFIG resolve against the FIRST_CUT folder.
ROUTED_POP="$STAGE_DIR/population_routed.xml.gz"
log "STEP 5/6: Reroute first-cut population on newly mapped network"
run_java org.eqasim.core.scenario.routing.RunPopulationRouting \
    --config-path "$FIRST_CONFIG" \
    --config:network.inputNetworkFile "$PREP_NET" \
    --config:facilities.inputFacilitiesFile "$PREP_FAC" \
    --config:plans.inputPlansFile "$PREP_POP" \
    --output-path "$ROUTED_POP" \
    --threads "$THREADS"
require_file "$ROUTED_POP"

# ------------------------ 6. SECOND CUT ------------------------------
# Cut the new network to the same extent. NetworkCutter first cuts the
# network, then cleans it per mode (including bike). We allow final
# cutter routing; it fills missing routes but does not replace existing
# routes that were already recomputed in STEP 5.
log "STEP 6/6: Cut regenerated scenario to REV-Cintura (and clean bike mode)"
run_java org.eqasim.core.scenario.cutter.RunScenarioCutter \
    --config-path "$FIRST_CONFIG" \
    --config:network.inputNetworkFile "$PREP_NET" \
    --config:facilities.inputFacilitiesFile "$PREP_FAC" \
    --config:plans.inputPlansFile "$ROUTED_POP" \
    --extent-path "$SHAPE" \
    --output-path "$FINAL_CUT" \
    --prefix "$FINAL_PREFIX" \
    --threads "$THREADS"

FINAL_CONFIG="$FINAL_CUT/${FINAL_PREFIX}config.xml"
FINAL_NET="$FINAL_CUT/${FINAL_PREFIX}network.xml.gz"
FINAL_POP="$FINAL_CUT/${FINAL_PREFIX}population.xml.gz"
FINAL_FAC="$FINAL_CUT/${FINAL_PREFIX}facilities.xml.gz"
for f in "$FINAL_CONFIG" "$FINAL_NET" "$FINAL_POP" "$FINAL_FAC"; do require_file "$f"; done

# A second cut can alter the retained population; report the size difference.
count_people() {
    gzip -dc "$1" | awk '/<person id=/{count++} END{print count+0}'
}
N_FIRST="$(count_people "$FIRST_POP")"
N_FINAL="$(count_people "$FINAL_POP")"
log "Population persons: initial ETH cut=$N_FIRST; final new-network cut=$N_FINAL"
if [[ "$N_FIRST" != "$N_FINAL" ]]; then
    log "WARNING: person counts changed between cuts; inspect outside-trip handling."
fi

log "DONE"
log "First ETH cut:     $FIRST_CUT"
log "Prepared scenario: $STAGE_DIR"
log "Final scenario:    $FINAL_CUT"
log "Final config:      $FINAL_CONFIG"
log "Final network:     $FINAL_NET"
log "Final population:  $FINAL_POP"
log "IMPORTANT: Check population counts, PT link compatibility, outside activities, and speedFactor calibration before simulation."
