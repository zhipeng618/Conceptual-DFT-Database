#!/bin/bash
# =============================================================================
# fchk_to_cdft.sh
# 阶段 2：FCHK -> 4 GJF（N/N-1/N-2/N+1）-> 4 Gaussian 单点 -> CDFT 文本
#
# 改动（相对上一版）：
#   ❶ clean_old_files 只删明确中间文件名，不再 rm -f N*（避免误删输入）
#   ❷ run_g16.sh 加 set -e + --mem=20G，避免失败作业被误判为成功
#   ❸ rm -rf /tmp/... 加变量检查，避免空变量删 /tmp
#   ❼ CDFT 文本用 find -newermt 精确定位，避免误抓旧 txt
#   ❽ modify_gjf 只替换第一个 # 路由行
#   ❾ Multiwfn 输出保留到日志文件
#   ❿ 每次 sbatch 带 --job-name，squeue 里可区分
#   ⓫ 失败时保留 N*.log 和 slurm-*.out
#   ⓬ GAUSS_SCRDIR 改为用户专属 scratch 目录
# =============================================================================
set -e

# ---------- 用户配置 ----------
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
# 0. 清理上一轮残留（❶ 明确文件名，不用 N* 通配）
# =============================================================================
clean_old_files() {
    rm -f N.gjf N-1.gjf N-2.gjf N+1.gjf \
          N.wfn N-1.wfn N-2.wfn N+1.wfn \
          N.log N-1.log N-2.log N+1.log \
          N.chk N-1.chk N-2.chk N+1.chk 2>/dev/null || true
}

# =============================================================================
# 1. Multiwfn 生成 4 个 GJF
# =============================================================================
run_multiwfn_generate_gjf() {
    local fchk="$1"
    local mwfn_log="./mwfn_gjf_${fchk%.fchk}.log"
    echo "▶ Multiwfn 生成 GJF: ${fchk}"
    printf "%s" "$MWFN_GEN_GJF_CMDS" | \
        timeout 300 "$MWFN" "$fchk" > "$mwfn_log" 2>&1 || true
    echo "✔ Multiwfn GJF 生成完成（日志: ${mwfn_log}）"
    sleep 0.5
}

# =============================================================================
# 2. 修改 GJF（❽ 只替换第一个 #）
# =============================================================================
modify_gjf() {
    local gjf_names=("N.gjf" "N-1.gjf" "N-2.gjf" "N+1.gjf")
    local exist=1

    for gjf in "${gjf_names[@]}"; do
        [ -f "$gjf" ] || continue
        exist=0
        echo "  → 修改 ${gjf}"

        local base="${gjf%.gjf}"
        local tmp
        tmp=$(mktemp)

        {
            echo "%nprocshared=${NPROC}"
            echo "%mem=${MEM}"
            echo "%chk=${base}.chk"
        } > "$tmp"

        # 只替换第一个 '#' 开头的行，其余 '#...' 保留原样
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
# 3. 写 run_g16.sh（❷ set -e + mem；❸ 变量检查；⓬ 独立 scratch）
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
    echo "✔ 生成 run_g16.sh"
}

# =============================================================================
# 4. sbatch 提交 4 个 Gaussian（❿ 带 --job-name）
# =============================================================================
submit_gaussian() {
    local gjf_list=("N.gjf" "N-1.gjf" "N-2.gjf" "N+1.gjf")
    JOB_IDS=()

    for gjf in "${gjf_list[@]}"; do
        [ -f "$gjf" ] || continue
        echo "  → sbatch 提交：${gjf}"

        local output
        output=$(sbatch --export=INPUTFILE="$gjf" \
                        --job-name="g16_${gjf%.gjf}" \
                        run_g16.sh 2>&1)

        local job_id
        job_id=$(echo "$output" | grep -oE 'Submitted batch job [0-9]+' | grep -oE '[0-9]+' || true)

        if [ -n "$job_id" ]; then
            JOB_IDS+=("$job_id")
            echo "    作业 ID: ${job_id}"
        else
            echo "    警告: 未能提取作业ID，输出：${output}"
        fi
    done
}

# =============================================================================
# 5. 等待 4 个 WFN 生成
# =============================================================================
wait_for_wfn() {
    local fchk_name="$1"
    local wfn_files=("N.wfn" "N-1.wfn" "N-2.wfn" "N+1.wfn")

    echo "⏳ 等待 WFN 文件生成（最长 $((MAX_WAIT/60)) 分钟）..."
    local elapsed=0

    while [ $elapsed -lt $MAX_WAIT ]; do
        local all_exist=1
        for f in "${wfn_files[@]}"; do
            if [ ! -f "$f" ]; then
                all_exist=0; break
            fi
        done

        if [ $all_exist -eq 1 ]; then
            echo "✔ 所有 WFN 文件已生成"
            return 0
        fi

        sleep $SLEEP_INTERVAL
        elapsed=$((elapsed + SLEEP_INTERVAL))
    done

    echo "❗ ${fchk_name} 的 WFN 文件未生成，超时"
    echo "${fchk_name}_WFN_TIMEOUT" >> "$ERROR_FILE"
    return 1
}

# =============================================================================
# 6. Multiwfn 生成 CDFT 文本（❼ 用 find -newermt 精确定位）
# =============================================================================
run_multiwfn_generate_cdft() {
    local fchk_name="$1"
    local mwfn_log="./mwfn_cdft_${fchk_name}.log"
    echo "▶ Multiwfn 生成 CDFT: ${fchk_name}"

    local before_ts=$(date +%s)
    printf "%s" "$MWFN_GEN_CDFT_CMDS" | \
        timeout 600 "$MWFN" "${fchk_name}.fchk" > "$mwfn_log" 2>&1 || true
    sleep 1

    local txt_file
    txt_file=$(find . -maxdepth 1 -name "*.txt" -newermt "@${before_ts}" \
                    ! -name "error_list.txt" 2>/dev/null | head -1 || true)

    if [ -z "$txt_file" ]; then
        echo "❗ 未找到 CDFT 文件（日志: ${mwfn_log}）"
        tail -20 "$mwfn_log" | sed 's/^/           /'
        echo "${fchk_name}_CDFT_FAIL" >> "$ERROR_FILE"
        return 1
    fi

    mv "$txt_file" "${fchk_name}_CDFT.txt"
    rm -f "$mwfn_log"
    echo "✔ CDFT 已生成 → ${fchk_name}_CDFT.txt"
    return 0
}

# =============================================================================
# 7. 清理中间文件和 Slurm 输出（仅成功路径调用）
# =============================================================================
cleanup_after_success() {
    local bases=("N" "N-1" "N-2" "N+1")
    local exts=("gjf" "wfn" "log" "chk")

    for base in "${bases[@]}"; do
        for ext in "${exts[@]}"; do
            local fname="${base}.${ext}"
            if [ -f "$fname" ]; then
                echo "  → 删除 ${fname}"
                rm -f "$fname"
            fi
        done
    done

    for job_id in "${JOB_IDS[@]}"; do
        local slurm_file="slurm-${job_id}.out"
        if [ -f "$slurm_file" ]; then
            echo "  → 删除 ${slurm_file}"
            rm -f "$slurm_file"
        fi
    done
}

# =============================================================================
# 主程序
# =============================================================================
main() {
    > "$ERROR_FILE"

    write_run_g16_sh

    shopt -s nullglob
    local fchk_files=(*.fchk)
    shopt -u nullglob

    if [ ${#fchk_files[@]} -eq 0 ]; then
        echo "❗ 未找到 FCHK 文件"
        return
    fi

    for fchk in "${fchk_files[@]}"; do
        local fchk_name="${fchk%.fchk}"

        echo ""
        echo "======================================"
        echo "▶ 正在处理分子: ${fchk}"
        echo "======================================"

        clean_old_files

        run_multiwfn_generate_gjf "$fchk"

        if ! modify_gjf "$fchk_name"; then
            echo "❗ 无 gjf 文件，跳过"
            echo "${fchk_name}_NO_GJF" >> "$ERROR_FILE"
            continue
        fi
        echo "✔ 已添加计算设置"

        submit_gaussian

        # ⓫ 失败分支不清理，保留 N*.log 和 slurm-*.out
        if ! wait_for_wfn "$fchk_name"; then
            echo "⚠ 保留 N*.log / slurm-*.out 供排查；清理 WFN 和 GJF 中间文件"
            rm -f N.gjf N-1.gjf N-2.gjf N+1.gjf N.wfn N-1.wfn N-2.wfn N+1.wfn 2>/dev/null || true
            continue
        fi

        if ! run_multiwfn_generate_cdft "$fchk_name"; then
            echo "⚠ 保留 N*.log / slurm-*.out 供排查"
            rm -f N.gjf N-1.gjf N-2.gjf N+1.gjf N.wfn N-1.wfn N-2.wfn N+1.wfn 2>/dev/null || true
            continue
        fi

        echo "🧹 清理中间文件…"
        cleanup_after_success
    done

    echo ""
    echo "🎉 全部 FCHK 文件处理完成！"
    echo "⚠ 错误文件列表见 ${ERROR_FILE}"
}

main