#== This module defines functions for executing dREL code ==#
export dynamic_block, define_dict_funcs, derive, get_func_text
export add_definition_func, empty_cache!
export DynamicRelationalContainer, DynamicDDLmRC

import CrystalInfoFramework.get_dictionary
import DataContainer:get_key_datanames, get_value, get_name
import DataContainer:get_raw_value,get_category,has_category

# Configuration
#const drel_grammar = joinpath(@__DIR__,"lark_grammar.ebnf")

#include("lark_grammar.ebnf")

# Create a parser for the dREL grammar. It needs to be contextual
# due to such issues as an isolated variable "j" being parsed as the
# signifier for an imaginary number.

const drel_parser = Serialization.deserialize(joinpath(@__DIR__,"..","deps","drel_grammar_serialised.jli"))

# Parse and output proto-Julia code using Lerche

get_drel_methods(cd::abstract_cif_dictionary) = begin
    has_meth = [n for n in cd if "_method.expression" in keys(n) && get(n,"_definition.scope",["Item"])[1] != "Category"]
    meths = [(n["_definition.id"][1],get_loop(n,"_method.expression")) for n in has_meth]
    println("Found $(length(meths)) methods")
    return meths
end

#== This method creates Julia code from dREL code by
(1) parsing the drel text into a parse tree
(2) traversing the parse tree with a transformer that has been prepared
    with the crucial information to output syntactically-correct Julia code
(3) --blank--
(4) adjusting indices to 1-based
(5) changing any aliases of the main category back to the category name
(6) making sure that all loop-local variables are defined at the entry level
(7) turning set categories into packets
(8) Assigning types to any dictionary items for which this is known
==#

make_julia_code(drel_text::String,dataname::String,dict::abstract_cif_dictionary) = begin
    tree = Lerche.parse(drel_parser,drel_text)
    #println("Rule dict: $(get_rule_dict())")
    transformer = TreeToJulia(dataname,dict)
    proto = transform(transformer,tree)
    tc_alias = transformer.target_category_alias
    #println("Proto-Julia code: ")
    #println(proto)
    #println("Target category aliased to $tc_alias")
    set_categories = get_set_categories(dict)
    parsed = ast_fix_indexing(proto,get_categories(dict),dict)
    println(parsed)
    if !transformer.is_category   #not relevant for category methods
        # catch implicit matrix assignments
        container_type = dict[dataname]["_type.container"][1]
        is_matrix = (container_type == "Matrix" || container_type == "Array")
        ft,parsed = find_target(parsed,tc_alias,transformer.target_object;is_matrix=is_matrix)
        if ft == nothing && !transformer.is_func
            println("WARNING: no target identified for $dataname")
        end
    end
    parsed = fix_scope(parsed)
    parsed = cat_to_packet(parsed,set_categories)  #turn Set categories into packets
    #println("####\n    Assigning types\n####\n")
    parsed = ast_assign_types(parsed,Dict(Symbol("__packet")=>transformer.target_cat),cifdic=dict,set_cats=set_categories,all_cats=get_categories(dict))
end

#== Extract the dREL text from the dictionary, if any
==#
get_func_text(dict::abstract_cif_dictionary,dataname::String,meth_type::String) =  begin
    full_def = dict[dataname]
    func_text = get_loop(full_def,"_method.expression")
    if size(func_text,2) == 0   #nothing
        return ""
    end
    # TODO: allow multiple methods
    eval_meths = func_text[func_text[!,Symbol("_method.purpose")] .== meth_type,:]
    println("Meth size for $dataname is $(size(eval_meths))")
    if size(eval_meths,1) == 0
        return ""
    end
    
    eval_meth = eval_meths[1,Symbol("_method.expression")]
end

define_dict_funcs(c::abstract_cif_dictionary) = begin
    #Parse and evaluate all dictionary-defined functions and store
    func_cat,all_funcs = get_dict_funcs(c)
    for f in all_funcs
        println("Now processing $f")         
        full_def = get_by_cat_obj(c,(func_cat,f))
        entry_name = full_def["_definition.id"][1]
        full_name = lowercase(full_def["_name.object_id"][1])
        func_text = get_loop(full_def,"_method.expression")
        func_text = func_text[Symbol("_method.expression")][1]
        println("Function text: $func_text")
        result = make_julia_code(func_text,entry_name,c)
        println("Transformed text: $result")
        set_func!(c,full_name,result,eval(result))  #store in dictionary
    end
end

#== 

Dynamic datasource

A dynamic datasource will also actively seek to derive missing
information, including calculation of default values.  These values
are cached for efficiency and appear as if they were present in the
original file after they have been calculated once.  To remove these
values, the cache should be emptied.

==#

abstract type DynamicRelationalContainer <: AbstractRelationalContainer end

struct DynamicDDLmRC <: DynamicRelationalContainer
    base::RelationalContainer
    dict::abstract_cif_dictionary #provides dREL functions
    value_cache::Dict{String,Any}
end

DynamicDDLmRC(ds::DataSource,dict::abstract_cif_dictionary) = begin
    DynamicDDLmRC(IsDataSource(),ds,dict)
end

DynamicDDLmRC(ds,dict::abstract_cif_dictionary) = begin
    DynamicDDLmRC(DataSource(ds),ds,dict)
end

DynamicDDLmRC(::IsDataSource,ds,dict) = begin
    DynamicDDLmRC(RelationalContainer(ds,dict),dict,Dict{String,Any}())
end

DynamicDDLmRC(cbwd::cif_container_with_dict) = begin
    DynamicDDLmRC(get_datasource(cbwd),get_dictionary(cbwd))
end

empty_cache!(d::DynamicDDLmRC) = empty!(d.value_cache)

cache_value!(d::DynamicDDLmRC,name,value) = begin
    if haskey(d.value_cache,name)
        println("WARNING: overwriting previously cached value")
        println("Was: $(d.value_cache[name])")
        println("Now: $value")
    end
    d.value_cache[name] = value
end

cache_value!(d::DynamicDDLmRC,name,index,value) = d.value_cache[name][index] = value

get_dictionary(d::DynamicDDLmRC) = d.dict

Base.keys(d::DynamicDDLmRC) = begin
    real_keys = keys(d.base)
    cache_keys = keys(d.value_cache)
    return union(real_keys,cache_keys)
end

Base.show(io::IO,d::DynamicDDLmRC) = begin
    show(io,d.base)
    show(io,d.value_cache)
end

Base.haskey(d::DynamicDDLmRC,s::String) = begin
    return s in keys(d)
end

"""
`s` is always a canonical data name, and the value returned will
be all values for that data name in the same order as the key values.
"""
Base.getindex(d::DynamicDDLmRC,s::String) = begin
    if haskey(d.value_cache,s) return d.value_cache[s] end
    dict = get_dictionary(d)
    cat = find_category(dict,s)
    obj = Symbol(find_object(dict,s))
    return get_category(d,cat)[obj]
end

get_category(d::DynamicDDLmRC,s::String)::DynamicCat = begin
    if has_category(d,s) return DynamicCat(get_category(d.base,s),d)
    elseif lowercase(s) in get_set_categories(get_dictionary(d))
        return DynamicCat(SetCategory(s,d.base,get_dictionary(d)),d)
    else
        return derive_category(d,s)
    end
end

has_category(d::DynamicDDLmRC,s::String) = begin
    return has_category(d.base,s)
end

# Legacy categories may appear without their key, for which
# the DDLm dictionary may provide a method.

#
#  Dynamic Category
#

"""
A dynamic category can derive missing values by reaching out to its parent relational container. Indexing
with a lone value will always assume that it is the value of the key.
"""
struct DynamicCat <: CifCategory
    base::CifCategory
    parent::DynamicRelationalContainer
end

DynamicCat(l::LegacyCategory,p::DynamicRelationalContainer) = begin
    dict = get_dictionary(l)
    keyname = get_keys_for_cat(dict,get_name(l))
    if length(keyname) != 1 #impossible if more than one
        throw(error("Cannot create dynamic category for $(l.name)"))
    end
    keyname = keyname[1]
    if !(has_func(dict,keyname))
        add_new_func(dict,keyname)
    end
    func_code = get_func(dict,keyname)
    key_vals = [Base.invokelatest(func_code,p,r) for r in l]
    # if that worked create a DDLm category
    if length(key_vals) == length(l)
        base_cat = LoopCategory(l,key_vals)
        return DynamicCat(base_cat,p)
    end
    error("Failed to generate key $keyname")
end

Base.show(io::IO,dc::DynamicCat) = begin
    show(io,dc.base)
    show(io,keys(dc.parent))
end

#== CifCategory interface ==#

get_key_datanames(d::DynamicCat) = get_key_datanames(d.base)
get_name(d::DynamicCat) = get_name(d.base)
Base.length(d::DynamicCat) = length(d.base)

Base.getindex(d::DynamicCat,sym::Symbol) = begin
    try
        q = d.base[sym]
    catch KeyError
        s = d.base.object_to_name[sym]
        if haskey(d.parent.value_cache,lowercase(s))
            println("Returning cached value for $s")
            return d.parent.value_cache[lowercase(s)]
        end
        m = derive(d,s)
        accept = any(x->!ismissing(x),m)
        if !accept
            m = get_default(d,s)
        end
        cache_value!(d.parent,lowercase(s), m)
        return m
    end
end

# As we assume the original source data are immutable, any request
# to set an index is routed to the cache

Base.setindex(d::DynamicCat,s::String,v) = begin
    cache_value!(d.value_cache,lowercase(s),v)
end

# Return the value at row n for `colname`
get_value(d::DynamicCat,n::Int,colname::Symbol) = begin
    return get_value(d.base,n,colname)
end

get_dictionary(d::DynamicCat) = get_dictionary(d.parent)

get_raw_value(d::DynamicCat,colname,n) = get_raw_value(d.base,colname,n)

#== Methods for dynamic categories only ==#

# This method actively tries to derive default values but will need the
# entire data block.

get_default(d::DynamicCat,s::String,x) = get_default(d,s)

get_default(d::DynamicCat,s::String) = begin
    db = d.parent
    dict = get_dictionary(db)
    def_vals = CrystalInfoFramework.get_default(dict,s)
    cat_name = find_category(dict,s)
    if !has_category(db,cat_name)
        throw(error("Cannot provide default value for $s,category $cat_name does not exist"))
    end
    target_loop = get_category(db,cat_name)
    if !ismissing(def_vals)
        return [def_vals for i in target_loop]
    end
    # perhaps we can lookup up a default value?
    m = lookup_default(dict,s,d)
    if !ismissing(m) return m end
    # is there a derived default available?
    if !haskey(dict.def_meths,(s,"enumeration.default"))
        add_definition_func!(dict,s)
    end
    func_code = get_def_meth(dict,s,"enumeration.default")
    return [Base.invokelatest(func_code,db,p) for p in target_loop]
end

"""
Derive missing values from a complete collection
"""
derive(b::DynamicRelationalContainer,dataname::String) = begin
    dict = get_dictionary(b)
    if !(has_func(dict,dataname))
        add_new_func(dict,dataname)
    end
    func_code = get_func(dict,dataname)
    target_loop = get_category(b,find_category(dict,dataname))
    [Base.invokelatest(func_code,b,p) for p in target_loop]
end

#==Derive all values in a loop for the given
dataname==#

derive(d::DynamicCat,s::String) = begin
    println("###\n\n    Deriving $s\n#####")
    derive(d.parent,s)
end

#== Per packet derivation

This is called from within a dREL method when an item is
found missing from a packet.
==#
    
derive(p::CatPacket,obj::String,db) = begin
    d = get_category(p)
    dict = get_dictionary(d)
    cat = get_name(d)
    dataname = get_by_cat_obj(dict,(cat,obj))["_definition.id"][1]
    if !(has_func(dict,dataname))
        add_new_func(dict,dataname)
    end
    func_code = get_func(dict,dataname)
    Base.invokelatest(func_code,db,p)
end

#==

Category methods

==#

#==

Category methods create whole new categories

==#

derive_category(b::DynamicRelationalContainer,cat::String) = begin
    dict = get_dictionary(b)
    if !(has_func(dict,cat))
        add_new_func(dict,cat)
    else
        println("Func for $cat already exists")
    end
    func_code = get_func(dict,cat)
    col_vals = Base.invokelatest(func_code,b)
    # Convert to canonical names
    col_vals = (lowercase(get_by_cat_obj(dict,(cat,x.first))["_definition.id"][1]) => x.second for x in col_vals)
    col_vals = Dict(col_vals...)
    println("Raw values for $cat: $col_vals")
    tds = TypedDataSource(col_vals,dict)
    DynamicCat(LoopCategory(cat,tds),b)
end

# For a single row in a packet
get_default(block::DynamicRelationalContainer,cp::CatPacket,obj::Symbol) = begin
    dict = get_dictionary(block)
    mycat = get_name(get_category(cp))
    dataname = get_by_cat_obj(dict,(mycat,String(obj)))["_definition.id"][1]
    def_val = CrystalInfoFramework.get_default(dict,dataname)
    if !ismissing(def_val)
        return def_val
    end
    # Try using enumeration default instead
    def_val = lookup_default(dict,dataname,cp)
    if !ismissing(def_val)
        return def_val
    end
    if !haskey(dict.def_meths,(dataname,"_enumeration.default"))
        add_definition_func!(dict,dataname)
    end
    func_code = get_def_meth(dict,dataname,"enumeration.default")
    debug_info = get_def_meth_txt(dict,dataname,"enumeration.default")
    println("==== Invoking default function for $dataname ===")
    println("Stored code:")
    println(debug_info)
    return Base.invokelatest(func_code,block,cp)
end

add_new_func(d::abstract_cif_dictionary,s::String) = begin
    t = get_func_text(d,s,"Evaluation")
    if t != ""
        r = make_julia_code(t,s,d)
    else
        r = Meta.parse("(a,b) -> missing")
    end
    println("Transformed code for $s:\n")
    println(r)
    set_func!(d,s, r, eval(r))
end

#== Definition methods.

A definition method defines a value for a DDLm attribute that depends
on some aspects of a specific data file. Typically this will
be units or default values.  When a definition method is found,
the particular attribute that it assigns is determined, and the
getindex function for that definition redirected to obtain this
value.

==#

"""
add_definition_func(dictionary,dataname)

Add a method that adjusts the definition of dataname by defining
a DDLm attribute.

TODO: add multiple definition funcs

We do not define any function for those cases in which there is
an attribute defined. This should cause errors if we attempt to
derive an attribute.
"""

const all_set_ddlm = [("units","code"),("enumeration","default")]

add_definition_func!(d::abstract_cif_dictionary,s::String) = begin
    # set defaults
    r = Meta.parse("(a,b) -> missing")
    for (c,o) in all_set_ddlm
        if !haskey(d[s],"_$c.$o")
            set_func!(d,s,"$c.$o",r,eval(r))
        end
    end
    # now add any redefinitions
    t = get_func_text(d,s,"Definition")
    if t != ""
        r = make_julia_code(t,s,d)
        att_name = "not found"
        for (a,targ) in all_set_ddlm
            ft,r = find_target(r,Symbol(a),targ)
            if ft != nothing
                println("Found target: $ft")
                att_name = "$a.$targ"
                break
            end
        end
        println("For dataname $s, attribute $att_name")
        println("Transformed code:\n")
        println(r)
        set_func!(d,s,att_name,r,eval(r))
    end
end

#==   Lookup 

A default value may be tabulated, and some other value in the
current packet is used to index into the table

==#

lookup_default(dict::abstract_cif_dictionary,dataname::String,cp::CatPacket) = begin
    index_name = get(dict[dataname],"_enumeration.def_index_id",[missing])[1]
    if ismissing(index_name) return missing
    end
    object_name = find_object(dict,index_name)
    # Note non-deriving form of getproperty
    println("Looking for $object_name in $(get_name(getfield(cp,:source_cat)))")
    current_val = getproperty(cp,Symbol(object_name))
    print("Indexing $dataname using $current_val to get")
    # Now index into the information
    indexlist = dict[dataname]["_enumeration_default.index"]
    pos = indexin([current_val],indexlist)
    if pos[1] == nothing return missing end
    as_string = dict[dataname]["_enumeration_default.value"][pos[1]]
    println(" $as_string")
    return convert_to_julia(dict,dataname,[as_string])[1]
end

lookup_default(dict::abstract_cif_dictionary,dataname::String,cat::CifCategory) = begin
    [lookup_default(dict,dataname,cp) for cp in cat]
end

#== 

Full dictionary processing

==#

compile_all_methods(dict) = begin
    for k in keys(dict)
        add_new_func(dict,k)
    end
end

