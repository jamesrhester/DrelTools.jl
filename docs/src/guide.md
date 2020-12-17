# Guide to using CIF_dREL

## Introduction

`CIF_dREL` provides methods and types that take advantage of code
embedded in CIF dictionaries (ontologies) that describes mathematical
relationships between data names defined in those ontologies. To
do this, it translates those methods into Julia code that can be
executed, for example, to find or check missing values.

Before reading the following, you should be familiar with 
the `CrystalInfoFramework.jl` documentation for working with
CIF files and dictionaries.

## Usage

### Preparation

Read in the CIF dictionary, and prepare any dREL *functions*
defined in the dictionary:

```julia
dict = DDLm_Dictionary("cif_core.dic")
define_dict_funcs!(dict)    #add dREL Functions to dictionary
```

In DDLm, dREL functions are defined in categories that have
`_definition.class` of `Function`. They should not be confused with
dREL *methods*, which are associated with particular data names
or categories.

The `DDLm_Dictionary` type used above is defined in
`CrystalInfoFramework.jl`. `DDL2_Dictionary`s may also be used,
but only methods of type `dREL` will be recognised.

[`define_dict_funcs!`](@ref) will
process all dREL functions found in the dictionary and make
them available to dREL methods. They can be inspected via the 
`CrystalInfoFramework` `get_dict_func` method.

dREL methods operate on any source of data that returns the correct
data types and has a relational structure.  We use a 
`CrystalInfoFramework` `TypedDataSource` created from a CIF block:

```julia
n = Cif("nick1.cif")
b = n["saly2_all_aniso"] #select a data block
t = TypedDataSource(b,dict)
```

The final step is to create a [`DynamicDDLmRC`](@ref) type that allows new values
to be derived given a dictionary describing the mathematical relationships:

```julia
dd = DynamicDDLmRC(t,dict)
```

Note that in this case the dictionary used for typing, and the dictionary
used for dREL methods and to create the relational structure, are the same
dictionary.

### Derivation

A request for a data name whose value is not found in the `DynamicDDLmRC` object will
trigger derivation:

```julia
dd["_cell.volume"]
```

A whole category may also be computed if the values needed for the calculation
are present:

```julia
dd["geom_bond"]
```

Note that, as computations (currently) can take significant time, results are
cached. To clear this cache, call [`empty_cache!`](@ref).

`test/drel_exec.jl` contains demonstrations of how to make use of dREL
scripts found in dictionaries.

### Namespaces

Advanced users may have `DataSource`s with data names from different namespaces.
Provide a further `nspace` argument to disambiguate in this case:

```julia
dd["_cell.volume","CifCore"]
```

## Translating dREL

If you wish simply to transform some dREL code into Julia, you can use
[`make_julia_code`](@ref).  You will need to provide the dREL fragment,
the data name it is associated with (or category name), and the CIF
dictionary. The returned `Expr` will need to be evaluated and assigned
to a variable before it can be executed. The arguments to the
returned function are the datablock and a single row of the category
to which the defined value belongs.

```julia
dreltext = """
      With c  as  cell
 
      _cell.volume =  c.vector_a * ( c.vector_b ^ c.vector_c )

"""
make_julia_code(dreltext,"_cell.volume",dict)

# output

function (__datablock::DynamicRelationalContainer, __packet::CatPacket)
    #= /home/jrh/programs/CIF/dRELTools.jl/src/drel_ast.jl:397 =#
    __dict = missing
    c = missing
    __dreltarget = missing
    #= /home/jrh/programs/CIF/dRELTools.jl/src/jl_transformer.jl:120 =#
    #= /home/jrh/programs/CIF/dRELTools.jl/src/jl_transformer.jl:122 =#
    begin
        __dict = get_dictionary(__datablock, "CifCore")
        begin
            c = __packet
            #= /home/jrh/programs/CIF/dRELTools.jl/src/jl_transformer.jl:651 =#
            begin
                __dreltarget = drel_property_access(c, "vector_a", __datablock)::drelvector * cross(drel_property_access(c, "vector_b", __datablock)::drelvector, drel_property_access(c, "vector_c", __datablock)::drelvector)
            end
        end
        return __dreltarget
    end
end

```
