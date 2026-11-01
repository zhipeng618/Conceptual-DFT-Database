#!/bin/bash
# =============================================================================
# fchk_to_cdft.sh
# Stage 2: FCHK -> 4 GJF files (N / N-1 / N-2 / N+1) -> 4 Gaussian single-point
#          calculations -> CDFT text output
#
# =============================================================================
set -e

# ---------- User configuration ----------
MWFN="/public/software/Multiwfn_3.8_dev_bin_Linux_noGUI/Multiwfn_noGUI"
SLEEP_INTERVAL=60
MAX_WAIT=3600
ERROR_FILE="error_list.txt"

NPROC=20
MEM="20GB"
ROUTE_LINE="#P b3lyp/6-311g(d,p) scrf=(smd,solvent=water) empiricaldispersion=gd3bj out=wfn"

MWFN_GEN_GJF_CMDS=$'22\n-1\n1\n\n\n'
MWFN_GEN_CDFT_CMDS=$'22\n-1\n1\n\n\n2\n\n'

JOB_IDS=()

# =============================================================================
# 0. Clean up leftovers from the previous run (Item 1: explicit file names,
#    no N* wildcard)
# =============================================================================
clean_old_files() {
    rm -f N.gjf N-1.gjf N-2.gjf N+1.gjf \
          N.wfn N-1.wfn N-2.wfn N+1.wfn \
          N.log N-1.log N-2.log N+1.log \
          N.chk N-1.chk N-2.chk N+1.chk 2>/dev/null || true
}

# =============================================================================
# 1. Use Multiwfn to generate the 4 GJF files
# =============================================================================
run_multiwfn_generate_gjf() {
    local fchk="$1"
    local mwfn_log="./mwfn_gjf_${fchk%.fchk}.log"
    echo "▶ Generating GJF with Multiwfn: ${fchk}"
    printf "%s" "$MWFN_GEN_GJF_CMDS" | \
        timeout 300 "$MWFN" "$fchk" > "$mwfn_log" 2>&1 || true
    echo "✔ Multiwfn GJF generation finished (log: ${mwfn_log})"
    sleep 0.5
}

# =============================================================================
# 2. Modify the GJF files (Item 8: replace only the first '#')
# =============================================================================
modify_gjf() {
    local gjf_names=("N.gjf" "N-1.gjf" "N-2.gjf" "N+1.gjf")
    local exist=1

    for gjf in "${gjf_names[@]}"; do
        [ -f "$gjf" ] || continue
        exist=0
        echo "  → Modifying ${gjf}"

        local base="${gjf%.gjf}"
        local tmp
        tmp=$(mktemp)

        {
            echo "%nprocshared=${NPROC}"
            echo "%mem=${MEM}"
            echo "%chk=${base}.chk"
        } > "$tmp"

        # Replace only the first line starting with '#';
        # any later '#...' lines are kept unchanged.
        awk -v route="$ROUTE_LINE" '
            BEGIN { done = 0 }
            /^[[:space:]]*#/ && !done { print route; done = 1; next }
            { print }
        ' "$gjf" >> "$tmp"

        mv "$tmp" "$gjf"
    done

    return $exist
}

# =============================================================================
# 3. Write run_g16.sh (Item 2: set -e + mem; Item 3: variable checks;
#    Item 12: per-job scratch directory)
# =============================================================================
write_run_g16_sh() {
    cat > run_g16.sh << EOF
#!/bin/bash
#SBATCH -J g16
#SBATCH -p cpu
#SBATCH -N 1
#SBATCH --no-requeue
#SBATCH --ntasks-per-node=${NPROC}
#SBATCH --mem=20G

set -e

cd \$SLURM_SUBMIT_DIR

module load gauss/16

export GAUSS_SCRDIR="/public/home/\$(whoami)/scratch/\${SLURM_JOB_ID}_\${INPUTFILE%.gjf}"
mkdir -p "\$GAUSS_SCRDIR"

g16 < "\$INPUTFILE" > "\${INPUTFILE%.gjf}.log"
formchk "\${INPUTFILE%.gjf}.chk"

rm -f "\$GAUSS_SCRDIR"/*
rm -rf "\$GAUSS_SCRDIR"
EOF
    chmod +x run_g16.sh
    echo "✔ Generated run_g16.sh"
}

# =============================================================================
# 4. Submit the 4 Gaussian jobs via sbatch (Item 10: with --job-name)
# =============================================================================
submit_gaussian() {
    local gjf_list=("N.gjf" "N-1.gjf" "N-2.gjf" "N+1.gjf")
    JOB_IDS=()

    for gjf in "${gjf_list[@]}"; do
        [ -f "$gjf" ] || continue
        echo "  → Submitting via sbatch: ${gjf}"

        local output
        output=$(sbatch --export=INPUTFILE="$gjf" \
                        --job-name="g16_${gjf%.gjf}" \
                        run_g16.sh 2>&1)

        local job_id
        job_id=$(echo "$output" | grep -oE 'Submitted batch job [0-9]+' | grep -oE '[0-9]+' || true)

        if [ -n "$job_id" ]; then
            JOB_IDS+=("$job_id")
            echo "    Job ID: ${job_id}"
        else
            echo "    Warning: failed to parse job ID, output: ${output}"
        fi
    done
}

# =============================================================================
# 5. Wait for the 4 WFN files to appear
# =============================================================================
wait_for_wfn() {
    local fchk_name="$1"
    local wfn_files=("N.wfn" "N-1.wfn" "N-2.wfn" "N+1.wfn")

    echo "⏳ Waiting for WFN files (up to $((MAX_WAIT/60)) min)..."
    local elapsed=0

    while [ $elapsed -lt $MAX_WAIT ]; do
        local all_exist=1
        for f in "${wfn_files[@]}"; do
            if [ ! -f "$f" ]; then
                all_exist=0; break
            fi
        done

        if [ $all_exist -eq 1 ]; then
            echo "✔ All WFN files are present"
            return 0
        fi

        sleep $SLEEP_INTERVAL
        elapsed=$((elapsed + SLEEP_INTERVAL))
    done

    echo "❗ WFN files for ${fchk_name} were not generated in time"
    echo "${fchk_name}_WFN_TIMEOUT" >> "$ERROR_FILE"
    return 1
}

# =============================================================================
# 6. Generate CDFT text with Multiwfn
#    (Item 7: locate the output precisely with find -newermt)
# =============================================================================
run_multiwfn_generate_cdft() {
    local fchk_name="$1"
    local mwfn_log="./mwfn_cdft_${fchk_name}.log"
    echo "▶ Generating CDFT with Multiwfn: ${fchk_name}"

    local before_ts=$(date +%s)
    printf "%s" "$MWFN_GEN_CDFT_CMDS" | \
        timeout 600 "$MWFN" "${fchk_name}.fchk" > "$mwfn_log" 2>&1 || true
    sleep 1

    local txt_file
    txt_file=$(find . -maxdepth 1 -name "*.txt" -newermt "@${before_ts}" \
                    ! -name "error_list.txt" 2>/dev/null | head -1 || true)

    if [ -z "$txt_file" ]; then
        echo "❗ CDFT file not found (log: ${mwfn_log})"
        tail -20 "$mwfn_log" | sed 's/^/           /'
        echo "${fchk_name}_CDFT_FAIL" >> "$ERROR_FILE"
        return 1
    fi

    mv "$txt_file" "${fchk_name}_CDFT.txt"
    rm -f "$mwfn_log"
    echo "✔ CDFT written to ${fchk_name}_CDFT.txt"
    return 0
}

# =============================================================================
# 7. Clean up intermediate files and Slurm outputs
#    (called only on the success path)
# =============================================================================
cleanup_after_success() {
    local bases=("N" "N-1" "N-2" "N+1")
    local exts=("gjf" "wfn" "log" "chk")

    for base in "${bases[@]}"; do
        for ext in "${exts[@]}"; do
            local fname="${base}.${ext}"
            if [ -f "$fname" ]; then
                echo "  → Removing ${fname}"
                rm -f "$fname"
            fi
        done
    done

    for job_id in "${JOB_IDS[@]}"; do
        local slurm_file="slurm-${job_id}.out"
        if [ -f "$slurm_file" ]; then
            echo "  → Removing ${slurm_file}"
            rm -f "$slurm_file"
        fi
    done
}

# =============================================================================
# Main program
# =============================================================================
main() {
    > "$ERROR_FILE"

    write_run_g16_sh

    shopt -s nullglob
    local fchk_files=(*.fchk)
    shopt -u nullglob

    if [ ${#fchk_files[@]} -eq 0 ]; then
        echo "❗ No FCHK files found"
        return
    fi

    for fchk in "${fchk_files[@]}"; do
        local fchk_name="${fchk%.fchk}"

        echo ""
        echo "======================================"
        echo "▶ Processing molecule: ${fchk}"
        echo "======================================"

        clean_old_files

        run_multiwfn_generate_gjf "$fchk"

        if ! modify_gjf "$fchk_name"; then
            echo "❗ No GJF files found, skipping"
            echo "${fchk_name}_NO_GJF" >> "$ERROR_FILE"
            continue
        fi
        echo "✔ Calculation settings added"

        submit_gaussian

        # Item 11: do not clean up on the failure path so that
        # N*.log and slurm-*.out are kept for debugging.
        if ! wait_for_wfn "$fchk_name"; then
            echo "⚠ Keeping N*.log / slurm-*.out for debugging; removing WFN and GJF intermediates"
            rm -f N.gjf N-1.gjf N-2.gjf N+1.gjf N.wfn N-1.wfn N-2.wfn N+1.wfn 2>/dev/null || true
            continue
        fi

        if ! run_multiwfn_generate_cdft "$fchk_name"; then
            echo "⚠ Keeping N*.log / slurm-*.out for debugging"
            rm -f N.gjf N-1.gjf N-2.gjf N+1.gjf N.wfn N-1.wfn N-2.wfn N+1.wfn 2>/dev/null || true
            continue
        fi

        echo "🧹 Cleaning intermediate files..."
        cleanup_after_success
    done

    echo ""
    echo "🎉 All FCHK files processed!"
    echo "⚠ See ${ERROR_FILE} for the list of errors"
}

main