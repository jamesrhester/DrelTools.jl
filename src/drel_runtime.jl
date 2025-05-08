# These definitions enhance standard Julia definitions to bring
# function behaviour in line with dREL

# Include this file in any namespace (module) that evaluates Julia
# code derived from dREL

using LinearAlgebra


# a character can be compared to a single-character string
Base.:(==)(c::Char,y::String) = begin
    if length(y) == 1
        return c == y[1]
    else
        return false
    end
end

Base.:(+)(y::String,z::Union{String,Char}) = y*z

# We redefine vectors so that we can fix up post and pre
# multiplication to always work

"""
A `drelvector` is a vector which adopts the correct
dimension (column or row) to allow pre or post
multiplication without explicit transposition. 
"""
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

#    **DrelTable**
#
# In order to capture any deviations from normal Julia
# we define our own Dict equivalent.  The most obvious
# deviation is being able to match CaselessStrings when
# used as keys.
#

"""
A `DrelTable` is almost like a Julia `Dict`, but it must allow
`CaselessString` comparisons with `String`, and the types of the
keys are restricted.
"""
struct DrelTable <: AbstractDict{Union{String,CaselessString,Integer},Any}
    keys::Array{Union{String,CaselessString,Integer},1}
    values::Array{Any,1}
end

DrelTable() = DrelTable([],[])

keys(d::DrelTable) = d.keys
values(d::DrelTable) = d.values

"""
    getindex(d::DrelTable,k)

`d[k]` find the value corresponding to `k`, where caseless comparisons are
performed for string values.
"""
getindex(d::DrelTable,k) = begin
    index = findfirst(x->isequal(x,k),d.keys)
    if isnothing(index) throw(KeyError(k)) end
    return d.values[index]
end

"""
    setindex!(d::DrelTable,v,k)

Set `d[k]` to `v`, where a caseless comparison is performed for `k`.
"""
setindex!(d::DrelTable,v,k) = begin
    index = findfirst(x->isequal(x,k),d.keys)
    if isnothing(index)
        push!(d.keys,k)
        push!(d.values,v)
    else
        d.values[index] = v
    end
end

iterate(d::DrelTable) = begin
    if length(d) == 0 return nothing end
    return Pair(d.keys[1],d.values[1]),2
end

iterate(d::DrelTable,state) = begin
    if length(d) < state return nothing end
    return Pair(d.keys[state],d.values[state]),state+1
end

length(d::DrelTable) = length(d.keys)



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

"""
    drel_property_access(cp,obj,datablock)

This call corresponds to `cp.obj` in dREL code. If `obj` is not a property of `cp`,
`datablock` is used to try to derive a value, returning `missing` for all failures
and caching the result in `datablock` if successful.
"""
drel_property_access(cp, obj, datablock::DynamicRelationalContainer) = begin
    source_cat = get_category(cp)
    catname = get_name(source_cat)
    dict = get_dictionary(cp)
    namespace = get_dic_namespace(dict)
    dataname = find_name(dict,catname,obj)
    result = missing
    rowno = getfield(cp,:id)
    @debug "Looking for property $obj in $catname"
    try
        result = getproperty(cp,Symbol(obj))  #non-deriving form
    catch e  #TODO define our own error
        @debug "Property $obj not present in $catname (error $(typeof(e)))"
        #println("$(catch_backtrace())")
        @debug "Continuing with deriving version"
        if !haskey(datablock,dataname,namespace)
            # populate the column with 'missing' values
            @debug "$obj is missing, adding missing values"
            # explicitly set type otherwise DataFrames thinks it is Missing only
            new_array = Array{Union{Missing,Any},1}(missing,length(source_cat))
            cache_value!(datablock, namespace, dataname, new_array)
        else
            result = getindex(datablock,dataname,namespace)[rowno]
        end
    end
    if !ismissing(result) && !isnothing(result)
        # @debug "Found! $result"
        return result
    elseif isnothing(result)
        # @debug "Found! nothing"
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

drel_property_access(c::CifCategory, obj, datablock::DynamicRelationalContainer) = begin
    if length(c) > 1
        throw(error("Trying to access cat $(get_name(c)).$obj with more than one packet"))
    else
        return drel_property_access(first(c), obj, datablock)
    end
end

drel_property_access(::Missing,obj::String,datablock::DynamicRelationalContainer) = missing

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

"""
    drel_index(haystack,needle)

Implements the drel "indexof" function. Return -1 if `needle` is
not found in vector `haystack`, otherwise provide the 0-based
location in `haystack`.
"""
drel_index(v::Vector,c) = begin
    q = indexin([c],v)[]
    @debug "Index of $c in " v
    q == nothing ? -1 : q-1
end
