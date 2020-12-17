module dRELTools 

using CrystalInfoFramework
using CrystalInfoFramework.DataContainer
using DataFrames
using Lerche
using Serialization

export TreeToJulia   #for testing

#== This module defines functions for executing dREL code ==#
export dynamic_block, define_dict_funcs!, derive
export add_definition_func!, empty_cache!
export DynamicRelationalContainer, DynamicDDLmRC, DynamicCat
export find_namespace
export drelvector,to_julia_array,drel_strip,drel_split,DrelTable
export get_category,make_julia_code

import CrystalInfoFramework.DataContainer:get_key_datanames, get_value, get_name
import CrystalInfoFramework.DataContainer:get_category, has_category, get_data, get_dictionary
import CrystalInfoFramework.DataContainer:select_namespace,get_namespaces

import Base:keys,haskey,show,getindex,setindex!,values,iterate,length

include("lark_grammar.ebnf")
include("jl_transformer.jl")
include("drel_execution.jl")
include("drel_ast.jl")
include("drel_runtime.jl")

end # module
