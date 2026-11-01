#!/bin/bash
#SBATCH --output=G16_%A_%a.log
#SBATCH --error=G16_%A_%a.err
#SBATCH -p cpu
#SBATCH -N 1
#SBATCH --ntasks-per-node=20
#SBATCH --mem=20G
# Note: --array is dynamically specified by the script itself at submission
#       time on the login node via sbatch --array=1-N.

# =============================================================================
# submit_all.sh
# Stage 1: SDF -> GJF (Multiwfn) -> sbatch -> Gaussian opt freq -> .log + .fchk
#
# Changes relative to the previous version:
#   4.  Fixed the issue that the exit code of g16 could not be captured
#       under `set -e`.
#   10. g16 is now explicitly redirected, consistent with run_g16.sh.
#   11. The %chk check now matches optional leading whitespace.
#   12. Removed deletion of Slurm output inside the job (to avoid
#       conflicts with Slurm's own writes).
# =============================================================================
set -e

# ---------- User configuration ----------
MWFN="/public/software/Multiwfn_3.8_dev_bin_Linux_noGUI/Multiwfn_noGUI"

SDF_DIR="."
GJF_DIR="${GJF_DIR:-./gjf}"
INPUT_LIST="input_list.txt"

NPROC=20
MEM="20GB"
ROUTE_LINE="#P opt freq b3lyp/6-311g(d,p) scrf=(iefpcm,solvent=water) em=gd3bj"

KEEP_MWFN_LOG=0

MWFN_SDF2GJF_CMDS=$'100\n2\n10\n\n0\n0\nq\n'
MWFN_TIMEOUT=90

# =============================================================================
# Inject calculation settings
# =============================================================================
inject_settings() {
    local gjf_file="$1"
    local base
    base=$(basename "$gjf_file" .gjf)

    grep -q "^[[:space:]]*%nprocshared=" "$gjf_file" || sed -i "1i %nprocshared=${NPROC}" "$gjf_file"
    grep -q "^[[:space:]]*%mem="         "$gjf_file" || sed -i "1i %mem=${MEM}"          "$gjf_file"
    grep -q "^[[:space:]]*%chk="         "$gjf_file" || sed -i "1i %chk=${base}.chk"    "$gjf_file"

    # Replace only the first '#' route line
    awk -v route="$ROUTE_LINE" '
        BEGIN { done = 0 }
        /^[[:space:]]*#/ && !done { print route; done = 1; next }
        { print }
    ' "$gjf_file" > "${gjf_file}.tmp" && mv "${gjf_file}.tmp" "$gjf_file"

    if ! grep -q "^[[:space:]]*#P" "$gjf_file"; then
        echo "    WARNING: no '#P' route line found in ${gjf_file}"
    fi
}

# =============================================================================
# Mode A: login node -- generate GJF files and submit itself
# =============================================================================
run_prepare() {
    echo "########## prepare mode (login node) ##########"

    mkdir -p "$GJF_DIR"
    > "$INPUT_LIST"

    shopt -s nullglob
    sdf_files=("$SDF_DIR"/*.sdf "$SDF_DIR"/*.SDF)
    shopt -u nullglob

    if [ ${#sdf_files[@]} -eq 0 ]; then
        echo "ERROR: no .sdf files found in the current directory"
        exit 1
    fi

    for sdf in "${sdf_files[@]}"; do
        local base gjf_out log_out sdf_abs tmp_dir found_gjf
        base=$(basename "$sdf"); base="${base%.*}"
        gjf_out="${GJF_DIR}/${base}.gjf"
        log_out="./mwfn_${base}.log"

        echo "=============================================="
        echo ">>> [Multiwfn] ${sdf}  ->  ${gjf_out}"
        echo "=============================================="

        sdf_abs=$(realpath "$sdf")
        if [ ! -f "$sdf_abs" ]; then
            echo "    -> FAILED: invalid realpath: '${sdf_abs}'"
            continue
        fi

        tmp_dir=$(mktemp -d)
        (
            cd "$tmp_dir"
            printf "%s" "$MWFN_SDF2GJF_CMDS" | \
                timeout "$MWFN_TIMEOUT" "$MWFN" "$sdf_abs" > mwfn.log 2>&1 || true
        )

        cp "${tmp_dir}/mwfn.log" "$log_out" 2>/dev/null || true

        found_gjf=""
        for cand in "${tmp_dir}/${base}.gjf" "${tmp_dir}"/*.gjf; do
            if [ -f "$cand" ]; then
                found_gjf="$cand"; break
            fi
        done

        if [ -n "$found_gjf" ]; then
            mv "$found_gjf" "$gjf_out"
        fi
        rm -rf "$tmp_dir"

        if [ -f "$gjf_out" ]; then
            inject_settings "$gjf_out"
            echo "$base" >> "$INPUT_LIST"
            echo "    -> OK, added to ${INPUT_LIST}"
            if [ "${KEEP_MWFN_LOG:-0}" -eq 0 ]; then
                rm -f "$log_out"
            fi
        else
            echo "    -> FAILED, see the tail of ${log_out}"
            tail -30 "$log_out" | sed 's/^/           /'
        fi
    done

    local N
    N=$(wc -l < "$INPUT_LIST")
    if [ "$N" -eq 0 ]; then
        echo "ERROR: ${INPUT_LIST} is empty, aborting submission"
        exit 1
    fi

    echo ""
    echo "=============================================="
    echo "${N} GJF files ready, submitting array job 1-${N}"
    echo "=============================================="

    local self_abs
    self_abs=$(realpath "$0")
    sbatch --array=1-${N} \
           --export=ALL,GJF_DIR="${GJF_DIR}" \
           "$self_abs"
}

# =============================================================================
# Mode B: compute node -- run Gaussian for one molecule
# =============================================================================
run_gaussian() {
    local INPUT_SUFFIX=".gjf"

    local InputfileName
    InputfileName=$(sed -n "${SLURM_ARRAY_TASK_ID}p" "$INPUT_LIST" | tr -d '\r\n')
    if [ -z "$InputfileName" ]; then
        echo "Error: No input for task ${SLURM_ARRAY_TASK_ID}"
        exit 1
    fi

    echo "========== Processing: ${InputfileName} =========="

    local MAIN_WORKDIR TASK_DIR
    MAIN_WORKDIR=$(pwd)
    TASK_DIR="${MAIN_WORKDIR}/task_${SLURM_ARRAY_TASK_ID}_${InputfileName}"
    mkdir -p "${TASK_DIR}"

    cp "${GJF_DIR}/${InputfileName}${INPUT_SUFFIX}" "${TASK_DIR}/" || {
        echo "Error: cannot find ${GJF_DIR}/${InputfileName}${INPUT_SUFFIX}"
        exit 1
    }
    cd "${TASK_DIR}" || { echo "Cannot enter task dir"; exit 1; }

    local SCRATCH_DIR
    SCRATCH_DIR="/public/home/$(whoami)/scratch/${SLURM_ARRAY_JOB_ID}_${SLURM_ARRAY_TASK_ID}"
    export GAUSS_SCRDIR="${SCRATCH_DIR}"
    mkdir -p "${GAUSS_SCRDIR}"

    # Item 11: allow leading whitespace
    if ! grep -q "^[[:space:]]*%chk=" "${InputfileName}${INPUT_SUFFIX}"; then
        sed -i "1s/^/%chk=${InputfileName}.chk\n/" "${InputfileName}${INPUT_SUFFIX}"
    fi

    echo "Starting G16 for ${InputfileName} at $(date)"

    module load gauss/16

    # Item 4:  use || to capture the exit code so that set -e does not abort early
    # Item 10: explicit redirection
    local G16_EXIT_CODE=0
    g16 < "${InputfileName}${INPUT_SUFFIX}" > "${InputfileName}.log" 2>&1 || G16_EXIT_CODE=$?

    echo "Finished (exit=${G16_EXIT_CODE}) at $(date)"

    if [ ${G16_EXIT_CODE} -eq 0 ] && [ -f "${InputfileName}.chk" ]; then
        formchk "${InputfileName}.chk" "${InputfileName}.fchk"
        cp "${InputfileName}.log"  "${MAIN_WORKDIR}/"
        cp "${InputfileName}.fchk" "${MAIN_WORKDIR}/"
    else
        echo "Error: G16 failed or no .chk (exit=${G16_EXIT_CODE})"
        # keep .log for debugging
        cp "${InputfileName}.log" "${MAIN_WORKDIR}/" 2>/dev/null || true
        cd "${MAIN_WORKDIR}" || exit 1
        rm -rf "${TASK_DIR}" "${GAUSS_SCRDIR}"
        exit 1
    fi

    cd "${MAIN_WORKDIR}" || exit
    rm -rf "${TASK_DIR}" "${GAUSS_SCRDIR}"

    # Item 12: do not delete Slurm output, to help debugging

    echo "========== Done: ${InputfileName} =========="
}

# =============================================================================
# Entry point
# =============================================================================
if [ -z "${SLURM_ARRAY_TASK_ID:-}" ]; then
    run_prepare
else
    run_gaussian
fi