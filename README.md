# CIF_dREL: A dREL to Julia translator

## Introduction

dREL (J. Chem. Inf. Model., 2012, 52 (8), pp 1917–1925
DOI: 10.1021/ci300076w) is a machine-readable language for describing the
relationships between data names defined in a CIF (Crystallographic
Information Framework) dictionary.  Examples of dREL
use can be found in 
(the latest CIF core dictionary)[https://github.com/COMCIFS/cif_core/cif_core.dic].

This package is experimental.  Method and type names are subject to
change, and the eventual final version will be pure Julia, but for now
the (Lark parser for Python)[https://github.com/lark-parser] is used
to transform dREL into Julia syntax based on the 
(dREL EBNF)[https://github.com/COMCIFS/dREL/annotated_grammar.rst]

## Installation

CIF support is provided by the CrystalInfoFramework.jl package. You
will also need to install Python3, and then the lark-parser
Python package (``pip install lark-parser``).  For now, the 
package needs to be installed in development mode, and ``make``
run in the src directory in order to transform the ``jl_transformer.nw``
file into ``jl_transformer.py``.  Utility ``notangle`` needs to
be installed in order to do this.

## Usage

1. After creating an ordinary Cifdic, ``define_dict_funcs(c::Cifdic)`` will
add all dREL functions found in the dictionary to that dictionary as
evaluated Julia definitions.
2. A ``dynamic_block`` is a CIF block that can evaluate missing datanames 
using dREL code found in the dictionary for that dataname, potentially executing long
chains of other evaluations.  The resulting values are **not**
stored in the block or cached.
3. ``derive(d::dynamic_block,s::String)`` will derive the value of dataname
``s`` based on other values in the block and dREL code found in the dictionary
associated with ``d``.

```julia
    p = Cifdic("/home/jrh/COMCIFS/cif_core/cif_core.dic")
    define_dict_funcs(p)    #add dREL Functions to dictionary
    n = NativeCif(joinpath(@__DIR__,"nick1.cif"))
    b = n["saly2_all_aniso"]
    c = assign_dictionary(b,p)
    db = dynamic_block(c) #create a dynamic block
    # 
    # (Re)evaluate an item
    #
    s = derive(db,"_cell.atomic_mass") #derive value
```

``tests/drel_exec.jl`` contains simple demonstrations of how to
make use of dREL scripts found in dictionaries.
