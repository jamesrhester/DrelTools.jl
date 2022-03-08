
# Configuration

# Deserialise a parser for the dREL grammar. This is serialized in the build phase of
# module installation, see deps/build.jl . If the EBNF is changed, run 'julia build.jl'
# in that directory.

const drel_parser = Serialization.deserialize(joinpath(@get_scratch!("lark_grammar"),"drel_grammar_serialised.jli"))

# Parse and output proto-Julia code using Lerche

get_drel_methods(cd::AbstractCifDictionary) = begin
    has_meth = cd[:method][cd[:method][!,:expression] .!= nothing,(:expression,:master_id)]
    #println("Found $(length(has_meth)) methods")
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
    make_julia_code(drel_text,dataname,dict; reserved=[])

Define a Julia method from dREL code contained in `drel_text` which calculates the value of `dataname`
defined in `dict`. All category names in `dict` and any additional names in `reserved` are recognised
as categories.
"""
make_julia_code(drel_text,dataname,dict; reserved=AbstractString[]) = begin
    tree = Lerche.parse(drel_parser,drel_text)
    @debug "Rule dict: $(get_rule_dict())"
    transformer = TreeToJulia(dataname,dict,extra_cats = reserved)
    proto = Lerche.transform(transformer,tree)
    tc_alias = transformer.target_category_alias
    @debug "Proto-Julia code: " proto
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
            @warn "WARNING: no target identified for $dataname"
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

"""
    define_dict_funcs!(dict)

Find and transform to Julia all dREL functions defined in `dict`. This must be called in order
for these functions to be available to dREL methods defined in `dict`.
"""
define_dict_funcs!(dict) = begin
    #Parse and evaluate all dictionary-defined functions and store
    func_cat,all_funcs = get_dict_funcs(dict)
    for f in all_funcs
        @debug "Now processing $f"         
        full_def = dict[find_name(dict,func_cat,f)]
        entry_name = full_def[:definition].id[]
        full_name = lowercase(full_def[:name].object_id[])
        func_text = full_def[:method][!,:expression][1]
        @debug "Function text: $func_text"
        result = make_julia_code(func_text,entry_name,dict)
        @debug "Transformed text: $result"
        set_func!(dict,full_name,result,eval(result))  #store in dictionary
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
    dict::Dict{String,AbstractCifDictionary} #provides dREL functions
    value_cache::Dict{String,Dict{String,Any}} #namespace indexed
    cat_cache::Dict{String,Dict{String,CifCategory}}
end

"""
    DynamicDDLmRC(ds, dict::AbstractCifDictionary)

Create a `DynamicDDLmRC` object from `ds` with relational
structure defined by `dict`. If `dict` includes dREL methods describing
mathematical relationships between data names, use these to derive
and cache missing values.

`ds` should provide the `DataSource` trait.

A `DynamicDDLmRC` is itself a `DataSource`.
"""
DynamicDDLmRC(ds::DataSource, dict::AbstractCifDictionary) = begin
    DynamicDDLmRC(IsDataSource(),ds,dict)
end

DynamicDDLmRC(ds,dict::AbstractCifDictionary) = begin
    DynamicDDLmRC(DataSource(ds),ds,dict)
end

DynamicDDLmRC(::IsDataSource,ds,dict) = begin
    nspace = get_dic_namespace(dict)
    DynamicDDLmRC(ds,Dict(nspace=>dict),
                  Dict(nspace=>Dict{String,Any}()),
                  Dict(nspace=>Dict{String,CifCategory}()))
end

DynamicDDLmRC(r::AbstractRelationalContainer) = begin
    nspaces = get_namespaces(r)
    d = Dict{String,Dict{String,Any}}()
    c = Dict{String,Dict{String,CifCategory}}()
    for n in nspaces
        d[n] = Dict()
        c[n] = Dict{String,CifCategory}()
    end
    DynamicDDLmRC(r,get_dicts(r),d,c)
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

"""
    empty_cache!(d)

Remove all cached data name values computed for `d`.
"""
empty_cache!(d::DynamicDDLmRC) = begin
    for k in keys(d.value_cache)
        empty!(d.value_cache[k])
    end
    for k in keys(d.cat_cache)
        empty!(d.cat_cache[k])
    end
end

invalidate_cache!(d::DynamicDDLmRC,nspace,name) = begin
    # invalidate related categories
    cat = find_category(d.dict[nspace],name)
    if haskey(d.cat_cache[nspace],cat)
        delete!(d.cat_cache[nspace],cat)
    end
end

cache_value!(d::DynamicDDLmRC,name::String,value) = begin
    nspace = find_namespace(d,name)
    cache_value!(d,nspace,lowercase(name),value)
end

#
# We want arrays of missing values to go through here as placeholders
#
cache_value!(d::DynamicDDLmRC,nspace::String,name::String,value) = begin
    if haskey(d.value_cache[nspace],lowercase(name))
        @warn "WARNING: overwriting previously cached value for $name"
        @warn "Old length: $(length(d.value_cache[nspace][name]))"
        @warn "New length: $(length(value))"
        if length(value) < 150
            @warn "Old values: $(d.value_cache[nspace][name])"
            @warn "New values: $(value)"
        end
    end
    d.value_cache[nspace][lowercase(name)] = value
    invalidate_cache!(d,nspace,name)
end

#
# Don't bother caching missing values
# Assume that any cached categories will still be valid
#
cache_value!(d,nspace,name,index,value) = begin
    d.value_cache[nspace][lowercase(name)][index] = value
end

cache_value!(d,nspace,name,index,value::Missing) = nothing

cache_value!(d::DynamicDDLmRC,name::String,index::Int,value) = begin
    cache_value!(d,find_namespace(d,name),name,index,value)
end

cache_cat!(d::DynamicDDLmRC,nspace,catname,catvalue) = begin
    for k in get_datanames(catvalue)
        cache_value!(d,nspace,k,catvalue[k])
    end
    d.cat_cache[nspace][catname] = catvalue
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
                  Dict(nspace=>d.value_cache[nspace]),
                  Dict(nspace=>d.cat_cache[nspace]))
end

"""
    keys(d::DynamicDDLmRC)

Return all data names that have associated values in `d`. If multiple
namespaces are present, some data names may be duplicated. If calculations
have been performed to derive data name values, those data names will
be included.
"""
keys(d::DynamicDDLmRC) = begin
    real_keys = keys(d.data)
    nspaces = get_namespaces(d)
    vc_keys = (keys(d.value_cache[n]) for n in nspaces)
    Iterators.flatten((real_keys,vc_keys...))
end

"""
    keys(d::DynamicDDLmRC,nspace)

Namespace-aware version of `keys`
"""
keys(d::DynamicDDLmRC,nspace) = begin
    f = select_namespace(d,nspace)
    Iterators.flatten((keys(f.data),keys(f.value_cache[nspace])))
end

show(io::IO,d::DynamicDDLmRC) = begin
    show(io,d.data)
    show(io,d.value_cache)
end

"""
    haskey(d::DynamicDDLmRC,s)

`true` if any instance found of `s` in `d`.
"""
haskey(d::DynamicDDLmRC,s) = begin
    return s in keys(d)
end

"""
    haskey(d::DynamicDDLmRC,s,n)

`true` if any instance found of `s` from namespace `n` in `d`.
"""
haskey(d::DynamicDDLmRC,s,n) = begin
    return s in keys(d,n)
end

"""
    getindex(d::DynamicDDLmRC,s)

`d[s]` returns all values for that data name in the same order as the key values,
so that they may be interpreted as a column of values in correct order, deriving
missing values from dREL methods if available.

If `s` appears in multiple namespaces within `d`, an error is raised.
"""
getindex(d::DynamicDDLmRC,s) = begin
    n = find_namespace(d,s)
    return d[s,n]
end

"""
    getindex(d::DynamicDDLmRC,s,nspace)

`d[s,nspace]` returns the values of dataname `s` from namespace `nspace` in `d`, with
derivation of missing values. Values
are returned in an order corresponding to the order in which key data name values are
provided, meaning that the returned values can be assembled into a table without
further manipulation.
"""
getindex(d::DynamicDDLmRC,s,nspace) = begin
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

"""
    setindex!(d::DynamicDDLmRC,v,s)
    
Set the value of `s` in `d` to `v`. The underlying data source is not changed,
instead values are set in the cache and will be deleted by `empty_cache!`.
"""
setindex!(d::DynamicDDLmRC,v,s) = begin
    nspace = find_namespace(d,s)
    setindex!(d,v,s,nspace)
end

"""
    setindex!(d::DynamicDDLmRC,v,s,nspace)

Set the value of `s` from namespace `nspace` in `d` to `v`. 
The underlying data source is not changed,
instead values are set in the cache and will be deleted by `empty_cache!`.
"""
setindex!(d::DynamicDDLmRC,v,s,nspace) = d.value_cache[nspace][lowercase(s)]=v

"""
    get_category(d::DynamicDDLmRC,s::AbstractString,nspace::String)

Return a `CifCategory` named `s` in namespace `nspace` from `d`, creating the
category using dREL category methods if missing. If `s` is already present, no further
data names from that category are derived.
"""
get_category(d::DynamicDDLmRC,s::AbstractString,nspace::String) = begin
    if haskey(d.cat_cache[nspace],s)
        return d.cat_cache[nspace][s]
    end
    dict = get_dictionary(d,nspace)
    if is_set_category(dict,s)   #an empty category is good enough
        d.cat_cache[nspace][s] = construct_category(d,s,nspace)
    elseif has_category(d,s,nspace)
        c = construct_category(d,s,nspace)
        if typeof(c) != LegacyCategory
            d.cat_cache[nspace][s] = c
        else
            d.cat_cache[nspace][s] = repair_cat(d,c,nspace)
        end
    else
        derive_category(d,s,nspace)   #worth a try
        if has_category(d,s,nspace)
            d.cat_cache[nspace][s] = construct_category(d,s,nspace)
        end
    end
    if !haskey(d.cat_cache[nspace],s)
        @info "Category $s not found for namespace $nspace"
        return missing
    end
    return d.cat_cache[nspace][s]  
end

"""
    get_category(d::DynamicDDLmRC,s)

Return a `CifCategory` named `s` from `d`, creating the
category using dREL category methods if missing. If `s` is already present, no further
data names from that category are derived. If `s` is ambiguous because it is 
present in multiple namespaces, an error is raised.
"""
get_category(d::DynamicDDLmRC,s) = begin
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
    @debug "Preparing to invoke code for $keyname"
    keyvals = [Base.invokelatest(func_code,d,p) for p in l]
    cache_value!(d,nspace,keyname,keyvals)
    return LoopCategory(l,keyvals)
end


#
#  Dynamic Category
#

get_default(db::DynamicRelationalContainer,s::AbstractString,nspace::String) = begin
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
        @debug "Result of lookup for $s: $m"
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
        @warn "$(typeof(e)) when executing default dREL for $s/enumeration.default, should not happen"
        @warn "Function text: $(get_def_meth_txt(dict,s,"enumeration.default"))"
        rethrow(e)
    end
    throw(error("should never reach this point"))
end

"""
    derive(b::DynamicRelationalContainer,dataname,nspace)

Derive values for `dataname` in `nspace` missing from `b`. Return `missing`
if the category itself is missing, otherwise return an Array potentially
containing missing values with one value for each row in the category.
"""
derive(b::DynamicRelationalContainer,dataname::AbstractString,nspace) = begin
    dict = get_dictionary(b,nspace)
    target_loop = get_category(b,find_category(dict,dataname),nspace)
    if ismissing(target_loop) return missing end
    return derive(b,target_loop,dataname,dict,nspace)
end

derive(b::DynamicDDLmRC,dataname::AbstractString) = begin
    nspaces = get_namespaces(b)
    derive(b,dataname,nspaces[])
end

derive(b::DynamicRelationalContainer,s::SetCategory,dataname::AbstractString,dict,nspace) = begin
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
        @warn "Warning: error $(typeof(e)) in dREL method for $dataname, should never happen."
        @warn "Method text: $(CrystalInfoFramework.get_func_text(dict,dataname))"
        rethrow(e)
    end
end

derive(b::DynamicRelationalContainer,s::LoopCategory,dataname::AbstractString,dict,nspace) = begin
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
        @warn "Warning: error $(typeof(e)) in dREL method for $dataname, should never happen."
        @warn "Method text: $(CrystalInfoFramework.get_func_text(dict,dataname))"
        rethrow(e)
    end
end

#
# Deal with empty legacy categories which might pop up
#
derive(b::DynamicRelationalContainer,s::LegacyCategory,dataname,dict,nspace) = begin
    if length(s) == 0 return []
    else
        throw(error("Legacy category $(get_name(s)) is missing key datanames; derivation of $dataname is not possible"))
    end
end

#== Per packet derivation

This is called from within a dREL method when an item is
found missing from a packet.
==#
    
derive(p::CatPacket,obj::AbstractString,db) = begin
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
        @warn "$(typeof(e)) when evaluating $cat.$obj, should not happen"
        @warn "Function text: $(get_func_text(dict,dataname))"
        rethrow(e)
    end
end

#==

Category methods

==#

#==

Category methods create whole new categories

==#

derive_category(b::DynamicRelationalContainer,cat::AbstractString,nspace) = begin
    dict = get_dictionary(b,nspace)
    t = load_func_text(dict,cat,"Evaluation")
    if t == "" return end
    if !(has_func(dict,cat))
        add_new_func(b,cat,nspace)
    #else
    #    println("Func for $cat already exists")
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
    # debug_info = get_def_meth_txt(dict,dataname,"enumeration.default")
    #println("==== Invoking default function for $dataname ===")
    #println("Stored code:")
    #println(debug_info)
    return Base.invokelatest(func_code,block,cp)
end

get_default(block::DynamicRelationalContainer,cp::CatPacket,obj::Symbol) = begin
    nspace = get_dic_namespace(get_dictionary(cp))
    get_default(block,cp,obj,nspace)
end

add_new_func(b::DynamicRelationalContainer,s::AbstractString,nspace) = begin
    dict = get_dictionary(b,nspace)
    # get all categories mentioned
    all_cats = String[]
    for n in get_namespaces(b)
        @debug "Namespace $n"
        append!(all_cats,get_categories(get_dictionary(b,n)))
    end
    add_new_func(dict,s,all_cats)
end

add_new_func(d::AbstractCifDictionary,s::AbstractString,special_names) = begin
    t = load_func_text(d,s,"Evaluation")
    if t != ""
        r = make_julia_code(t,s,d,reserved=special_names)
    else
        r = Meta.parse("(a,b) -> missing")
    end
    @debug "Transformed code for $s:\n" r
    set_func!(d,s, r, eval(r))
end

add_new_func(d::AbstractCifDictionary,s::AbstractString) = begin
    @warn "Warning: recognising only categories from $(get_dic_name(d))"
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

const all_set_ddlm = [("units","code"),("enumeration","default")]

"""
    add_definition_func!(dictionary,dataname)

Add a method that adjusts the definition of dataname by defining
a DDLm attribute.
"""
add_definition_func!(d,s) = begin
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
                @debug "Found target: $ft"
                att_name = "$a.$targ"
                break
            end
        end
        @debug "For dataname $s, attribute $att_name"
        @debug "Transformed code:\n" r
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

