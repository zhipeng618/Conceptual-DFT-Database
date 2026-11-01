#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Extract conceptual DFT (CDFT) descriptors and orbital-energy parameters
from Multiwfn output files (*_CDFT.txt) and write a summary Excel workbook.

"""
import os
import glob
import re
import pandas as pd
from datetime import datetime

# ==================== Parameter mapping table ====================
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
    # Item 9: the previous version used r'Hardness \(=fundamental gap\)',
    # which after re.escape matched the literal string
    # 'Hardness \\(=fundamental gap\\)' and therefore never matched the
    # Multiwfn output. Use the unescaped full string plus a short alias
    # as a fallback instead.
    'Hardness (=fundamental gap)': [
        'Hardness (=fundamental gap)',
        'Hardness'
    ],
    'Mulliken electronegativity': ['Mulliken electronegativity'],
    'Nucleophilicity index': ['Nucleophilicity index'],
    'Second vertical IP': ['Second vertical IP'],
    'Softness': ['Softness'],
    'Softness^2': ['Softness^2'],
    # ---------- Orbital energies ----------
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

# ==================== Regex utilities ====================
# Sort all aliases by length in descending order so that longer keywords
# are matched before shorter ones.
all_aliases = sorted(
    (kw for aliases in PARAM_MAPPING.values() for kw in aliases),
    key=lambda x: -len(x)
)

KEYWORD_REGEX = re.compile(
    r'(' + '|'.join(re.escape(kw) for kw in all_aliases) + r')',
    re.IGNORECASE
)

# Item 11: supports integers, decimals, and scientific notation
# (e.g., -7.5, 0, -7.5e-1).
VALUE_PATTERN = re.compile(
    r'([-+]?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)\s*eV',
    re.IGNORECASE
)


# ==================== Core extraction function ====================
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

            # Exact alias matching (case-insensitive).
            for std_name, aliases in PARAM_MAPPING.items():
                if any(kw.lower() == found_kw_lower for kw in aliases):
                    results[std_name] = value
                    break

    except Exception as e:
        print(f"[WARN] Processing {os.path.basename(input_file)} failed: {str(e)}")

    return results


# ==================== Excel generation ====================
def build_excel(directory="."):
    # Item 10: only read *_CDFT.txt to avoid accidentally reading
    # files such as error_list.txt.
    txt_files = sorted(glob.glob(os.path.join(directory, "*_CDFT.txt")))
    if not txt_files:
        print("[ERROR] No *_CDFT.txt files found in the current directory.")
        return

    all_data = {}
    processed = 0
    skipped = 0

    for path in txt_files:
        filename = os.path.splitext(os.path.basename(path))[0]
        # Item 12: strip the "_CDFT" suffix so only the molecule name
        # appears in the Excel sheet.
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

    # Item 13: timestamped output file name.
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