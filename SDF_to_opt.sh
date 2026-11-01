#!/bin/bash
#SBATCH --output=G16_%A_%a.log
#SBATCH --error=G16_%A_%a.err
#SBATCH -p cpu
#SBATCH -N 1
#SBATCH --ntasks-per-node=20
#SBATCH --mem=20G
# 注意：--array 由脚本自身在登录节点提交时用 sbatch --array=1-N 动态指定。

# =============================================================================
# submit_all.sh
# 阶段 1：SDF -> GJF (Multiwfn) -> sbatch -> Gaussian opt freq -> .log + .fchk
#
# 改动（相对上一版）：
#   ❹ 修复 set -e 下 g16 失败时 $? 捕获不到的问题
#   ❿ g16 改为显式重定向，与 run_g16.sh 统一
#   ⓫ %chk 检查改为匹配行首可选空白
#   ⓬ 去掉任务中删除 Slurm 输出（避免与 Slurm 写入冲突）
# =============================================================================
set -e

# ---------- 用户配置 ----------
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
# 注入计算设置
# =============================================================================
inject_settings() {
    local gjf_file="$1"
    local base
    base=$(basename "$gjf_file" .gjf)

    grep -q "^[[:space:]]*%nprocshared=" "$gjf_file" || sed -i "1i %nprocshared=${NPROC}" "$gjf_file"
    grep -q "^[[:space:]]*%mem="         "$gjf_file" || sed -i "1i %mem=${MEM}"          "$gjf_file"
    grep -q "^[[:space:]]*%chk="         "$gjf_file" || sed -i "1i %chk=${base}.chk"    "$gjf_file"

    # 只替换第一个 '#' 路由行
    awk -v route="$ROUTE_LINE" '
        BEGIN { done = 0 }
        /^[[:space:]]*#/ && !done { print route; done = 1; next }
        { print }
    ' "$gjf_file" > "${gjf_file}.tmp" && mv "${gjf_file}.tmp" "$gjf_file"

    if ! grep -q "^[[:space:]]*#P" "$gjf_file"; then
        echo "    WARNING: ${gjf_file} 中没有找到 '#P' 路由行"
    fi
}

# =============================================================================
# 模式 A：登录节点 —— 生成 GJF 并提交自身
# =============================================================================
run_prepare() {
    echo "########## prepare mode (login node) ##########"

    mkdir -p "$GJF_DIR"
    > "$INPUT_LIST"

    shopt -s nullglob
    sdf_files=("$SDF_DIR"/*.sdf "$SDF_DIR"/*.SDF)
    shopt -u nullglob

    if [ ${#sdf_files[@]} -eq 0 ]; then
        echo "ERROR: 当前目录没有 .sdf 文件"
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
            echo "    -> 失败！realpath 无效: '${sdf_abs}'"
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
            echo "    -> OK，已加入 ${INPUT_LIST}"
            if [ "${KEEP_MWFN_LOG:-0}" -eq 0 ]; then
                rm -f "$log_out"
            fi
        else
            echo "    -> 失败！查看 ${log_out} 末尾"
            tail -30 "$log_out" | sed 's/^/           /'
        fi
    done

    local N
    N=$(wc -l < "$INPUT_LIST")
    if [ "$N" -eq 0 ]; then
        echo "ERROR: ${INPUT_LIST} 为空，取消提交"
        exit 1
    fi

    echo ""
    echo "=============================================="
    echo "共 ${N} 个 gjf 就绪，提交数组作业 1-${N}"
    echo "=============================================="

    local self_abs
    self_abs=$(realpath "$0")
    sbatch --array=1-${N} \
           --export=ALL,GJF_DIR="${GJF_DIR}" \
           "$self_abs"
}

# =============================================================================
# 模式 B：计算节点 —— 跑一个分子的 Gaussian
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

    # ⓫ 允许行首空白
    if ! grep -q "^[[:space:]]*%chk=" "${InputfileName}${INPUT_SUFFIX}"; then
        sed -i "1s/^/%chk=${InputfileName}.chk\n/" "${InputfileName}${INPUT_SUFFIX}"
    fi

    echo "Starting G16 for ${InputfileName} at $(date)"

    module load gauss/16

    # ❹ 用 || 捕获退出码，避免 set -e 提前退出
    # ❿ 显式重定向
    local G16_EXIT_CODE=0
    g16 < "${InputfileName}${INPUT_SUFFIX}" > "${InputfileName}.log" 2>&1 || G16_EXIT_CODE=$?

    echo "Finished (exit=${G16_EXIT_CODE}) at $(date)"

    if [ ${G16_EXIT_CODE} -eq 0 ] && [ -f "${InputfileName}.chk" ]; then
        formchk "${InputfileName}.chk" "${InputfileName}.fchk"
        cp "${InputfileName}.log"  "${MAIN_WORKDIR}/"
        cp "${InputfileName}.fchk" "${MAIN_WORKDIR}/"
    else
        echo "Error: G16 failed or no .chk (exit=${G16_EXIT_CODE})"
        # 保留 .log 供排查
        cp "${InputfileName}.log" "${MAIN_WORKDIR}/" 2>/dev/null || true
        cd "${MAIN_WORKDIR}" || exit 1
        rm -rf "${TASK_DIR}" "${GAUSS_SCRDIR}"
        exit 1
    fi

    cd "${MAIN_WORKDIR}" || exit
    rm -rf "${TASK_DIR}" "${GAUSS_SCRDIR}"

    # ⓬ 不删除 Slurm 输出，便于排查

    echo "========== Done: ${InputfileName} =========="
}

# =============================================================================
# 入口
# =============================================================================
if [ -z "${SLURM_ARRAY_TASK_ID:-}" ]; then
    run_prepare
else
    run_gaussian
fi