#!/bin/bash
#SBATCH --job-name=locarno_second_cut
#SBATCH --partition=mech-cst-mov.cpu.q
#SBATCH --cpus-per-task=24
#SBATCH --mem=256G
#SBATCH --time=05:00:00
#SBATCH --output=second_cut_%j.out
#SBATCH --error=second_cut_%j.err
set -euo pipefail

# Usage: sbatch second_cut_only.slurm SUCCESSFUL_REBUILD_JOB_ID [true|false]
# true = do NOT run the final population router (diagnostic default).
REBUILD_ID="${1:?Supply successful rebuild job ID as first argument}"
SKIP_ROUTING="${2:-true}"
[[ "$SKIP_ROUTING" == true || "$SKIP_ROUTING" == false ]] || { echo 'Second argument must be true or false' >&2; exit 1; }

BASE=/home/20201733/locarno_ETH_Model
SOURCE="$BASE/rebuilds/$REBUILD_ID"
PREP="$SOURCE/04_05_prepared"
FIRST_CONFIG="$SOURCE/01_eth_cut/eth_rev_config.xml"
PREP_NET="$PREP/network_prepared.xml.gz"
PREP_FAC="$PREP/facilities_prepared.xml.gz"
SHAPE="/home/20201733/locarno_ETH_Model/shapes/REV_Cintura_project.shp"
JAR=/home/20201733/eqasim-java-Fork/switzerland/target/switzerland.jar

# Prefer explicitly routed population where it exists; allow override via environment.
if [[ -z "${ROUTED_POP:-}" ]]; then
    if [[ -f "$PREP/population_routed.xml.gz" ]]; then
        ROUTED_POP="$PREP/population_routed.xml.gz"
    else
        ROUTED_POP="$PREP/population_prepared.xml.gz"
    fi
fi

# Use the same matching PT inputs as the successful rebuild.
# Override these variables at submission if that run used another location.
PT_SCHEDULE="${PT_SCHEDULE:-$BASE/Updated_network/mapped_schedule.xml.gz}"
PT_VEHICLES="${PT_VEHICLES:-$BASE/Updated_network/transit_vehicles.xml.gz}"

# New output for each diagnostic run, leaving the successful cut untouched.
FINAL_CUT="$SOURCE/06_final_cut_debug_${SKIP_ROUTING}_${SLURM_JOB_ID}"

for f in "$FIRST_CONFIG" "$PREP_NET" "$PREP_FAC" "$ROUTED_POP" "$PT_SCHEDULE" "$PT_VEHICLES" "$SHAPE" "$JAR"; do
    [[ -f "$f" ]] || { echo "ERROR: Missing input: $f" >&2; exit 1; }
done

module purge
module load EESSI/2026.06
module load Java/25.36

echo "Source rebuild: $SOURCE"
echo "Population:     $ROUTED_POP"
echo "Network:        $PREP_NET"
echo "Facilities:     $PREP_FAC"
echo "Schedule:       $PT_SCHEDULE"
echo "PT vehicles:    $PT_VEHICLES"
echo "Skip routing:   $SKIP_ROUTING"
echo "Output:         $FINAL_CUT"

java -Xmx210G -cp "$JAR" org.eqasim.core.scenario.cutter.RunScenarioCutter \
    --config-path "$FIRST_CONFIG" \
    --output-path "$FINAL_CUT" \
    --extent-path "$SHAPE" \
    --prefix locarno_ \
    --threads "${SLURM_CPUS_PER_TASK:-24}" \
    --plans-path "$ROUTED_POP" \
    --config:network.inputNetworkFile "$PREP_NET" \
    --config:facilities.inputFacilitiesFile "$PREP_FAC" \
    --config:plans.inputPlansFile "$ROUTED_POP" \
    --config:transit.transitScheduleFile "$PT_SCHEDULE" \
    --config:transit.vehiclesFile "$PT_VEHICLES" \
    --skip-routing "$SKIP_ROUTING" \
    --eqasim-configurator org.eqasim.switzerland.ch_cmdp.SwitzerlandConfigurator

echo "Completed second cut in: $FINAL_CUT"
