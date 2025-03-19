# Test the dynamic types

const dd = setup()

@testset "Test dynamic relational container type " begin
    dd["a_test_value"]=2
    @test dd["a_test_value"] == 2
    @test haskey(dd,"a_test_value")
    empty_cache!(dd)
    @test !CrystalInfoContainers.has_category(dd,"model_site")
end

@testset "Test construction of empty Set categories" begin
    c = LoopCategory(dd, "atom_sites_Cartn_transform")
    p = first_packet(c)
    @test !ismissing(p.matrix)
end

@testset "Test dynamic set categories" begin
    c = LoopCategory(dd, "cell")
    @test c[:length_a] == [11.520]
    p = first_packet(c)
    @test p.length_a == 11.520
    @test p.vector_c == [0.0,0.0,4.920]
end

@testset "Test dynamic loop categories" begin
    l = LoopCategory(dd, "atom_site")
    @test 0.2501 in l[:fract_x]
    q = l[:tensor_beta]
end
