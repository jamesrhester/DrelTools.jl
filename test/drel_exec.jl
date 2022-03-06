# Test execution of dREL code

setup() = begin
    p = DDLm_Dictionary(joinpath(@__DIR__,"cif_core.dic"))
    define_dict_funcs!(p)
    n = Cif(Path(joinpath(@__DIR__,"nick1.cif")))
    b = n["saly2_all_aniso"]
    t = TypedDataSource(b,p)
    return DynamicDDLmRC(t,p)
end

const db = setup()


@testset "Test dictionary-defined functions" begin
    # Test that our functions are available
    d = get_dictionary(db)
    println("$(keys(d.func_defs))")
    @test get_func(d,"symkey")("2_555",db) == 2
end

@testset "Test generation of missing keys" begin
    d = get_dictionary(db)
    @test get_func(d,"symequiv")("2_555",drelvector([0.5,0.5,0.5]),db) == drelvector([0.0,1.0,-0.5])
end

@testset "Test single-step derivation" begin
    s = derive(db,"_cell.atomic_mass")
    @test s[1] == 552.488
    println("$(code_typed(get_func(get_dictionary(db),"_cell.atomic_mass"),(DynamicRelationalContainer,CatPacket)))")
    true
end

@testset "Test multi-step derivation" begin
    t = derive(db,"_cell.orthogonal_matrix")
    @test isapprox(t[1] , [11.5188 0 0; 0.0 11.21 0.0 ; -.167499 0.0 4.92], atol=0.01)
end

@testset "Test matrix multiplication" begin
    t = derive(db,"_cell.metric_tensor")
    @test isapprox(t[1], [132.71 0.0 -0.824094; 0.0 125.664 0.0; -0.824094 0.0 24.2064], atol = 0.01)
end

@testset "Test density" begin
    t = @time derive(db,"_exptl_crystal.density_diffrn")
    @test isapprox(t[1], db["_exptl_crystal.density_diffrn"][1],atol = 0.001)
    @time derive(db,"_exptl_crystal.density_diffrn")
end

@testset "Test tensor beta" begin
    t = @time derive(db,"_atom_site.tensor_beta")
    println("$t")
    println("$(code_typed(get_func(get_dictionary(db),"_atom_site.tensor_beta"),(DynamicRelationalContainer,CatPacket)))")
    true
end

# Often seem to fail at this point
@testset "Test value lookup" begin
    t = get_category(db,"atom_type","CifCore")
    @test DrelTools.get_default(db,first(t),:cromer_mann_c,"CifCore") == 0.2508
end

@testset "Test F_calc" begin
    t = db["_refln.F_calc"]
    @test isapprox(t,[23.993,32.058,6.604],atol=0.3)
end

@testset "Test category methods" begin
    #m = get_category(db,"model_site")
    #println("Created category $m")
    c = get_category(db,"geom_bond")
    println(c)
    t = db["_geom_bond.distance"]
    println(t)
    lookup_dict = Dict(:atom_site_label_1=>"c1",
                       :atom_site_label_2=>"c2",
                       :site_symmetry_1=>"1_555",
                       :site_symmetry_2=>"1_555")
    @test isapprox(get_category(db,"geom_bond")[lookup_dict].distance, 1.41673,atol=0.0001)
end
