# CIF_dREL: A dREL to Julia translator

## Introduction

dREL (J. Chem. Inf. Model., 2012, 52 (8), pp 1917–1925
DOI: 10.1021/ci300076w) is a machine-readable language for describing the
relationships between data names defined in a CIF (Crystallographic
Information Framework) dictionary.  Examples of dREL
use can be found in 
[the latest CIF core dictionary](https://github.com/COMCIFS/cif_core/cif_core.dic).

This package is experimental.  Method and type names are subject to
change. It is likely to run a lot faster in the future as optimisations
are implemented.  Suggestions on speed improvement and new functionality
are welcome.

## Installation

Install Julia.  At the Pkg prompt (ie after entering `]`) type
`add CIF_dREL`.  Simply put `using CIF_dREL` at the top of any
Julia code that uses methods from this package.

Note that CIF dictionary support is provided by the 
[CrystalInfoFramework](https://github.com/jamesrhester/CrystalInfoFramework.jl) 
package, which will be installed together with `CIF_dREL`.

Please advise of any difficulties in installation so that either these
instructions or the installation setup can be improved.

## Note

The `deps` directory contains a short script to pre-build the dREL grammar. When
changing the grammar this should be re-run. There is no harm in executing
this script after installation: `julia build.jl`

