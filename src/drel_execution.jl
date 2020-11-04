#== This module defines functions for executing dREL code ==#
export dynamic_block, define_dict_funcs, derive
export add_definition_func, empty_cache!
export DynamicRelationalContainer, DynamicDDLmRC, DynamicCat
export find_namespace

import DataContainer:get_key_datanames, get_value, get_name
import DataContainer:get_category, has_category, get_data, get_dictionary
import DataContainer:select_namespace,get_namespaces

# Configuration
#const drel_grammar = joinpath(@__DIR__,"lark_grammar.ebnf")

#include("lark_grammar.ebnf")

# Create a parser for the dREL grammar. It needs to be contextual
# due to such issues as an isolated variable "j" being parsed as the
# signifier for an imaginary number.

const drel_parser = Serialization.deserialize(joinpath(@__DIR__,"..","deps","drel_grammar_serialised.jli"))

# Parse and output proto-Julia code using Lerche

get_drel_methods(cd::abstract_cif_dictionary) = begin
    has_meth = cd[:method][cd[:method][!,:expression] .!= nothing,(:expression,:master_id)]
    println("Found $(length(has_meth)) methods")
    return has_meth    #category methods as well
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
"""
make_julia_code(drel_text::String,dataname::String,dict::abstract_cif_dictionary; reserved=[])

Define a Julia method from dREL code contained in `drel_text` which calculates the value of `dataname`
defined in `dict`. All category names in `dict` and any additional names in `reserved` are recognised
as categories.
"""
make_julia_code(drel_text::String,dataname::String,dict::abstract_cif_dictionary; reserved=String[]) = begin
    tree = Lerche.parse(drel_parser,drel_text)
    #println("Rule dict: $(get_rule_dict())")
    transformer = TreeToJulia(dataname,dict,extra_cats = reserved)
    proto = Lerche.transform(transformer,tree)
    tc_alias = transformer.target_category_alias
    println("Proto-Julia code: ")
    println(proto)
    #println("Target category aliased to $tc_alias")
    unique!(append!(reserved,get_categories(dict)))
    parsed = ast_fix_indexing(proto,reserved,dict)
    #println(parsed)
    if !transformer.is_category   #not relevant for category methods
        # catch implicit matrix assignments
        container_type = get_container_type(dict,dataname)
        is_matrix = (container_type == "Matrix" || container_type == "Array")
        ft,parsed = find_target(parsed,tc_alias,transformer.target_object;is_matrix=is_matrix)
        if ft == nothing && !transformer.is_func
            println("WARNING: no target identified for $dataname")
        end
    end
    parsed = fix_scope(parsed)
    set_categories = get_set_categories(dict)
    #parsed = cat_to_packet(parsed,set_categories)  #turn Set categories into packets
    #println("####\n    Assigning types\n####\n")
    parsed = ast_assign_types(parsed,Dict(Symbol("__packet")=>transformer.target_cat),cifdic=dict,set_cats=set_categories,all_cats = reserved)
    if !transformer.is_category
        parsed = ast_assign_retval(parsed,dict,transformer.target_cat,find_object(dict,dataname))
    end
    return parsed
end

define_dict_funcs(c::abstract_cif_dictionary) = begin
    #Parse and evaluate all dictionary-defined functions and store
    func_cat,all_funcs = get_dict_funcs(c)
    for f in all_funcs
        println("Now processing $f")         
        full_def = c[find_name(c,func_cat,f)]
        entry_name = full_def[:definition].id[]
        full_name = lowercase(full_def[:name].object_id[])
        func_text = full_def[:method][!,:expression][1]
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

Values can be distributed between namespaces, each of which has a
corresponding dictionary.

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

get_namespaces(d::DynamicDDLmRC) = collect(keys(d.value_cache))

"""
find_namespace(d::DynamicDDLmRC,dataname)

Find a single namespace in `d` that knows about `dataname`. If no such namespace exists,
an error is thrown
"""
find_namespace(d::DynamicDDLmRC,dataname) = begin
    nspaces = get_namespaces(d)
    if length(nspaces) == 1 return nspaces[] end
    potentials  = [n for n in nspaces if haskey(d.dict[n],dataname)]
    if length(potentials) > 1
        throw(error("Name appears in more than one namespace: $dataname. Please specify namespace."))
    elseif length(potentials) == 0 throw(KeyError(dataname)) end
    potentials[]
end

empty_cache!(d::DynamicDDLmRC) = begin
    for k in keys(d.value_cache)
        empty!(d.value_cache[k])
    end
end

cache_value!(d::DynamicDDLmRC,name::String,value) = begin
    nspace = find_namespace(d,name)
    cache_value!(d,nspace,lowercase(name),value)
end

cache_value!(d::DynamicDDLmRC,nspace::String,name::String,value) = begin
    if haskey(d.value_cache[nspace],lowercase(name))
        println("WARNING: overwriting previously cached value for $name")
        println("Old length: $(length(d.value_cache[nspace][name]))")
        println("New length: $(length(value))")
    end
    d.value_cache[nspace][lowercase(name)] = value
end

# Don't bother caching missing values
cache_value!(d::DynamicDDLmRC,nspace::String,name::String,index::Int,value) = begin
    if !ismissing(value)
        d.value_cache[nspace][lowercase(name)][index] = value
    end
end

cache_value!(d::DynamicDDLmRC,name::String,index::Int,value) = begin
    cache_value!(d,find_namespace(d,name),name,index,value)
end

cache_cat!(d::DynamicDDLmRC,nspace,catname,catvalue) = begin
    for k in get_datanames(catvalue)
        cache_value!(d,nspace,k,catvalue[k])
    end
end

get_dictionary(d::DynamicDDLmRC) = d.dict[get_namespaces(d)[]]

get_dictionary(d::DynamicDDLmRC,nspace) = d.dict[nspace]

# We treat ourselves as a data source so that the
# cached values and supplied values are both accessible

get_data(d::DynamicDDLmRC) = d

select_namespace(d::DynamicDDLmRC,nspace) = begin
    filtered_data = TypedDataSource(Dict{String,Any}(),d.dict[nspace])
    try
        filtered_data = select_namespace(d.data,nspace)
    catch e
        if !(e isa KeyError) rethrow() end
    end
    DynamicDDLmRC(filtered_data,Dict(nspace=>d.dict[nspace]),
                  Dict(nspace=>d.value_cache[nspace]))
end

"""
All keys returned, even if duplicated
"""
Base.keys(d::DynamicDDLmRC) = begin
    real_keys = keys(d.data)
    nspaces = get_namespaces(d)
    vc_keys = (keys(d.value_cache[n]) for n in nspaces)
    Iterators.flatten((real_keys,vc_keys...))
end

"""
Namespace-aware version of `keys`
"""
Base.keys(d::DynamicDDLmRC,nspace::String) = begin
    f = select_namespace(d,nspace)
    Iterators.flatten((keys(f.data),keys(f.value_cache[nspace])))
end

Base.show(io::IO,d::DynamicDDLmRC) = begin
    show(io,d.data)
    show(io,d.value_cache)
end

"""
Return true if any instance found of `s` in `d`
"""
Base.haskey(d::DynamicDDLmRC,s::String) = begin
    return s in keys(d)
end

Base.haskey(d::DynamicDDLmRC,s::String,n::String) = begin
    return s in keys(d,n)
end

"""
`s` is always a canonical data name, and the value returned will
be all values for that data name in the same order as the key values.
Note that new values can only be derived via categories.
As we have namespaces, getindex only works if the namespace is included
in `s`
"""
Base.getindex(d::DynamicDDLmRC,s::AbstractString) = begin
    n = find_namespace(d,s)
    return d[s,n]
end

"""
d[s,nspace]

Return from `d` the value of dataname `s` from namespace `nspace`, with
derivation of missing values.
"""
Base.getindex(d::DynamicDDLmRC,s::AbstractString,nspace::AbstractString) = begin
    ls = lowercase(s)
    small_r = select_namespace(d,nspace)
    if haskey(small_r.data,ls) return small_r.data[ls] end
    if haskey(small_r.value_cache[nspace],ls) return small_r.value_cache[nspace][ls] end
    m = derive(d,s,nspace)
    if ismissing(m) throw(KeyError("$s")) end
    accept = any(x->!ismissing(x),m)
    if !accept
        m = get_default(d,s,nspace)
    end
    if any(x->!ismissing(x),m)
        setindex!(d,m,s,nspace)
        return m
    end
    throw(KeyError("$s"))
end

Base.setindex!(d::DynamicDDLmRC,v,s::String) = begin
    nspace = find_namespace(d,s)
    setindex!(d,v,s,nspace)
end

Base.setindex!(d::DynamicDDLmRC,v,s::String,nspace::String) = d.value_cache[nspace][lowercase(s)]=v

get_category(d::DynamicDDLmRC,s::String,nspace::String) = begin
    dict = get_dictionary(d,nspace)
    if is_set_category(dict,s)   #an empty category is good enough
        return construct_category(d,s,nspace)
    end
    println("Searching for category $s")
    if has_category(d,s,nspace)
        c = construct_category(d,s,nspace)
        if typeof(c) != LegacyCategory return c end
        return repair_cat(d,c,nspace)
    end
    derive_category(d,s,nspace)   #worth a try
    if has_category(d,s,nspace) return construct_category(d,s,nspace) end
    println("Category $s not found for namespace $nspace")
    return missing
end

"""
If no namespace is provided, try and find one based on the name
"""
get_category(d::DynamicDDLmRC,s::String) = begin
    n = find_namespace(d,s)
    get_category(d,s,n)
end

# Legacy categories may appear without their key, for which
# the DDLm dictionary may provide a method.

repair_cat(d::DynamicDDLmRC,l::LegacyCategory,nspace) = begin
    dict = get_dictionary(d,nspace)
    s = get_name(l)
    # derive any single missing key
    keyname = get_keys_for_cat(dict,s)
    if length(keyname) != 1 return l end
    keyname = keyname[]
    if !(has_func(dict,keyname))
        add_new_func(d,keyname,nspace)
    end
    func_code = get_func(dict,keyname)
    println("Preparing to invoke code for $keyname")
    keyvals = [Base.invokelatest(func_code,d,p) for p in l]
    cache_value!(d,nspace,keyname,keyvals)
    return LoopCategory(l,keyvals)
end


#
#  Dynamic Category
#

get_default(db::DynamicRelationalContainer,s::String,nspace::String) = begin
    dict = get_dictionary(db,nspace)
    def_vals = CrystalInfoFramework.get_default(dict,s)
    cat_name = find_category(dict,s)
    if !has_category(db,cat_name,nspace) && get_cat_class(dict,cat_name) != "Set"
        throw(error("Cannot provide default value for $s,category $cat_name does not exist for namespace $nspace"))
    end
    target_loop = get_category(db,cat_name,nspace)
    if !ismissing(def_vals)
        return [def_vals for i in target_loop]
    end
    # perhaps we can lookup a default value?
    m = all_from_default(dict,s,target_loop)
    if any(x->!ismissing(x),m)
        println("Result of lookup for $s: $m")
        return m
    end
    # end of the road for non dREL dictionaries
    if !has_default_methods(dict) return fill(missing,length(target_loop)) end
    # is there a derived default available?
    if !has_def_meth(dict,s,"enumeration.default")
        add_definition_func!(dict,s)
    end
    func_code = get_def_meth(dict,s,"enumeration.default")
    try
        return [Base.invokelatest(func_code,db,p) for p in target_loop]
    catch e
        println("$(typeof(e)) when executing default dREL for $s/enumeration.default, should not happen")
        println("Function text: $(get_def_meth_txt(dict,s,"enumeration.default"))")
        rethrow(e)
    end
    throw(error("should never reach this point"))
end

"""
derive(b::DynamicRelationalContainer,dataname::String,nspace)

Derive values for `dataname` in `nspace` missing from `b`. Return `missing`
if the category itself is missing, otherwise return an Array potentially
containing missing values with one value for each row in the category.
"""
derive(b::DynamicRelationalContainer,dataname::String,nspace) = begin
    dict = get_dictionary(b,nspace)
    target_loop = get_category(b,find_category(dict,dataname),nspace)
    if ismissing(target_loop) return missing end
    return derive(b,target_loop,dataname,dict,nspace)
end

derive(b::DynamicDDLmRC,dataname::String) = begin
    nspaces = get_namespaces(b)
    derive(b,dataname,nspaces[])
end

derive(b::DynamicRelationalContainer,s::SetCategory,dataname::String,dict,nspace) = begin
    obj = find_object(dict,dataname)
    if haskey(s,dataname) return s[Symbol(obj)] end
    if !has_drel_methods(dict) return missing end
    if !(has_func(dict,dataname))
        add_new_func(b,dataname,nspace)
    end
    func_code = get_func(dict,dataname)
    pkt = first_packet(s)
    #if length(keys(s)) == 0   # no data
    #    pkt = nothing
    #else
    #    pkt = first(s)
    #end
    try
        [Base.invokelatest(func_code,b,pkt)]
    catch e
        println("Warning: error $(typeof(e)) in dREL method for $dataname, should never happen.")
        println("Method text: $(CrystalInfoFramework.get_func_text(dict,dataname))")
        rethrow(e)
    end
end

derive(b::DynamicRelationalContainer,s::LoopCategory,dataname::String,dict,nspace) = begin
    if length(s) == 0 return missing end
    obj = find_object(dict,dataname)
    if haskey(s,dataname) return s[Symbol(obj)] end
    if !has_drel_methods(dict) return fill(missing,length(s)) end
    if !(has_func(dict,dataname))
        add_new_func(b,dataname,nspace)
    end
    func_code = get_func(dict,dataname)
    try
        [Base.invokelatest(func_code,b,p) for p in s]
    catch e
        println("Warning: error $(typeof(e)) in dREL method for $dataname, should never happen.")
        println("Method text: $(CrystalInfoFramework.get_func_text(dict,dataname))")
        rethrow(e)
    end
end

#
# Deal with empty legacy categories which might pop up
#
derive(b::DynamicRelationalContainer,s::LegacyCategory,dataname,dict,nspace) = begin
    if length(s) == 0 return []
    else
        throw(error("Category $(get_name(s)) is missing key datanames; derivation of $dataname is not possible"))
    end
end

#== Per packet derivation

This is called from within a dREL method when an item is
found missing from a packet.
==#
    
derive(p::CatPacket,obj::String,db) = begin
    d = get_category(p)
    dict = get_dictionary(d)
    nspace = get_dic_namespace(dict)
    if !has_drel_methods(dict) return missing end 
    cat = get_name(d)
    dataname = find_name(dict,cat,obj)
    # get the underlying data
    if !(has_func(dict,dataname))
        add_new_func(db,dataname,nspace)
    end
    func_code = get_func(dict,dataname)
    try
        Base.invokelatest(func_code,db,p)
    catch e
        println("$(typeof(e)) when evaluating $cat.$obj, should not happen")
        println("Function text: $(get_func_text(dict,dataname))")
        rethrow(e)
    end
end

#==

Category methods

==#

#==

Category methods create whole new categories

==#

derive_category(b::DynamicRelationalContainer,cat::String,nspace) = begin
    dict = get_dictionary(b,nspace)
    t = load_func_text(dict,cat,"Evaluation")
    if t == "" return end
    if !(has_func(dict,cat))
        add_new_func(b,cat,nspace)
    else
        println("Func for $cat already exists")
    end
    func_code = get_func(dict,cat)
    col_vals = Base.invokelatest(func_code,b)
    # Convert to canonical names
    col_vals = (lowercase(find_name(dict,cat,x.first)) => x.second for x in col_vals)
    for p in col_vals
        cache_value!(b,nspace,p.first,p.second)
    end
end

# For a single row in a packet
get_default(block::DynamicRelationalContainer,cp::CatPacket,obj::Symbol,nspace) = begin
    dict = get_dictionary(block,nspace)
    mycat = get_name(get_category(cp))
    dataname = find_name(dict,mycat,String(obj))
    def_val = CrystalInfoFramework.get_default(dict,dataname)
    if !ismissing(def_val)
        return def_val
    end
    # Try using enumeration default instead
    def_val = lookup_default(dict,dataname,cp)
    if !ismissing(def_val)
        return convert_to_julia(dict,dataname,[def_val])[]
    end
    # Bail if not dREL aware
    if !has_default_methods(dict) return missing end
    if !has_def_meth(dict,dataname,"_enumeration.default")
        add_definition_func!(dict,dataname)
    end
    func_code = get_def_meth(dict,dataname,"enumeration.default")
    debug_info = get_def_meth_txt(dict,dataname,"enumeration.default")
    println("==== Invoking default function for $dataname ===")
    println("Stored code:")
    println(debug_info)
    return Base.invokelatest(func_code,block,cp)
end

get_default(block::DynamicRelationalContainer,cp::CatPacket,obj::Symbol) = begin
    nspace = get_dic_namespace(get_dictionary(cp))
    get_default(block,cp,obj,nspace)
end

add_new_func(b::DynamicRelationalContainer,s::String,nspace) = begin
    dict = get_dictionary(b,nspace)
    # get all categories mentioned
    all_cats = String[]
    for n in get_namespaces(b)
        println("Namespace $n")
        append!(all_cats,get_categories(get_dictionary(b,n)))
    end
    add_new_func(dict,s,all_cats)
end

add_new_func(d::abstract_cif_dictionary,s::String,special_names) = begin
    t = load_func_text(d,s,"Evaluation")
    if t != ""
        r = make_julia_code(t,s,d,reserved=special_names)
    else
        r = Meta.parse("(a,b) -> missing")
    end
    println("Transformed code for $s:\n")
    println(r)
    set_func!(d,s, r, eval(r))
end

add_new_func(d::abstract_cif_dictionary,s::String) = begin
    println("Warning: recognising only categories from $(get_dic_name(d))")
    add_new_func(d,s,String[])
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
    t = load_func_text(d,s,"Definition")
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

all_from_default(dict,dataname,cat::CifCategory) = begin
    convert_to_julia(dict,dataname,[lookup_default(dict,dataname,cp) for cp in cat])
end

#== 

Full dictionary processing

==#

compile_all_methods(dict) = begin
    for k in keys(dict)
        add_new_func(dict,k)
    end
end

