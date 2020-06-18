#==

Introduction
============

The Lerche grammar system allows 'Transformer' functions to be defined. Each transformer
is named after a node in the parse tree, and takes the contents of the node as an
argument.  The transformers in this file transform the parse tree into a piece of
Julia code assuming the following environment:

1. The entire dREL method becomes a Julia function definition that takes a Category
   representing the category in which the definition appears.
   This allows the function to be 'mapped' over the category if necessary.

2. The outer function also takes a cif data block object with a specified interface.

3. The CIF interactions are mediated by the CrystalInfoFramework package.
   
The transformer methods will assume that any interior nodes have already been processed.

==#

@rule_holder

@contains_rules mutable struct TreeToJulia <: Transformer
    target_cat::String
    target_object::String
    is_func::Bool
    is_validation::Bool
    cat_list::Array{String}
    att_dict::Dict
    func_list::Array
    cat_ids::Set{String}
    target_category_alias::Symbol
    ddlm_cats::Set
    aug_assign_table::Dict{String,Function}
end

TreeToJulia(dataname,data_dict;is_validation=false,att_dict=Dict()) = begin
    target_cat = find_category(data_dict,dataname)
    target_object = data_dict[dataname]["_name.object_id"][1]
    func_cat,func_list = get_dict_funcs(data_dict)
    is_func = target_cat == func_cat
    cat_list = get_categories(data_dict)
    TreeToJulia(target_cat,target_object,is_func,is_validation,
                cat_list,att_dict,func_list,Set(),Symbol(target_cat),
                Set(),Dict("++="=>push!,"--="=>error))
end

# For testing, a default
TreeToJulia() = begin
    TreeToJulia("dummy","dummer",true,false,["a","b","c"],Dict(),[],Set(),"dummy",
                Set(),Dict())
end

#== The top level

When the final "input" item is encountered, we already have 
a fully-transformed parse tree

==#

@inline_rule input(t::TreeToJulia,arg) = begin
    if t.is_func return arg end
    header = Expr(:block,:(__dict=get_dictionary(__datablock)))
    for c in t.cat_ids
        push!(header.args,
              :($(Symbol(c)) = get_category(__datablock,$c))
              )
    end
    push!(header.args,arg)
    push!(header.args,:(return __dreltarget))
    final_expr = quote
        (__datablock::DynamicRelationalContainer,__packet::CatPacket) -> $header
    end
    return final_expr
end

# A function definition is an anonymous function
@inline_rule funcdef(t::TreeToJulia,f,id,args,suite) = begin
    println("Function body:\n$suite")
    @assert suite.head == :block
    reverse!(suite.args)
    for c in t.cat_ids
        push!(suite.args,Expr(Symbol("="),Symbol(c), :(get_category(__datablock,$c))))
    end
    push!(suite.args,Expr(Symbol("="),Symbol("__dict"),:(get_dictionary(__datablock))))
    if !ismissing(id)
        push!(suite.args,Expr(:call,:println,:(String("Entered function ")),String(id)))
    end
    reverse!(suite.args)
    push!(suite.args, :(return $id))
    println("New function body:\n$suite")
    func_def = :(($(args...),__datablock::DynamicRelationalContainer)-> $suite)
    return func_def
end
    
#== From literals to expressions

Our adherence to auto-generated grammars based on EBNF means that
we cannot insert aliases easily for literal transformation. That
happens here. Note that we parse in integers as they will not
have matched with reals if they reach this rule.

 ==#

@inline_rule literal(t::TreeToJulia,s) = begin
    if !(s isa Token)
        return s
    end
    v = s.value
    output = s
    if s.type_ == "LONGSTRING"
        output = :($(v[4:end-3]))
    elseif s.type_ == "SHORTSTRING"
        output = :($(v[2:end-1]))
    elseif s.type_ in ("HEXINT","OCTINT","BININT","INTEGER")
        output = :($(Base.parse(Int64,v)))
    elseif s.type_ == NULL
        output = :(nothing)
    elseif s.type_ == MISSING
        output = :(missing)
    end
    return output
end

@rule real(t::TreeToJulia,r) = begin
    println("Real rule, passed $r")
    extra = length(r)
    if r[end-1] == "-"
        extra = length(r)-2
    end
    full_text = join(r[1:extra],"")
    if extra < length(r)
        full_text *= "e"*r[end-1]*r[end]
    end
    return :($(Base.parse(Float64,full_text)))
end

@inline_rule imaginary(t::TreeToJulia,r) = begin
    if r isa Token # so an integer terminal
        return :($(Complex(0,Base.parse(Float64,r))))
    else
        return :($(Complex(0,r)))
    end
end

@inline_rule ident(t::TreeToJulia,id) = begin
    println("Identifier: $id")
    lid = lowercase(id)
    if lid == "twopi"
        return :(2π)
    elseif lid == "pi"
        return :(π)
    end
    if id[1] == "_"
        id = id[2:end]
        lid = lid[2:end]
    end
    # catch category references
    if lid in t.cat_list && id != t.target_cat
        push!(t.cat_ids,String(id))
    end
    if id == t.target_cat
        id = :__packet
    else
        id = Symbol(id)
    end
    return id
end

@rule id_list(t::TreeToJulia,idl) = begin
    if length(idl) == 1
        return idl[1]
    else
        @assert typeof(idl) == Array
        return idl   #already a list
    end
end

@inline_rule enclosure(t::TreeToJulia,arg) = arg
@inline_rule primary(t::TreeToJulia,arg) = arg
@inline_rule att_primary(t::TreeToJulia,arg) = arg

# Do we even need parenth forms in dREL now that tuples
# are gone?
@inline_rule parenth_form(t::TreeToJulia,_,arg,_) = begin
    println("Passed $arg")
    final = if length(arg) == 1 arg[1] else arg end
    println("Returning $final")
    return final
end


# Lists are arrays

@rule list_display(t::TreeToJulia,args) = begin
    if length(args) == 2
        return :([])
    else
        return :([$(args[2]...)])
    end
end


#== Tables

==#
@inline_rule table_entry(t::TreeToJulia,key,colon,value) = :($key=>$value)

@rule table_contents(t::TreeToJulia,args) = args

@inline_rule table_display(t::TreeToJulia,lbr,contents,rbr) = begin
    return :(Dict($contents...))
end
                         
@rule arith(t::TreeToJulia,args) = begin
    if length(args) == 1
        return args[1]
    else
        return fix_mathops(args[2],(args[1],),(args[3],))
    end
end

@rule factor(t::TreeToJulia,args) = begin
    if length(args) > 1
        if args[1] == "+" return args[2] else return :(-1*$(args[2])) end
    end
    return args[1]
end

@rule power(t::TreeToJulia,args) = begin
    if length(args) == 1 return args end
    return :($(args[1])^$(args[end]))
end

@rule term(t::TreeToJulia,args) = begin
    if length(args) > 1 return fix_mathops(args[2],(args[1],),(args[3],))
    end
    return args[1]
end

@inline_rule restricted_comp_operator(t::TreeToJulia,op) = op
@rule comp_operator(t::TreeToJulia,args) = begin
    if length(args) == 2  # not in
        return [:not,:in]
    else
        return [Symbol(args[1])]
    end
end

# Have to rearrange 'not in' expressions. Our comparisons are still
# strings at this point
@rule comparison(t::TreeToJulia,args) = begin
    if length(args) > 1   #so not a straight pass through
        if length(args[2]) == 2  # "not in"
            return Expr(:call,:!,Expr(:call,args[2][2],args[1],args[3]))
        else
            return Expr(:call,args[2][1],args[1],args[3])
        end
    end
    return args[1]
end

@rule not_test(t::TreeToJulia,args) = begin
    if length(args) == 1
        return args[1]
    end
    return Expr(:call,:!,args[2:end]...)
end

@rule and_test(t::TreeToJulia,args) = begin
    if length(args) == 1
        return args[1]
    else
        return Expr(:&&, args[1],args[3])
    end
end

@rule or_test(t::TreeToJulia,args) = begin
    if length(args) == 1
        return args[1]
    else
        return :($(args[1])||$(args[3]))
    end
end

@inline_rule subscription(t::TreeToJulia,a,b) = begin
    if b isa Array    #slice list
        return Expr(:ref,a,b...)
    else
        return Expr(:ref,a,b)
    end
end

@inline_rule dotlist_element(t::TreeToJulia,a,b) = :($a=>$b)

@rule dotlist(t::TreeToJulia,args) = :(Dict($args))

@inline_rule attributeref(t::TreeToJulia,a,b) = begin
    println("Attribute ref: $a . $b")
    println("Watching for $(t.target_category_alias) . $(t.target_object)")
    if (a == :__packet || a == t.target_category_alias) &&
        b == t.target_object
        return :__dreltarget
    else
        return :(drel_property_access($a,$(lowercase(b)),__datablock))
    end
end

    
@inline_rule expression(t::TreeToJulia,arg) = arg

# An expression list is a real list of expressions
@rule expression_list(t::TreeToJulia,args) = begin
    result = filter(x-> x!= ",",args)
    println("After expression list: $result")
    return result
end


@inline_rule augop(t::TreeToJulia,arg) = arg.value

@inline_rule assignment(t::TreeToJulia,lhs,op,rhs) = begin
    actual_op = op
    if !(op in ("=","+=","-="))
        actual_op = t.aug_assign_table[op]
    end
    if length(lhs) == length(rhs) == 1
        result = Expr(Symbol(actual_op),lhs[1],rhs[1])
    else
        result = Expr(Symbol(actual_op),Expr(:tuple,lhs...),Expr(:tuple,rhs...))
    end
    println("$result")
    return result
end
                 
@inline_rule lhs(t::TreeToJulia,a) = a

@inline_rule rhs(t::TreeToJulia,a) = a

@inline_rule att_primary(t::TreeToJulia,arg) = begin
    println("Att_primary: $arg")
    return arg
end


# Slicing

@inline_rule long_slice(t::TreeToJulia,ss,colon, expr) = begin
    ss["step"] = expr
    return ss
end

@rule short_slice(t::TreeToJulia,args) = begin
    if length(args) == 1   # a colon
        return Dict("start"=>0,"stop"=>:end)
    elseif length(args) == 3   #start,end
        return Dict("start"=>args[1],"stop"=>args[3])
    elseif length(args) == 2 && args[1] == ":"
        return Dict("start"=>0,"stop"=>args[1])
    end
    return Dict("start"=>args[1],"stop"=>:end)
end

@inline_rule proper_slice(t::TreeToJulia,arg) = begin
    step = get(arg,"step",1)
    start = arg["start"]
    if step != 1
        return Expr(:call,Symbol(":"),start,step,arg["stop"])
    end
    return Expr(:call,Symbol(":"),start,arg["stop"])
end

# Filter out the commas
@rule slice_list(t::TreeToJulia,args) = begin
    return filter(x->x!=",",args)
end

#== Functions.  

A function call may invoke a built-in function, so we have
to convert these to known Julia functions. However, list/array construction
in Julia is accomplished simply by using square brackets, so we special-case
these functions. Also, as Julia has multiple dispatch, we don't need to
annotate type as a new function will be compiled for each type set
encountered.

We preserve case for dictionary-defined functions, not sure if this
is correct. As the function call is defined by the _name.object_id, and
this is type "code", it should be caseless?

==#
@rule call(t::TreeToJulia,args) = begin
    println("Call: $args")
    func_name = lowercase(String(args[1]))
    if func_name in ["list","array"]
        if length(args) == 3
            return :([])
        else
            return :(Array($(args[3]...)))
        end
    end
    # Dictionary-defined functions
    if func_name in t.func_list
        return :(get_func(__dict,$(func_name))($(args[3]...),__datablock))
    end
    if length(args) == 3
        return transform_function_name(func_name,[])
    end
    return transform_function_name(func_name,args[3])
end


# Statements

@rule simple_statement(t::TreeToJulia,args) = begin
    println("A simple statement: $args")
    if length(args) == 1
        return args[1]
    else
        println("Wrapping in a block: $args")
        return Expr(:block,args...)
    end
end

@inline_rule small_statement(t::TreeToJulia,arg) = begin
    if arg isa Expr return arg end
    if arg.type_ == "BREAK"
        return :(break)
    elseif arg.type_ == "NEXT"
        return :(continue)
    else
        error("Unimplemented rule: $arg")
    end
end

@inline_rule statement(t::TreeToJulia,arg) = arg

@rule statements(t::TreeToJulia,args) = begin
    if length(args) == 1 return args[1] end
    if args[1] isa Expr && args[1].head == :block
        println("Statements: adding to end of block $args")
        push!(args[1].args,args[2])
        return args[1]
    end
    return Expr(:block,args...)
end

# Compound statements

@inline_rule compound_statement(t::TreeToJulia,arg) = arg

@rule arglist(t::TreeToJulia,arg) = begin
    if length(arg) == 1 return arg end
    push!(arg[1],arg[3])
end

@inline_rule one_arg(t::TreeToJulia,id,first,second) = begin
    return Symbol(id)  #drop the annotations
end

# Suite is a list of arguments
@rule suite(t::TreeToJulia,args) = begin
    println("suite: Processing $args")
    if args[1] isa Expr
        @assert length(args) == 1
        println("One stmt only: $(args[1].head)")
        if args[1].head == :block
            return args[1]
        end
    end
    return Expr(:block,args...)
end


@rule if_stmt(t::TreeToJulia,args) = begin
    basic_if = Expr(:if,args[2],args[3])
    current_level = basic_if.args
    if length(args) > 3  # else_if or else
        for one_expr in args[4:end]
            push!(current_level,one_expr)
            if one_expr.head == :block
                break
            else
                @assert one_expr.head == :elseif
                current_level = current_level[end].args
            end
        end
    end
    println("If stmt: $basic_if")
    return basic_if
end

@inline_rule else_stmt(t::TreeToJulia,e,else_suite) = begin
    return else_suite
end

@inline_rule else_if_stmt(t::TreeToJulia,_,expr,suite) = begin
    return Expr(:elseif, Expr(:block, expr), suite)
end

@inline_rule for_stmt(t::TreeToJulia,_,idl,expr_list,suite) = begin
    forblock = Expr(:for,:(($idl),copy($expr_list)),suite)
    return forblock
end

@inline_rule repeat_stmt(t::TreeToJulia,_,suite) = Expr(:while,true,suite)

@rule do_stmt(t::TreeToJulia,args) = begin
    increment = if length(args) > 5 args[6] else 1 end
    return Expr(:for,
                Expr(:(=),args[2],Expr(:call,:(:),args[3],increment,args[4])),args[end])
end

@inline_rule with_stmt(t::TreeToJulia,_,id1,_,id2,suite) = begin
    type_annot = :Any
    if id2 != :__packet
        return :($id1 = $id2::CifCategory;$suite)
    else
        t.target_category_alias = id1
        return :($id1 = $id2;$suite)
    end
end

@rule loop_stmt(t::TreeToJulia,args) = begin
    return Expr(:for, Expr(:(=),args[2], args[4]), args[end])
end
    
fix_mathops(op,left,right) = begin
    op = op.value
    if op == "^"
        return :(cross($(left...),$(right...)))
    elseif occursin(op, "+-/")
        enhanced = "."*op
        return :($(Symbol(enhanced))($(left...), $(right...)))
    else
        return :($(Symbol(op))($(left...), $(right...)))
    end
end

#==

Utility functions

==#
                               
#== Changing dREL to Julia function calls ==#

transform_function_name(in_name,func_args) = begin
    builtins = Dict(
        "table"=>:(Dict{String,Any}),
                "len"=> :length,
                "abs"=> :abs,
                "magn"=> :abs,
                "str"=> :str,
                "norm"=> :norm,
                "sqrt"=> :sqrt,
                "exp"=> :exp,
                "complex"=> :complex,
                "max"=> :max,
                "min"=> :min,
                "current_row"=> :current_row,
                "float"=> :Float64,
                "strip"=> :drel_strip,
                "eigen"=> :drel_eigen,
      "sind"=> :sind,
      "cosd"=> :cosd,
      "tand"=> :tand,
      "asind"=> :asind,
      "acosd"=> :acosd,
      "atand"=> :atand,
                "repr"=> :string,
      "transpose"=> :permutedims
    )
    test_name = lowercase(in_name)
    target_name = get(builtins,test_name,nothing)
    if target_name != nothing
        return Expr(:call,target_name,func_args...)
        #return :($(Symbol(target_name))($(func_args...)))
    elseif test_name == "matrix"  #custom Julia creation
        return :(to_julia_array($(func_args...)))
    elseif test_name == "atoi"
        return :(parse(Int64,$(func_args...)))
    elseif test_name == "int"
        return :(floor.(Int64,$(func_args...)))
    elseif test_name == "mod"
        return :(broadcast(mod,$(func_args...)))
    elseif test_name == "upper"
        return :(uppercase($(func_args...)))
    elseif test_name == "expimag"
        return :(exp(1im*$(func_args...)))
    elseif test_name in ["real","imag"]
        return :(($(func_args...)).$(Symbol(test_name)))
    elseif test_name == "sort"
        return :(sort!($(func_args...)))
    end
    println("Going with plain $in_name, $(func_args...)")
    return Expr(:call,Symbol(in_name),func_args...)   #dictionary defined
end