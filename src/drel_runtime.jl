# These definitions enhance standard Julia definitions to bring
# function behaviour in line with dREL

# Include this file in any namespace (module) that evaluates Julia
# code derived from dREL

using LinearAlgebra

export drelvector,to_julia_array,drel_strip,drel_split,DrelTable

# a character can be compared to a single-character string
Base.:(==)(c::Char,y::String) = begin
    if length(y) == 1
        return c == y[1]
    else
        return false
    end
end

Base.:(+)(y::String,z::String) = y*z

# We redefine vectors so that we can fix up post and pre
# multiplication to always work

struct drelvector <: AbstractVector{Number}
    elements::Vector{Number}
end
# Create a drelvector from a row vector
drelvector(a::Array{Any,2}) = begin
    drelvector(vec(a))
end

# postmultiply: no transpose necessary
Base.:(*)(a::Array,b::drelvector) = begin
    #println("Multiplying $a by $(b.elements)")
    res = drelvector(a * b.elements)
    #println("To get $res")
    return res
end

#    **DrelTable**
#
# In order to capture any deviations from normal Julia
# we define our own Dict equivalent.  The most obvious
# deviation is being able to match CaselessStrings when
# used as keys.
#
struct DrelTable <: AbstractDict{Union{String,CaselessString,Integer},Any}
    keys::Array{Union{String,CaselessString,Integer},1}
    values::Array{Any,1}
end

DrelTable() = DrelTable([],[])

Base.keys(d::DrelTable) = d.keys
Base.values(d::DrelTable) = d.values
Base.getindex(d::DrelTable,k) = begin
    index = findfirst(x->isequal(x,k),d.keys)
    if isnothing(index) throw(KeyError(k)) end
    return d.values[index]
end

Base.setindex!(d::DrelTable,v,k) = begin
    index = findfirst(x->isequal(x,k),d.keys)
    if isnothing(index)
        push!(d.keys,k)
        push!(d.values,v)
    else
        d.values[index] = v
    end
end

Base.iterate(d::DrelTable) = begin
    if length(d) == 0 return nothing end
    return Pair(d.keys[1],d.values[1]),2
end

Base.iterate(d::DrelTable,state) = begin
    if length(d) < state return nothing end
    return Pair(d.keys[state],d.values[state]),state+1
end

Base.length(d::DrelTable) = length(d.keys)

# premultiply: transpose first
Base.:(*)(a::drelvector,b::Array{N,2} where N) = drelvector(permutedims(a.elements) * b)

# join multiply: dot product
Base.:(*)(a::drelvector,b::drelvector) = dot(a.elements,b.elements)

# all the rest
Base.getindex(a::drelvector,b) = getindex(a.elements,b)
Base.length(a::drelvector) = length(a.elements)
Base.size(a::drelvector) = size(a.elements)
Base.setindex!(a::drelvector,v,index) = setindex!(a.elements,v,index)
LinearAlgebra.cross(a::drelvector,b::drelvector) = drelvector(cross(vec(a.elements),vec(b.elements)))
# Broadcasting, so we get a drelvector when working with scalars
Base.BroadcastStyle(::Type{<:drelvector}) = Broadcast.ArrayStyle{drelvector}()
Base.similar(a::Broadcast.Broadcasted{Broadcast.ArrayStyle{drelvector}},::Type{ElType}) where ElType = drelvector(similar(Array{ElType},axes(a)))


#== Convert the dREL array representation to the Julia representation...
recursively. A dREL array is a sequence of potentially nested lists. Each
element is separated by a comma. This becomes, in Julia, a vector of
vectors, which is ultimately one-dimensional. So we loop over each element,
stacking each vector at each level into a 2-D array. Note that, while we
swap the row and column directions (dimensions 1 and 2) the rest are 
unchanged. Each invocation of this routine returns the actual level
that is currently being treated, together with the result of working
with the previous level.

Vectors in dREL are a bit magic, in that they conform themselves
to be row or column as required. We have implemented this in
the runtime, so we need to turn any single-dimensional array
into a drelvector ==#

to_julia_array(drel_array) = begin
    if ndims(drel_array) == 1 && eltype(drel_array) <: Number
        return drelvector(drel_array)
    else
        return to_julia_array_rec(drel_array)[2]
    end
end

to_julia_array_rec(drel_array) = begin
    if eltype(drel_array) <: AbstractArray   #can go deeper
        sep_arrays  = to_julia_array_rec.(drel_array)
        level = sep_arrays[1][1]  #level same everywhere
        result = (x->x[2]).(sep_arrays)
        if level == 2
            #println("$level:$result")
            return 3, vcat(result...)
        else
            #println("$level:$result")
            return level+1, cat(result...,dims=level)
        end
    else    #primitive elements, make them floats
        #println("Bottom level: $drel_array")
        return 2,hcat(Float64.(drel_array)...)
    end
end

#== 

Property access

Because we want to allow recursive derivation when encountering property
access into a packet, we need to provide the datablock as an additional
argument.  

Also take into account namespaces, which means we have to obtain the
dictionary via the category, which holds the relevant dictionary.

==#

drel_property_access(cp::CatPacket,obj::String,datablock::DynamicRelationalContainer) = begin
    source_cat = get_category(cp)
    catname = get_name(source_cat)
    dict = get_dictionary(cp)
    namespace = get_dic_namespace(dict)
    dataname = find_name(dict,catname,obj)
    result = missing
    rowno = getfield(cp,:id)
    #println("Looking for property $obj in $(source_cat.data_ptr)")
    try
        result = getproperty(cp,Symbol(obj))  #non-deriving form
    catch e  #TODO define our own error
        println("Property $obj not present in $catname (error $(typeof(e)))")
        #println("$(catch_backtrace())")
        println("Continuing with deriving version")
        if !haskey(datablock,dataname,namespace)
            # populate the column with 'missing' values
            println("$obj is missing, adding missing values")
            # explicitly set type otherwise DataFrames thinks it is Missing only
            new_array = Array{Union{Missing,Any},1}(missing,length(source_cat))
            cache_value!(datablock, namespace, dataname, new_array)
        else
            result = getindex(datablock,dataname,namespace)[rowno]
        end
    end
    if !ismissing(result) && !isnothing(result)
        #println("Found! $result")
        return result
    elseif isnothing(result)
        #println("Found! nothing")
        return result
    end
    m = derive(cp,obj,datablock)
    if ismissing(m)
        m = get_default(datablock,cp,Symbol(obj),namespace)
    end
    # store the cached value
    cache_value!(datablock,namespace,dataname,rowno, m)
    return m
end

# Generic fallback
drel_property_access(a,b,c) = begin
    println("Not drel compatible: looking for $b in $(typeof(a)) using data from $(typeof(c))")
    return getproperty(a,b)
end

"""

drel_strip implements the drel "Strip" function.

drel_strip(array,n) returns an array consisting of
the nth element of the constituent arrays. n counts
from zero
"""
drel_strip(a::Array,n::Int) = begin
    return (b[n+1] for b in a)
end

"""

drel_split implements the drel "Split" function.

drel_split(string,character) returns an array of
values obtained by splitting the string at each
occurrence of character.
"""
drel_split(s::String,c) = begin
    return split(s,c)
end
