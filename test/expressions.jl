
@testset "Testing expression processing" begin
    #ud = prepare_system()
    t = DDLm_Dictionary(joinpath(@__DIR__,"cif_core.dic"))
    rawtext = :(a = [1,2,3,4]; b = a[0]; return b)
    newtext = ast_fix_indexing(rawtext,String[],t)
    println("New text: $newtext")
    @test eval(newtext) == 1
    # So in the next test b becomes [1,3,5,7,9] and b[2] is 5 
    rawtext = :(a = [1,2,3,4,5,6,7,8,9]; c = 4; b = a[c-4:2:c+4]; return b[2])
    newtext = ast_fix_indexing(rawtext,String[],t)
    println("New text: $newtext")
    @test eval(newtext) == 5
    rawtext = :(f(x) = begin s = 1;for i = 1:5 if i == 3 q = 1 elseif i == 4 a = q end end; a end)
    newtext = fix_scope(rawtext)
    eval(rawtext)
    # Make sure that Julia behaves as we expect
    @test_throws UndefVarError f(2) == 1
    eval(newtext)
    @test f(2) == 1
    # Alternative function definition form
    rawtext = :(function (x) s = 1;for i = 1:5 if i == 3 qq = 1 elseif i == 4 a = qq end end; a end)
    newtext = fix_scope(rawtext)
    println("New text: $newtext")
    g = eval(rawtext)
    # Make sure that Julia behaves as we expect
    @test_throws UndefVarError g(2) == 1
    g = eval(newtext)
    @test g(2) == 1

    #Now test that we properly process matrices
    rawtext = :(a.label = [[1,2,3],[4,5,6]]; return a.label)
    target,newtext = find_target(rawtext,"a","label";is_matrix=true)
    println("$newtext")
    @test eval(newtext) == [[1 2 3];[4 5 6]]
end

@testset "Test namespace presence" begin
    t = DDLm_Dictionary(joinpath(@__DIR__,"ddlm_from_ddl2.dic"))
    CIF_dREL.add_new_func(t,"_dictionary.date")
    println(t.func_text["_dictionary.date"])
end

@testset "Test dREL processing" begin
    t = DDL2_Dictionary(joinpath(@__DIR__,"ddl2_with_methods.dic"))
    # Test embedded property accesses
    rawtext = """
         with ce as category_examples
         category_examples.detail = description_example[.case=ce.case,.master_id=ce.id].detail
        """
    roughtext = CIF_dREL.make_julia_code(rawtext,"_category_examples.detail",t)
    println(roughtext)
end
