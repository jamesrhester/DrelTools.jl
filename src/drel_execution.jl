#== This module defines functions for executing dREL code ==#
export dynamic_block, define_dict_funcs, derive, get_func_text
export add_definition_func, empty_cache!

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
    # catch implicit matrix assignments
    container_type = dict[dataname]["_type.container"][1]
    is_matrix = (container_type == "Matrix" || container_type == "Array")
    ft,parsed = find_target(parsed,tc_alias,transformer.target_object;is_matrix=is_matrix)
    if ft == nothing && !transformer.is_func
        error("Epic fail: no target identified for $dataname")
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

#== Dynamic blocks

A dynamic block, in addition to knowing types and default values, will also
actively seek to derive missing information, including calculation of
default values.  These values are cached for efficiency and appear as if
they were present in the original file after they have been calculated once.
To remove these values, the cache should be emptied.

==#

struct dynamic_block <: cif_container_with_dict
    block::cif_block_with_dict
    value_cache::Dict{String,Any}
end

dynamic_block(cbwd::cif_block_with_dict) = dynamic_block(cbwd,Dict{String,Any}())

empty_cache!(d::dynamic_block) = empty!(d.value_cache)

cache_value!(d::dynamic_block,name,value) = begin
    if haskey(d.value_cache,name)
        println("WARNING: overwriting previously cached value")
        println("Was: $(d.value_cache[name])")
        println("Now: $value")
    end
    d.value_cache[name] = value
end

cache_value!(d::dynamic_block,name,index,value) = d.value_cache[name][index] = value

CrystalInfoFramework.get_dictionary(d::dynamic_block) = get_dictionary(d.block)
CrystalInfoFramework.get_datablock(d::dynamic_block) = get_datablock(d.block)
CrystalInfoFramework.get_typed_datablock(d::dynamic_block) = d

Base.getindex(d::dynamic_block,s::String) = begin
    try
        q = d.block[s]
    catch KeyError
        if haskey(d.value_cache,lowercase(s))
            println("Returning cached value for $s")
            return d.value_cache[lowercase(s)]
        end
        m = derive(d,s)
        accept = any(x->!ismissing(x),m)
        if !accept
            m = CrystalInfoFramework.get_default(d,s)
        end
        cache_value!(d,lowercase(s), m)
        return m
    end
end

Base.keys(d::dynamic_block) = begin
    real_keys = keys(get_datablock(d))
    cache_keys = keys(d.value_cache)
    return union(real_keys,cache_keys)
end

# While the original get_loop is almost perfect for our uses, it
# will call getindex and therefore start deriving missing data names
# if the data file explicitly contains missing values.
#
# CrystalInfoFramework.get_loop(d::dynamic_block,s::String) = begin

# This method actively tries to derive default values
CrystalInfoFramework.get_default(d::dynamic_block,s::String) = begin
    dict = get_dictionary(d)
    def_vals = CrystalInfoFramework.get_default(dict,s)
    target_loop = CategoryObject(d,find_category(dict,s))
    if !ismissing(def_vals)
        return [def_vals for i in target_loop]
    end
    # is there a derived default available?
    if !haskey(dict.def_meths,(s,"enumeration.default"))
        add_definition_func!(dict,s)
    end
    func_code = get_def_meth(d,s,"enumeration.default")
    return [Base.invokelatest(func_code,d,p) for p in target_loop]
end


#==Derive all values in a loop for the given
dataname==#

derive(d::dynamic_block,s::String) = begin
    println("###\n\n    Deriving $s\n#####")
    dict = get_dictionary(d)
    if !(has_func(dict,s))
        add_new_func(dict,s)
    end
    func_code = get_func(dict,s)
    target_loop = CategoryObject(d,find_category(dict,s))
    [Base.invokelatest(func_code,d,p) for p in target_loop]
end

#== Per packet derivation

This is called from within a dREL method when an item is
found missing from a packet.
==#
    
derive(d::dynamic_block,cat::String,obj::String,p::CatPacket) = begin
    dict = get_dictionary(d)
    dataname = get_by_cat_obj(dict,(cat,obj))["_definition.id"][1]
    if !(has_func(dict,dataname))
        add_new_func(dict,dataname)
    end
    func_code = get_func(dict,dataname)
    Base.invokelatest(func_code,d,p)
end

# For a single row in a packet
CrystalInfoFramework.get_default(cp::CatPacket,obj::Symbol) = begin
    dict = get_dictionary(cp)
    block = get_datablock(cp)
    mycat = get_name(cp)
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


#== We redefine getproperty to allow derivation inside category
packets.  If the property is missing, we populate the original
data frame with a column of 'missing' values, so that each 
subsequent packet can set the particular value it refers to.
==#

Base.getproperty(cp::CatPacket,obj::Symbol) = begin
    raw_table = parent(getfield(cp,:dfr))
    result = missing
    try
        result = getproperty(getfield(cp,:dfr),obj)
    catch KeyError
        # populate the column with 'missing' values
        full_length = size(raw_table,1)
        println("$obj is missing, adding $full_length missing values")
        # explicitly set type otherwise DataFrames thinks it is Missing only
        new_array = Array{Union{Missing,Any},1}(missing,full_length)
        d = get_datablock(cp)
        setproperty!(raw_table,obj, new_array)
    end
    if !ismissing(result)
        return result
    end
    #println("$(getfield(cp,:dfr)) has no member $obj:deriving...")
    # So we have to derive
    # get the parent container with dictionary
    db = get_datablock(cp)
    m = derive(db,get_name(cp),String(obj),cp)
    if ismissing(m)
        m = CrystalInfoFramework.get_default(cp,obj)
    end
    # store the cached value
    row_no = parentindices(getfield(cp,:dfr))[1]
    raw_table[row_no,obj] = m
    println("All values for $obj: $(raw_table[!,obj])")
    return m
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
            ft,r = find_target(r,a,targ)
            if ft != nothing
                att_name = "$(ft[1]).$(ft[2])"
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

lookup_default(dict,dataname,cp) = begin
    index_name = get(dict[dataname],"_enumeration.def_index_id",[missing])[1]
    if ismissing(index_name) return missing
    end
    object_name = dict[index_name]["_name.object_id"][1]
    current_val = getproperty(cp,Symbol(object_name))
    print("Indexing $dataname using $current_val to get")
    # Now index into the information
    indexlist = dict[dataname]["_enumeration_default.index"]
    pos = indexin([current_val],indexlist)
    if pos[1] == nothing return missing end
    as_string = dict[dataname]["_enumeration_default.value"][pos[1]]
    println(" $as_string")
    return get_julia_type(dict,dataname,[as_string])[1]
end
