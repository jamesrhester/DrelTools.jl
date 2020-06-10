#== 
dREL interface to Relations
==#

#Base.length(c::CategoryObject) = size(c.data_frame,1)
#CrystalInfoFramework.get_dictionary(c::CategoryObject) = get_dictionary(c.datablock)
#CrystalInfoFramework.get_datablock(c::CategoryObject) = get_datasource(c.datablock)

# During iteration over packets, values may have been calculated. These will
# be stored in extra columns of our data frame. So we check for these, and
# update any cache that our data block has for next time that it is used
# to create category objects.

#==
update_cache(c::CategoryObject) = begin
    cols = setdiff(Set(names(c.data_frame)),[:dummy])
    println("All data frame names: $cols")
    println("Lookup: $(c.object_to_name)")
    full_names = zip(cols,[c.object_to_name[String(col)] for col in cols])
    new_names = filter(n -> !(n[2] in lowercase.(keys(c.datablock))),collect(full_names))
    map(n -> cache_value!(c.datablock,n[2],getproperty(c.data_frame,n[1])),new_names)
    println("Cached $new_names")
end

==#
