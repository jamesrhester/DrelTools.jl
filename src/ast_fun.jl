# Test function to check our filtering. We are either called on an
# expression, or on an argument to an expression.
module testdrel

ast_filter(ast_node, new_head = nothing) = begin
    if typeof(ast_node) == Expr
        # process based on head
        # process arguments
        ixpr = Expr(:call,[1])  #dummy
        if new_head != nothing
            ixpr.head = new_head
        else
            ixpr.head = ast_node.head
        end
        ixpr.args = [ast_filter(x) for x in ast_node.args]
        return ixpr
    else
        ixpr = ast_node
        return ixpr
    end
end

# change all pluses to minuses

ast_replace_plus(ast_node) = begin
    if typeof(ast_node) == Expr
        # process based on head
        # process arguments
        ixpr = Expr(:call,[1])  #dummy
        ixpr.head = ast_node.head
        ixpr.args = [ast_replace_plus(x) for x in ast_node.args]
        return ixpr
    elseif ast_node == :+
        return :-
    end
    return ast_node
end

# change all occurrences of a particular symbol

ast_replace_symbol(ast_node,a_symbol) = begin
    if typeof(ast_node) == Expr
        # process based on head
        # process arguments
        ixpr = Expr(:call,[1])  #dummy
        ixpr.head = ast_node.head
        ixpr.args = [ast_replace_symbol(x,a_symbol) for x in ast_node.args]
        return ixpr
    elseif ast_node == a_symbol
        return :new_symbol
    end
    return ast_node
end

ast_add_type(ast_node,a_symbol,a_type) = begin
    if typeof(ast_node) == Expr
        # process based on head
        # process arguments
        ixpr = Expr(:call,[1])  #dummy
        ixpr.head = ast_node.head
        ixpr.args = [ast_add_type(x,a_symbol,a_type) for x in ast_node.args]
        return ixpr
    elseif ast_node == a_symbol
        return :($a_symbol::$a_type)
    end
    return ast_node
end

# Match based on function call name
ast_find_and_add_type(ast_node,func_name,a_type) = begin
    if typeof(ast_node) == Expr && ast_node.head == :call && ast_node.args[1] == func_name
        # process based on head
        # process arguments
        println("Found match for $ast_node and $func_name")
        ixpr = :($ast_node::$a_type)
        return ixpr
    elseif typeof(ast_node) == Expr
        ixpr = Expr(:call,[1]) #dummy
        ixpr.head = ast_node.head
        ixpr.args = [ast_find_and_add_type(x,func_name,a_type) for x in ast_node.args]
        return ixpr
    end
    return ast_node
end

# Mimic scoping behaviour (no filtering at this point). We have an
# array of dictionaries corresponding to scopes.

ast_mimic_scopes(ast_node,in_scope_dict,lhs=nothing) = begin
    println("$ast_node: in scope $in_scope_dict")
    if typeof(ast_node) == Expr && ast_node.head == :(=)
        # we only care if the final type is tagged as a categoryobject
        println("Found assignment for $ast_node")
        lh = ast_node.args[1]
        [ast_mimic_scopes(x,in_scope_dict,lh) for x in ast_node.args[2:end]]
    elseif typeof(ast_node) == Expr && lhs != nothing && ast_node.head == :(::)
        if ast_node.args[2] == :CategoryObject
            in_scope_dict[end][lhs] = ast_node.args[1]
        end
    elseif typeof(ast_node) == Expr && ast_node.head in [:block,:for]
        new_scope_dict = vcat(in_scope_dict, Dict())
        println("New scope!")
        [ast_mimic_scopes(x,new_scope_dict,nothing) for x in ast_node.args]
        println("At end of scope: $new_scope_dict")
    else
        return ast_node
    end
end

# Now do both; keep a track of assignments, and assign types
# Each case has implications for the assignment dictionary
# and for the filtered AST.

ast_assign_types(ast_node,in_scope_dict,lhs=nothing,cifdic=Dict()) = begin
    println("$ast_node: in scope $in_scope_dict")
    ixpr = :(:call,:f)  #dummy
    if typeof(ast_node) == Expr && ast_node.head == :(=)
        # we only care if the final type is tagged as a categoryobject
        println("Found assignment for $ast_node")
        lh = ast_node.args[1]
        # this is for the filtering
        ixpr.head = ast_node.head
        ixpr.args = [ast_assign_types(x,in_scope_dict,lh,cifdic) for x in ast_node.args]
        return ixpr
    elseif typeof(ast_node) == Expr && lhs != nothing && ast_node.head == :(::)
        if ast_node.args[2] == :CategoryObject
            in_scope_dict[lhs] = ast_node.args[1]
        end
        ixpr.head = ast_node.head
        ixpr.args = ast_node.args
        return ixpr
    elseif typeof(ast_node) == Expr && ast_node.head in [:block,:for]
        new_scope_dict = deepcopy(in_scope_dict)
        println("New scope!")
        ixpr.head = ast_node.head
        ixpr.args = [ast_assign_types(x,new_scope_dict,nothing,cifdic) for x in ast_node.args]
        println("At end of scope: $new_scope_dict")
        return ixpr
    elseif typeof(ast_node) == Expr && ast_node.head == :call && ast_node.args[1] == :getindex
        println("Found call of getindex")
        if ast_node.args[2] in keys(in_scope_dict)
            cat,obj = in_scope_dict[ast_node.args[2]],ast_node.args[3]
            final_type = get_julia_type(cifdic,cat,obj)
            println("category $cat object $obj type $final_type")
            return :($ast_node::$final_type)
        else
            ixpr.head = ast_node.head
            ixpr.args = [ast_assign_types(x,in_scope_dict,nothing,cifdic) for x in ast_node.args]
            return ixpr
        end
    elseif typeof(ast_node) == Expr
        ixpr.head = ast_node.head
        ixpr.args = [ast_assign_types(x,in_scope_dict,nothing,cifdic) for x in ast_node.args]
        return ixpr
    else
        return ast_node
    end
end

test_expr1 = quote
    a = p::CategoryObject
    s = 0
    for x in atom_site::CategoryObject
        s = s + getindex(x,"x_pos")
    end
    return s
end

test_expr2 = quote
    f() = begin
        a = [1 2 3]
        b = [4 6 7]
        c = 0
        for x in a
            c = c + x
        end
        println(c)
        return c
    end
end

eval(test_expr2)

eval(ast_filter(test_expr2))

#dump(test_expr2,maxdepth=8)

#dump(ast_replace_plus(test_expr2),maxdepth=8)

end
