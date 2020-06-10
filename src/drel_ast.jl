
export ast_fix_indexing,fix_scope,find_target, cat_to_packet, get_all_datanames

#==
For simplicity, the Python-Lark transformer does not annotate
any types except for the function return type. The following routine
traverses an expression, and inserts the appropriate types

Any category assignments are done using a separate
equals statement, so we record those as they happen. An AST
node is a two-element structure, where the first element is
the type and the second element is an array of arguments.

The following code updates a dictionary of assignments,
and in parallel appends type information when a getindex
call corresponds to a known category/object combination.

If a value is checked against missing, we drop the type assertion as
it will fail before the check is carried out. We skip annotation
inside calls of 'ismissing' in order to do this.

==#
# Keep a track of assignments, and assign types
# Each case has implications for the assignment dictionary
# and for the filtered AST.

ast_assign_types(ast_node,in_scope_dict;lhs=nothing,cifdic=Dict(),set_cats=Array{String}[],all_cats=Array{String}[]) = begin
    #println("$ast_node: in scope $in_scope_dict")
    ixpr = :(:call,:f)  #dummy
    if typeof(ast_node) == Expr
        if ast_node.head == :(=) && typeof(ast_node.args[1]) == Symbol # simple assignment
            #println("Found assignment for $ast_node")
            lh = ast_node.args[1]
            if typeof(ast_node.args[2]) == Symbol && ast_node.args[2] != :missing #direct assignment, lets keep it
                rhs_symb = ast_node.args[2]
                if typeof(rhs_symb) == Expr && rhs_symb.head == :call
                    if rhs_symb.args[1] == :first_packet   #a Set category
                        in_scope_dict[lh] = rhs_symb.args[2].args[3]
                        #first_packet(CategoryObject(__datablock,<set category>))
                        #println("Assignment of $rhs_symb to $lh")
                    end
                elseif rhs_symb == :__packet
                    in_scope_dict[lh] = in_scope_dict[:__packet]
                    #println("__packet -> $lh")
                else
                    #println("Ignoring $lh = $rhs_symb")
                end
            end
            ixpr.head = ast_node.head
            ixpr.args = [ast_assign_types(x,in_scope_dict,lhs=lh,cifdic=cifdic,all_cats=all_cats) for x in ast_node.args]
            return ixpr
        elseif lhs != nothing && ast_node.head == :(::)
            if ast_node.args[2] in(:CifCategory,:CatPacket)
                in_scope_dict[lhs] = String(ast_node.args[1])
            end
            ixpr.head = ast_node.head
            ixpr.args = ast_node.args
            return ixpr
        elseif ast_node.head in [:for]
            new_scope_dict = deepcopy(in_scope_dict)
            #println("New scope!")
            ixpr.head = ast_node.head
            ixpr.args = [ast_assign_types(x,new_scope_dict,lhs=nothing,cifdic=cifdic,all_cats=all_cats) for x in ast_node.args]
            #println("At end of scope: $new_scope_dict")
            return ixpr
        # Following sections append type information
        elseif ast_node.head == :call && ast_node.args[1] == :getindex
            #println("Found call of getindex")
            if ast_node.args[2] in keys(in_scope_dict)
                # if assignment to '__packet', look further
                target_cat = in_scope_dict[ast_node.args[2]]
                if in_scope_dict[ast_node.args[2]] == "__packet"
                    target_cat = in_scope_dict[Symbol("__packet")]
                end
                #println("Looking up type for $target_cat")
                return ast_construct_type(ast_node,cifdic,target_cat,String(ast_node.args[3]))
            else  #normal indexing
                ixpr.head = ast_node.head
                ixpr.args = [ast_assign_types(x,in_scope_dict,lhs=nothing,cifdic=cifdic,all_cats=all_cats) for x in ast_node.args]
                ixpr.args[3] = :($(ixpr.args[3])+1)
                return ixpr
            end
        elseif ast_node.head == :call && ast_node.args[1] == :ismissing
            return ast_node    #no internal annotations if missing is allowed
        elseif ast_node.head == :ref
            #println("Found subscription")
            if ast_node.args[1] in keys(in_scope_dict)
                # if assignment to '__packet', look further
                target_cat = in_scope_dict[ast_node.args[1]]
                if in_scope_dict[ast_node.args[1]] == "__packet"
                    target_cat = in_scope_dict[Symbol("__packet")]
                end
                #println("Looking up type for $target_cat")
                return ast_construct_type(ast_node,cifdic,target_cat,String(ast_node.args[2]))
            elseif typeof(ast_node.args[1]) != Expr && String(ast_node.args[1]) in all_cats && lhs != nothing  #indexing category packet selection
                in_scope_dict[lhs] = String(ast_node.args[1])
                #println("Found assignment to indexed category $lhs -> $(in_scope_dict[lhs])")
            end
            ixpr.head = ast_node.head
            ixpr.args = [ast_assign_types(x,in_scope_dict,lhs=nothing,cifdic=cifdic,all_cats=all_cats) for x in ast_node.args]
            return ixpr
        elseif ast_node.head == :call && ast_node.args[1] == :drel_property_access
            if ast_node.args[2] in keys(in_scope_dict)
                # if assignment to '__packet', look further
                target_cat = in_scope_dict[ast_node.args[2]]
                if in_scope_dict[ast_node.args[2]] == "__packet"
                    target_cat = in_scope_dict[Symbol("__packet")]
                end
                #println("Looking up type for $target_cat")
                return ast_construct_type(ast_node,cifdic,target_cat,ast_node.args[3])
            elseif typeof(ast_node.args[2]) != Expr && String(ast_node.args[2]) in set_cats
                return ast_construct_type(ast_node,cifdic,String(ast_node.args[2]),String(ast_node.args[3]))
            else
                println("WARNING: property access using unrecognised object $(ast_node)")
                ixpr.head = ast_node.head
                ixpr.args = ast_node.args
                return ixpr
            end
        else
            ixpr.head = ast_node.head
            ixpr.args = [ast_assign_types(x,in_scope_dict,lhs=nothing,cifdic=cifdic,all_cats=all_cats) for x in ast_node.args]
            return ixpr
        end
    else    #Not an expression
        return ast_node
    end
end

#== A helper function to construct a type specification at the end of the supplied node
==#

ast_construct_type(ast_node,cifdic,cat,obj) = begin
    final_type,final_cont = get_julia_type_name(cifdic,cat,obj)
    if final_cont == "Single"
        #println("category $cat object $obj type $final_type")
        return :($ast_node::$final_type)
    end
    dims = get_dimensions(cifdic,cat,obj)
    if final_cont in ["Array","Matrix"]
        #println("category $cat object $obj type Array{$final_type} dims $dims")
        if length(dims) == 1   # a vector, every time!
            return :($ast_node::drelvector)
        end
        return :($ast_node::Array{$final_type,$(length(dims))})
    else
        println("Type specification too complex or unproductive, ignoring")
        return ast_node
    end
end
    
#== 

dREL uses 0-based indexing, but Julia uses 1-based indexing. We trawl through
the AST to find any index-type expressions. While this macro is similar to the one that assigns
types, we keep it separate for maintainability.  ``In_scope_list`` should contain
a list of variable names that are in scope as category names or packets. We do
not touch slices, as are assumed to have been caught earlier.

If we find a category[object] reference where ``object`` is not a dictionary,
when convert it to a dictionary of form category_key => object.

This is further complicated by the problem that tables are referenced exactly like
dictionaries, so we must catch literal creation (checking for :Dict at the moment)
and references to dictionary items that are defined to be Table type. 

The form `__datablock[String]` refers to a category from the datablock and should
be ignored.
==#

ast_fix_indexing(ast_node,in_scope_list::Array{String,1},cifdic;lhs=nothing) = begin
    #println("$ast_node: in scope $in_scope_list")
    ixpr = :(:call,:f)  #dummy
    if typeof(ast_node) == Expr
        if ast_node.head == :(=)
            # we only care if the final type is tagged as a categoryobject or is in scope
            println("Found assignment for $ast_node")
            lh = ast_node.args[1]
            # this is for the filtering
            ixpr.head = ast_node.head
            ixpr.args = [ast_fix_indexing(x,in_scope_list,cifdic,lhs=lh) for x in ast_node.args]
            if ixpr.args[2] == Symbol("__packet")
                push!(in_scope_list,String(lh))
            end
            return ixpr
        elseif lhs != nothing && ast_node.head == :(::)
            if ast_node.args[2] == :CifCategory
                push!(in_scope_list, String(lhs))
            end
            return ast_node
        # Find category construction (old style)
        elseif lhs != nothing && ast_node.head == :call && ast_node.args[1] in (:CifCategory,:(Dict{String,Any}))
            push!(in_scope_list,String(lhs))
            return ast_node
        # Find category access (new style)
        elseif lhs != nothing && ast_node.head == :ref && ast_node.args[1] == :__datablock
            println("Found category lookup for $(ast_node.args[2])")
            push!(in_scope_list,String(lhs))
            return ast_node
        elseif ast_node.head in [:for]
            new_scope_list = deepcopy(in_scope_list)
            println("New scope!")
            ixpr.head = ast_node.head
            ixpr.args = [ast_fix_indexing(x,new_scope_list,cifdic,lhs=nothing) for x in ast_node.args]
            println("At end of scope: $new_scope_list")
            return ixpr
        # Fix the actual indexing
        elseif ast_node.head == :call && ast_node.args[1] == :getindex
            println("Found call of getindex")
            ixpr.head = ast_node.head
            ixpr.args = [ast_fix_indexing(x,in_scope_list,cifdic,lhs=nothing) for x in ast_node.args]
            if !(String(ast_node.args[2]) in in_scope_list)
                ixpr.args[3] = :($(ixpr.args[3])+1)
            else  #a bona-fide dREL packet selection!
                println("Expanding key-based indexing for $(ast_node.args[2])")
                keyname = get_single_keyname(cifdic,String(ast_node.args[2]))
                ixpr.args[3] = :(Dict($keyname=>$(ixpr.args[3])))
            end
            return ixpr
        elseif ast_node.head == :ref
            println("Found subscription: $(ast_node.args)")
            ixpr.head = ast_node.head
            ixpr.args = [ast_fix_indexing(x,in_scope_list,cifdic,lhs=nothing) for x in ast_node.args]
            # The logic here: if the subject of the subscription is a known category object,
            # then do not + 1. Otherwise, it must be a plain old array dereference, and
            # one should be added. If the subject of the subscription is itself an
            # expression, then we must have a category dereference and can ignore it.
            if typeof(ast_node.args[1])!= Expr && !(String(ast_node.args[1]) in in_scope_list)
                #println("Checking node $(ixpr.args[2])")
                if typeof(ixpr.args[2]) ==  Expr && ixpr.args[2].head == :call && ixpr.args[2].args[1] == :(:)
                    ixpr.args[2].args[2] = :($(ixpr.args[2].args[2])+1)
                    # no need to adjust endpoint as Julia is inclusive, dREL is exclusive
                else  # multi-indexing, has anything been missed?
                    for i in 2:length(ixpr.args)
                        ixpr.args[i] = :($(ixpr.args[i])+1)
                    end
                end
            elseif lhs != nothing
                #the subscripted item is known to us, if we have an assignment store it
                #println("Expanding key-based indexing for $(ast_node.args[1])")
                #keyname = get_single_keyname(cifdic,String(ast_node.args[1]))
                #ixpr.args[2] = :(Dict($keyname=>$(ixpr.args[2])))
            end
            return ixpr
        else          
            ixpr.head = ast_node.head
            ixpr.args = [ast_fix_indexing(x,in_scope_list,cifdic,lhs=nothing) for x in ast_node.args]
            return ixpr
        end
    else #not an expression node
        return ast_node
    end
end

#== A function to detect instances of the target dataname

Unfortunately the Lark parser only discovers category aliases
after the body has been processed, so it is impossible to
substitute in the return variable. So we do that in this function.
Furthermore, where the target is directly assigned to a 
square-bracketed expression, that expression is coerced to a
Matrix if the dictionary type is Matrix or Array.  This is in
keeping with dREL rules. Nothing else defined in the dictionary
can be assigned in a dREL method, and all other uses must be
explicit as to whether a matrix is being used.

To enable use in discovering the target in definition methods,
we return any names found.
==#

find_target(ast_node,alias_name,target_obj;is_matrix=false) = begin
    found_target = nothing
    ixpr = :(:call,:f)  #dummy
    if typeof(ast_node) == Expr && ast_node.head == :(=)
        ixpr.head = ast_node.head
        found_target,ixpr.args[1] = find_target(ast_node.args[1],alias_name,target_obj)
        if ixpr.args[1] == :__dreltarget
            found_target = :__dreltarget
            if is_matrix
                if typeof(ast_node.args[2]) == Expr && ast_node.args[2].head == :vect
                    println("Fixing implicit matrix assignment")
                    ixpr.args[2] = :(to_julia_array($(ast_node.args[2])))
                else
                    ixpr.args[2] = ast_node.args[2]
                end
            else
                ixpr.args[2] = ast_node.args[2]
            end
        else
            ixpr.args[2] = ast_node.args[2]  #no need to search for target on RHS
        end
        return found_target,ixpr
    elseif typeof(ast_node) == Expr && (ast_node.head == :ref ||
                                        ast_node.head == :(.))
        if ast_node.args[1] == Symbol(alias_name)
            println("Found potential target! $ast_node for alias $alias_name.$target_obj")
            if typeof(ast_node.args[2]) == QuoteNode && ast_node.args[2].value == Symbol(lowercase(target_obj)) 
                return (alias_name,target_obj),:__dreltarget
            else
                return found_target,ast_node
            end
        else
            return found_target,ast_node
        end
    elseif typeof(ast_node) == Expr && ast_node.head == :call && ast_node.args[1] == :drel_property_access
        if ast_node.args[2] == alias_name
            println("Found potential target! $ast_node for alias $alias_name.$target_obj")
            if typeof(ast_node.args[3]) == QuoteNode && ast_node.args[3].value == lowercase(target_obj) 
                return (alias_name,target_obj),:__dreltarget
            else
                return found_target,ast_node
            end
        else
            return found_target,ast_node
        end
    elseif typeof(ast_node) == Expr
        ixpr.head = ast_node.head
        argresult = [find_target(x,alias_name,target_obj,is_matrix=is_matrix) for x in ast_node.args]
        ixpr.args = [a[2] for a in argresult]
        found_target = [a[1] for a in argresult if a[1] != nothing]
        if length(found_target)==1
            found_target = found_target[1]
        else
            found_target = nothing
        end
        return found_target,ixpr
    else
        return found_target,ast_node
    end
end

#== A function to detect assignments inside code blocks. As dREL
follows Python behaviour and considers that variables in do loops
exist beyond the end of the do loop, and that subsequent iterations
refer to the same variables assigned in previous iterations, we must
lift all variable assignments to the outer level.  We find all
assignments and assign to 'missing' at the top of the provided
block. Note that this assumes code from dREL in that we can assume no
global variables and no assignments to dictionary datanames (because
that is forbidden), and no use of the "local" keyword as we do not do
that when generating Julia code. 

The ast node passed to the routine should begin with a function
definition ==#

fix_scope(ast_node) = begin
    if !(((ast_node.head == :(=) && ast_node.args[1].head == :call)||
         (ast_node.head == :-> && ast_node.args[1].head == :tuple))
         && ast_node.args[2].head == :block) 
        return ast_node
    end
    enclosing = :()
    enclosing.head = ast_node.head
    enclosing.args = []
    push!(enclosing.args,ast_node.args[1])
    all_assignments = unique(collect_assignments(ast_node.args[2]))
    ixpr = :(begin end)
    for s in all_assignments
        push!(ixpr.args,:($s = missing))
    end
    # debugging printout
    # push!(ixpr.args,:(println("__packet is $__packet")))
    for a in ast_node.args[2].args
        push!(ixpr.args,a)
    end
    push!(enclosing.args,ixpr)
    return enclosing
end

collect_assignments(ast_node) = begin
    assigns = []
    if typeof(ast_node) == Expr && ast_node.head == :(=)   #assignment
        # Store new local variable if not already defined
        # Don't care about double assignment
        if typeof(ast_node.args[1]) == Symbol
            push!(assigns,ast_node.args[1])
        end
    elseif typeof(ast_node) == Expr
        for i in 1:length(ast_node.args)
            append!(assigns,collect_assignments(ast_node.args[i]))
        end
    end
    return assigns
end

#==
Set category packets can be referenced directly without any looping
statement. Our transformer accesses a category object for every category
mentioned, but does not know about Set categories. We do, and so we
catch the DDLmCategory creation and create a CatPacket. We must change
the type of any subsequent assignments.

NB: nested CategoryObject calls will fail. Should not exist. ==#

cat_to_packet(ast_node,set_cats) = begin
    ixpr = :()
    if typeof(ast_node) == Expr && ast_node.head == :ref && ast_node.args[1] == :__datablock
        ixpr.head = ast_node.head
        if ast_node.args[2] in set_cats
            ixpr = :(first_packet($ast_node))
        else
            ixpr.args = [cat_to_packet(x,set_cats) for x in ast_node.args]
        end
    elseif typeof(ast_node) == Expr && ast_node.head == :(::)
        ixpr.head = ast_node.head
        #println("$(ast_node.args[2]),$(ast_node.args[1])")
        if ast_node.args[2] == :CifCategory && String(ast_node.args[1]) in set_cats
            #println("Bazinga!")
            ixpr.args = [ast_node.args[1],:CatPacket]
        else
            ixpr.args = ast_node.args
        end
    elseif typeof(ast_node) == Expr
        ixpr.head = ast_node.head
        ixpr.args = [cat_to_packet(x,set_cats) for x in ast_node.args]
    else
        return ast_node
    end
    return ixpr
end

#==

 Return a list of data names whose values are referenced in the completely-
 transformed dREL code. Similar to ast_assign_types. found_cats should be
initialised with one entry "__packet" => name of category. This routine
adds to this dictionary whenever a category is assigned to a variable,
so variable => category_name

An assignment will shuffle around the name of a category. We catch the
first assignment only.

==#

get_all_datanames(ast_node,found_cats,set_cats,all_cats) = begin
    println("###\n\n $ast_node \n\n####")
    dn_list = Tuple{String,String}[]
    calc_cat = found_cats[Symbol("__packet")]
    if typeof(ast_node) == Expr
        if ast_node.head == :(=) && typeof(ast_node.args[1]) == Symbol
            lh = ast_node.args[1]
            # Check for set category assignments
            rhs_symb = ast_node.args[2]
            if typeof(rhs_symb) == Expr
                if rhs_symb.head == :call
                    if rhs_symb.args[1] == :first_packet   #a Set category
                        found_cats[lh] = rhs_symb.args[2].args[3]
                        #first_packet(CategoryObject(__datablock,<set category>))
                        println("Assignment of $(found_cats[lh]) to $lh")
                    elseif rhs_symb.args[1] == :CifCategory  #Loop category
                        found_cats[lh] = rhs_symb.args[3]
                        println("Assignment of $(found_cats[lh]) to $lh")
                    end
                end
                map(q -> append!(dn_list,q),
                    [get_all_datanames(x,found_cats,set_cats,all_cats) for x in ast_node.args])
            elseif typeof(rhs_symb) == Symbol && String(rhs_symb) in all_cats
                found_cats[lh] = String(rhs_symb)
                println("Assignment of $rhs_symb to $lh")
            elseif rhs_symb == :__packet
                found_cats[lh] = calc_cat
                println("__packet -> $lh")
            else
                println("Warning: ignoring $rhs_symb")
            end
        elseif ast_node.head in [:for]
            map(q -> append!(dn_list,q),
                [get_all_datanames(x,found_cats,set_cats,all_cats) for x in ast_node.args])
        # handle subscriptions
        # Example: (atom_type_scat[a.type_symbol]).dispersion    
        elseif ast_node.head == :call && ast_node.args[1] == :getindex
            if ast_node.args[2] in keys(found_cats)
                # if assignment to '__packet', look further
                target_cat = found_cats[ast_node.args[2]]
                push!(dn_list,(target_cat,String(ast_node.args[3])))
                return dn_list
            else  #normal indexing
                map(q -> append!(dn_list,q),
                    [get_all_datanames(x,found_cats,set_cats,all_cats) for x in ast_node.args])
            end
        elseif ast_node.head == :ref
            if ast_node.args[1] in keys(found_cats)
                target_cat = found_cats[ast_node.args[1]]
                push!(dn_list,(target_cat,String(ast_node.args[2])))
                # TODO: multi-index packet selection
            end
            map(q -> append!(dn_list,q),
                [get_all_datanames(x,found_cats,set_cats,all_cats) for x in ast_node.args])
        elseif ast_node.head == :call && ast_node.args[1] == :drel_property_access
            if ast_node.args[2] in keys(found_cats) #a variable
                target_cat = found_cats[ast_node.args[2]]
                push!(dn_list,(target_cat,String(ast_node.args[3].value)))
            elseif typeof(ast_node.args[2])!= Expr && String(ast_node.args[2]) in set_cats
                push!(dn_list,(String(ast_node.args[2]),ast_node.args[3]))
            elseif typeof(ast_node.args[2])==Expr
                # dig out expressions of form "(a[b]).c"
                sub_expr = ast_node.args[2]
                if sub_expr.head == :ref
                    if sub_expr.args[1] in keys(found_cats)
                        # if assignment to '__packet', look further
                        target_cat = found_cats[sub_expr.args[1]]
                        push!(dn_list,(target_cat,ast_node.args[3]))
                        return dn_list
                    end
                end
                map(q -> append!(dn_list,q),
                    [get_all_datanames(x,found_cats,set_cats,all_cats) for x in ast_node.args[2:end]])
            end
        else
            map(q -> append!(dn_list,q),
                [get_all_datanames(x,found_cats,set_cats,all_cats) for x in ast_node.args])
        end
    else
        #println("Non-expr node $ast_node ; ignored")
    end
    #println("Returning $dn_list")
    return dn_list
end
