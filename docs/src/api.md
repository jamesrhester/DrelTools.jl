# dRELTools API

## Types

```@docs
DynamicDDLmRC
```

## Methods

```@docs
define_dict_funcs!(dict)
empty_cache!(d::DynamicDDLmRC)
keys(d::DynamicDDLmRC)
haskey(d::DynamicDDLmRC,s)
haskey(d::DynamicDDLmRC,s,n)
getindex(d::DynamicDDLmRC,s)
getindex(d::DynamicDDLmRC,s,nspace)
setindex!(d::DynamicDDLmRC,v,s)
setindex!(d::DynamicDDLmRC,v,s,nspace)
get_category(d::DynamicDDLmRC,s::AbstractString,nspace::String)
get_category(d::DynamicDDLmRC,s)
derive(b::DynamicRelationalContainer,dataname::AbstractString,nspace)
```

## For developers

```@docs
make_julia_code(drel_text,dataname,dict; reserved=AbstractString[])
add_definition_func!(d,s)
```

### Drel runtime functions

The following methods are defined to be used within
Julia code generated from dREL in order to support dREl
semantics and recursive calculation.

```@docs
drelvector
DrelTable
DrelTools.drel_property_access(cp,obj,datablock::DynamicRelationalContainer)
```
