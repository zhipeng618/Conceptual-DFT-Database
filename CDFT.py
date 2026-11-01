#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
从 Multiwfn 输出的 *_CDFT.txt 文件中提取 CDFT 描述符及轨道能量参数，
生成汇总 Excel 表格。

改动（相对上一版）：
   ❾ 修正 'Hardness (=fundamental gap)' 的别名（去掉多余的 re.escape）
   ❿ glob 改为 *_CDFT.txt，避免误读 error_list.txt
   ⓫ VALUE_PATTERN 支持整数与科学计数法
   ⓬ Excel 中文件名去掉 "_CDFT" 后缀
   ⓭ Excel 文件名保留时间戳，避免多次运行互相覆盖
"""
import os
import glob
import re
import pandas as pd
from datetime import datetime

# ==================== 参数映射表 ====================
PARAM_MAPPING = {
    'Chemical potential': ['Chemical potential'],
    'Cubic electrophilicity index (w_cubic)': [
        'Cubic electrophilicity index',
        'w_cubic',
        'w cubic'
    ],
    'Electrophilic descriptor (epsilon)': [
        'Electrophilic descriptor',
        'epsilon'
    ],
    'Electrophilicity index': ['Electrophilicity index'],
    'First vertical EA': ['First vertical EA'],
    'First vertical IP': ['First vertical IP'],
    # ❾ 修正：原版写法 r'Hardness \(=fundamental gap\)' 经过 re.escape 后
    #    匹配的是字面 'Hardness \\(=fundamental gap\\)'，与 Multiwfn 输出不符。
    #    直接用未转义的完整字符串 + 短别名兜底。
    'Hardness (=fundamental gap)': [
        'Hardness (=fundamental gap)',
        'Hardness'
    ],
    'Mulliken electronegativity': ['Mulliken electronegativity'],
    'Nucleophilicity index': ['Nucleophilicity index'],
    'Second vertical IP': ['Second vertical IP'],
    'Softness': ['Softness'],
    'Softness^2': ['Softness^2'],
    # ---------- 轨道能量相关 ----------
    'HOMO-LUMO Gap (N)': [
        'E_HOMO-LUMO Gap (N)',
        'HOMO-LUMO gap'
    ],
    'E_HOMO(N)':    ['E_HOMO(N)'],
    'E_HOMO(N+1)':  ['E_HOMO(N+1)'],
    'E_HOMO(N-1)':  ['E_HOMO(N-1)'],
    'E_HOMO(N-2)':  ['E_HOMO(N-2)'],
    'E_LUMO(N)':    ['E_LUMO(N)']
}

# ==================== 正则工具 ====================
# 按长度降序排列所有别名，长关键词优先匹配
all_aliases = sorted(
    (kw for aliases in PARAM_MAPPING.values() for kw in aliases),
    key=lambda x: -len(x)
)

KEYWORD_REGEX = re.compile(
    r'(' + '|'.join(re.escape(kw) for kw in all_aliases) + r')',
    re.IGNORECASE
)

# ⓫ 支持整数、小数、科学计数法（如 -7.5、0、-7.5e-1）
VALUE_PATTERN = re.compile(
    r'([-+]?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)\s*eV',
    re.IGNORECASE
)


# ==================== 核心提取函数 ====================
def extract_records(input_file):
    results = {}
    try:
        with open(input_file, encoding='utf-8', errors='ignore') as f:
            lines = f.readlines()

        for line in lines:
            kw_match = KEYWORD_REGEX.search(line)
            if not kw_match:
                continue

            values = VALUE_PATTERN.findall(line)
            if not values:
                continue

            try:
                value = float(values[-1])
            except ValueError:
                continue

            found_kw = kw_match.group(1).strip()
            found_kw_lower = found_kw.lower()

            # 精确匹配别名（忽略大小写）
            for std_name, aliases in PARAM_MAPPING.items():
                if any(kw.lower() == found_kw_lower for kw in aliases):
                    results[std_name] = value
                    break

    except Exception as e:
        print(f"[WARN] Processing {os.path.basename(input_file)} failed: {str(e)}")

    return results


# ==================== 生成 Excel ====================
def build_excel(directory="."):
    # ❿ 只读取 *_CDFT.txt，避免误读 error_list.txt
    txt_files = sorted(glob.glob(os.path.join(directory, "*_CDFT.txt")))
    if not txt_files:
        print("[ERROR] No *_CDFT.txt files found in the current directory.")
        return

    all_data = {}
    processed = 0
    skipped = 0

    for path in txt_files:
        filename = os.path.splitext(os.path.basename(path))[0]
        # ⓬ 去掉 "_CDFT" 后缀，Excel 中只显示分子名
        if filename.endswith("_CDFT"):
            filename = filename[:-5]

        records = extract_records(path)
        if records:
            all_data[filename] = records
            processed += 1
        else:
            print(f"[SKIP] {os.path.basename(path)}: No parameters extracted.")
            skipped += 1

    if not all_data:
        print("[ERROR] No valid data extracted from any file.")
        return

    std_columns = list(PARAM_MAPPING.keys())
    df = pd.DataFrame.from_dict(all_data, orient='index')
    for col in std_columns:
        if col not in df.columns:
            df[col] = None
    df = df[std_columns]
    df.reset_index(inplace=True)
    df.rename(columns={'index': 'File'}, inplace=True)
    ordered_cols = ['File'] + std_columns
    df = df[ordered_cols]

    # ⓭ 文件名带时间戳
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    output_path = os.path.join(directory, f"extracted_parameters_{timestamp}.xlsx")
    df.to_excel(output_path, index=False)

    print(f"[OK] Extraction complete! Total files: {len(txt_files)}")
    print(f"     Successfully extracted: {processed} files")
    if skipped:
        print(f"     Skipped: {skipped} files")
    print(f"[SAVED] Result: {output_path}")

    print("\n[SUMMARY] Parameter extraction statistics:")
    for param in std_columns:
        count = sum(1 for data in all_data.values() if param in data)
        print(f"  {param}: {count}/{processed} files")


if __name__ == "__main__":
    build_excel()