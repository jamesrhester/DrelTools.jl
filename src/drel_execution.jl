#== This module defines functions for executing dREL code ==#
export dynamic_block, define_dict_funcs, derive, get_func_text
export add_definition_func, empty_cache!
export DynamicRelationalContainer, DynamicDDLmRC, DynamicCat

import DataContainer:get_key_datanames, get_value, get_name
import DataContainer:get_category, has_category, get_data, get_dictionary

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
    data
    dict::Dict{String,abstract_cif_dictionary} #provides dREL functions
    value_cache::Dict{String,Dict{String,Any}} #namespace indexed
end

DynamicDDLmRC(ds::DataSource,dict::abstract_cif_dictionary) = begin
    DynamicDDLmRC(IsDataSource(),ds,dict)
end

DynamicDDLmRC(ds,dict::abstract_cif_dictionary) = begin
    DynamicDDLmRC(DataSource(ds),ds,dict)
end

DynamicDDLmRC(::IsDataSource,ds,dict) = begin
    nspace = get_dic_namespace(dict)
    DynamicDDLmRC(ds,Dict(nspace=>dict),Dict(nspace=>Dict{String,Any}()))
end

DynamicDDLmRC(r::AbstractRelationalContainer) = begin
    nspaces = get_namespaces(r)
    d = Dict{String,Dict{String,Any}}()
    for n in nspaces
        d[n] = Dict()
    end
    DynamicDDLmRC(r,get_dicts(r),d)
end

empty_cache!(d::DynamicDDLmRC) = begin
    for k in keys(d.value_cache)
        empty!(d.value_cache[k])
    end
end

cache_value!(d::DynamicDDLmRC,name,value) = begin
    nspace = first(d.value_cache).first
    cache_value!(d,nspace,name,value)
end

cache_value!(d::DynamicDDLmRC,nspace,name,value) = begin
    if haskey(d.value_cache[nspace],name)
        println("WARNING: overwriting previously cached value")
        println("Was: $(d.value_cache[nspace][name])")
        println("Now: $value")
    end
    d.value_cache[nspace][name] = value
end

cache_value!(d::DynamicDDLmRC,nspace,name,index,value) = d.value_cache[nspace][name][index] = value

cache_cat!(d::DynamicDDLmRC,nspace,catname,catvalue) = begin
    for k in get_datanames(catvalue)
        cache_value!(d,nspace,k,catvalue[k])
    end
end

get_dictionary(d::DynamicDDLmRC) = first(d.dict).second

get_dictionary(d::DynamicDDLmRC,nspace) = d.dict[nspace]

# We treat ourselves as a data source so that the
# cached values and supplied values are both accessible

get_data(d::DynamicDDLmRC) = d

Base.keys(d::DynamicDDLmRC) = begin
    real_keys = keys(d.data)
    Iterators.flatten(real_keys, (
    string.(n*"‡",keys(d.value_cache[n])) for n in keys(d.value_cache))...)
end

Base.show(io::IO,d::DynamicDDLmRC) = begin
    show(io,d.data)
    show(io,d.value_cache)
end

Base.haskey(d::DynamicDDLmRC,s::String) = begin
    return s in keys(d)
end

"""
`s` is always a canonical data name, and the value returned will
be all values for that data name in the same order as the key values.
Note that new values can only be derived via categories.
As we have namespaces, getindex only works if the namespace is included
in `s`
"""
Base.getindex(d::DynamicDDLmRC,s::AbstractString) = begin
    if haskey(d.data,s) return d.data[s] end
    if occursin('‡', s)
        nspace,realname = split(s,'‡')
    else
        nspace,realname = "",s
    end
    getindex(d,realname,nspace)
end

Base.getindex(d::DynamicDDLmRC,s::AbstractString,nspace::AbstractString) = begin
    if haskey(d.value_cache[nspace],s) return d.value_cache[nspace][s] end
    m = derive(d,s,nspace)
    accept = any(x->!ismissing(x),m)
    if !accept
        m = get_default(d,s,nspace)
    end
    if any(x->!ismissing(x),m)
        d[lowercase(s)]= m
        return m
    end
    throw(KeyError("$s"))
end

Base.setindex!(d::DynamicDDLmRC,v,s::String,nspace::String) = d.value_cache[nspace][s]=v

get_category(d::DynamicDDLmRC,s::String,nspace::String) = begin
    dict = get_dictionary(d,nspace)
    cat_type = get(dict[s],"_definition.class",["Datum"])[]
    if cat_type == "Set"   #an empty category is good enough
        println("Building empty category $s")
        return construct_category(d,s,nspace)
    end
    println("Searching for category $s")
    if has_category(d,s,nspace) return construct_category(d,s,nspace) end
    derive_category(d,s,nspace)   #worth a try
    if has_category(d,s,nspace) return construct_category(d,s,nspace) end
    println("Category $s not found for namespace $nspace")
    return missing
end

# Legacy categories may appear without their key, for which
# the DDLm dictionary may provide a method.

#
#  Dynamic Category
#

get_default(db::DynamicRelationalContainer,s::String,nspace::String) = begin
    dict = get_dictionary(db,nspace)
    def_vals = CrystalInfoFramework.get_default(dict,s)
    cat_name = find_category(dict,s)
    if !has_category(db,cat_name,nspace)
        throw(error("Cannot provide default value for $s,category $cat_name does not exist for namespace $nspace"))
    end
    target_loop = get_category(db,cat_name,nspace)
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
derive(b::DynamicRelationalContainer,dataname::String,nspace) = begin
    dict = get_dictionary(b,nspace)
    if !(has_func(dict,dataname))
        add_new_func(dict,dataname)
    end
    func_code = get_func(dict,dataname)
    target_loop = get_category(b,find_category(dict,dataname))
    [Base.invokelatest(func_code,b,p) for p in target_loop]
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

derive_category(b::DynamicRelationalContainer,cat::String,nspace) = begin
    dict = get_dictionary(b,nspace)
    t = get_func_text(dict,cat,"Evaluation")
    if t == "" return end
    if !(has_func(dict,cat))
        add_new_func(dict,cat)
    else
        println("Func for $cat already exists")
    end
    func_code = get_func(dict,cat)
    col_vals = Base.invokelatest(func_code,b)
    # Convert to canonical names
    col_vals = (lowercase(get_by_cat_obj(dict,(cat,x.first))["_definition.id"][1]) => x.second for x in col_vals)
    for p in col_vals
        cache_value!(b,nspace,p.first,p.second)
    end
end

# For a single row in a packet
get_default(block::DynamicRelationalContainer,cp::CatPacket,obj::Symbol,nspace) = begin
    dict = get_dictionary(block,nspace)
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

