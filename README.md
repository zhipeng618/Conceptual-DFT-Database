# Conceptual-DFT-Database
A standardized, solution-phase conceptual density functional theory (CDFT) descriptor database for 257 water-relevant organic contaminants, computed at the B3LYP/6-311G(d,p)/SMD level.
# Solution-Phase CDFT Descriptor Database for Organic Contaminants
[![DOI](https://zenodo.org/badge/1441806853.svg)](https://doi.org/10.5281/zenodo.23859637)
A standardized, solution-phase conceptual density functional theory (CDFT) descriptor
database for **257 water-relevant organic pollutants**. All descriptors were computed
at the uniform **B3LYP/6-311G(d,p)/SMD** level using Gaussian 16 and Multiwfn 3.8,
with Hirshfeld population analysis.

This repository contains **only the CDFT descriptor database**. Machine-learning
models, training code, and model weights are **not** included.

The database accompanies:

> Luo, Z.; Lin, F.; Zeng, W.; Ye, J.; Zeng, H.; Ho, S.-H.
> *A solution-phase reactivity descriptor database with machine-learning acceleration
> for high-throughput contaminant assessment.* **[Journal]**, [Year].
> DOI: [10.xxxx/xxxxx]

| File | Description |
|---|---|
| `data/cdft_global_descriptors_257.csv` | One row per compound; 18 global CDFT descriptors plus identifiers |
| `CDFT_raw_outputs_257_molecules.zip` | Raw Multiwfn output text files (.txt) containing all computed descriptors for each of the 257 compounds |
---

## 1. Database Overview

- **Compounds:** 257 structurally diverse organic contaminants, including
  pharmaceuticals and personal care products, pesticides, industrial chemicals,
  dyes, surfactants, flame retardants, PFAS, microplastic additives, and
  endocrine-disrupting compounds.
- **Source of initial structures:** PubChem.
- **Charge states:** neutral (N), singly cationic (N−1), doubly cationic (N−2),
  and singly anionic (N+1).
- **Global descriptors:** 18 CDFT global descriptors.
- **Condensed descriptors:** per-atom Fukui functions, dual descriptor, local
  softness, local electrophilicity/nucleophilicity, relative indices, and local
  hyper-softness.
- **Solvation:** geometry optimization and frequency analysis with IEFPCM water;
  single-point energies with SMD water.
- **Population analysis:** Hirshfeld charges.
- **Basis-set exception:** for elements not covered by standard Pople basis sets,
  def2-TZVP was used.

---

## 2. Repository Contents

| File | Description |
|---|---|
| `data/cdft_global_descriptors_257.csv` | One row per compound; 18 global CDFT descriptors plus identifiers |
| `data/cdft_condensed_descriptors_257.csv` | One row per atom; condensed CDFT descriptors plus atom identifiers |
| `data/compound_list.csv` | Compound metadata: internal ID, PubChem CID, name, chemical class |

All CSV files are UTF-8 encoded. Missing or unavailable values are recorded as
empty cells or `NA`.

---

## 3. Download

Clone the repository:

```bash
git clone https://github.com/<USERNAME>/cdft-contaminant-database.git
cd cdft-contaminant-database
Large files, if any, are distributed through GitHub Releases:
https://github.com/<USERNAME>/cdft-contaminant-database/releases/tag/v1.0.0
Raw Gaussian output files (.fchk, .wfn, .log) are not included because of
their large volume. They are available from the corresponding author upon
reasonable request.

4. Quick Start
import pandas as pd

# Global descriptors: one row per compound
global_df = pd.read_csv("data/cdft_global_descriptors_257.csv")
print(global_df.shape)
print(global_df.columns.tolist())

# Compound metadata
compound_df = pd.read_csv("data/compound_list.csv")
print(compound_df.head())

# Condensed descriptors: one row per atom
condensed_df = pd.read_csv("data/cdft_condensed_descriptors_257.csv")
print(condensed_df.head())

Column	Description	Unit
compound_id	Internal compound identifier	—
pubchem_cid	PubChem CID	—
name	Compound name	—
E_HOMO(N)	HOMO energy of the neutral state	eV
E_LUMO(N)	LUMO energy of the neutral state	eV
E_H-L_Gap(N)	HOMO–LUMO gap of the neutral state	eV
E_HOMO(N+1)	HOMO energy of the singly anionic state	eV
E_HOMO(N-1)	HOMO energy of the singly cationic state	eV
E_HOMO(N-2)	HOMO energy of the doubly cationic state	eV
VIP1	First vertical ionization potential	eV
VIP2	Second vertical ionization potential	eV
VEA1	First vertical electron affinity	eV
chi_M	Mulliken electronegativity	eV
mu	Chemical potential	eV
eta	Chemical hardness	eV
S	Softness	eV⁻¹
S2	Hypersoftness	eV⁻²
omega	Electrophilicity index	eV
N	Nucleophilicity index	eV
omega_cubic	Cubic electrophilicity index	eV
epsilon	Electrophilic descriptor	eV

4.1

---

## 4. Computational Workflow (Reproducibility)

### 4.1 Prerequisites

- Gaussian 16 (Revision C.01)
- Multiwfn 3.8 (dev), non-GUI Linux build
- Slurm workload manager
- Python ≥ 3.6.8
- VMD (optional, for isosurface visualization)

Install Python dependencies:

```bash
pip install -r requirements.txt

4.2 Stage I–II: Geometry optimization and frequency analysis
bash SDF_to_opt.sh
For each SDF file, the script calls Multiwfn to generate a Gaussian input,
inserts %nprocshared, %mem, %chk, submits a Slurm array job, converts
the checkpoint to FCHK with formchk, and logs failures in error_list.txt.

4.3 Stage III–IV: Four charge states and CDFT extraction
bash fchk_to_cdft.sh
This generates Gaussian inputs for N, N−1, N−2, and N+1, submits them to
Slurm, waits for the four .wfn files, and invokes Multiwfn to compute global
and condensed CDFT descriptors. Output is renamed to
<molecule>_CDFT.txt.

4.4 Stage V: Descriptor aggregation
python CDFT.py

Parses all <molecule>_CDFT.txt files and writes a timestamped Excel
workbook extracted_parameters_YYYYMMDD_HHMMSS.xlsx with one row per molecule
and one column per descriptor. Missing values are reported in the summary.


5. Computational Protocol Summary
Software: Gaussian 16 (Revision C.01); Multiwfn 3.8 (dev).

Geometry optimization and frequency analysis: B3LYP/6-311G(d,p) with
IEFPCM water. The absence of imaginary frequencies confirmed genuine local
minima.

Single-point energies: B3LYP/6-311G(d,p) with SMD water for the four
charge states N, N−1, N−2, and N+1.

Descriptor extraction: Multiwfn built-in CDFT framework based on
Hirshfeld population analysis.

Workflow: automated Bash/Python pipeline for input generation, Slurm job
submission, wavefunction parsing, consistency checking, and descriptor
aggregation.

Benchmarks: basis-set sensitivity, functional dependence across 0–100%
Hartree–Fock exchange, and gas-phase versus SMD-water comparisons are reported
in the manuscript and Supporting Information.

6. Usage Notes and Limitations
Global CDFT descriptors depend on the exchange–correlation functional and
solvation model. Values in this database are internally consistent at
B3LYP/6-311G(d,p)/SMD but should not be mixed with values computed at other
levels without calibration.

Global descriptors derived from charged-state total energies, such as VIP1,
VIP2, and VEA1, are sensitive to solvation. Use the solution-phase values
provided here for aqueous applications.

Condensed local descriptors are more robust to functional and solvation
choices than global descriptors, but site rankings near the ~20–25% HF
exchange threshold can reverse for some molecules. Cross-validation with at
least two functionals is recommended for critical site predictions.

The database is intended for screening, prioritization, and QSAR model
development. Quantitative mechanistic conclusions should be validated against
experimental data or higher-level calculations.
