@testset "Test compound expressions" begin
    testdic = DDLm_Dictionary(joinpath(@__DIR__,"dic_for_tests.dic"))
    block = DynamicDDLmRC(Dict(),testdic)
    cif_cat = SetCategory("rv",Dict("output"=>0),testdic)

    teststring1 = ("""
           cumsum = 0
           q = [[1,2],[3,4],[5,6]]
           for a,b in q {
                cumsum += a*b
           }
           rv.output = cumsum
           """, 44)
    teststring2 = ("""
           cumsum = 0
           q = [[1,2,3,4],[3,4,5,6],[5,6,7,8]]
           for a,b,c,d in q {
                cumsum += a*b+c*d
           }
           rv.output = cumsum
           """, 142)

    for (teststring,correct) in (teststring1,teststring2)
        r = make_julia_code(teststring,"_rv.output",testdic)
        println("$teststring \n========\n\n$r")
        new_func = eval(r)
        result = Base.invokelatest(new_func,block,CatPacket(1,cif_cat))
        @test result == correct
    end

end

@testset "Test evaluation of simple expressions" begin
    testdic = DDLm_Dictionary(joinpath(@__DIR__,"dic_for_tests.dic"))
    test_tuples = (("0.5 * (1.0 + 2.0)",1.5),)
    block = DynamicDDLmRC(Dict(),testdic)
    cif_cat = SetCategory("rv",Dict("output"=>0),testdic)
    for (expr,correct) in test_tuples
        r = make_julia_code("rv.output = " * expr,"_rv.output",testdic)
        println("$expr \n========\n\n$r")
        new_func = eval(r)
        result = Base.invokelatest(new_func,block,CatPacket(1,cif_cat))
        @test result == correct
    end
end


@testset "Test simple expression processing" begin
    
    # Acceptable long/short strings

    good = ("a = '''A long string'''",
     "b = \"\"\"\"another long string\"\"\"",
     "c = ''''''",
            "d = \"\"\"\"\"\"",

            # Empty enclosures
            "e = []",
            "f = {}",)

    # Unacceptable long/short strings

    bad = (" a = 'hello ' '",
           " b = '''hello ''' '''")

    for expr in good
        @test typeof(Lerche.parse(DrelTools.drel_parser,expr)) <: Tree
    end

    for expr in bad
        @test_throws UnexpectedCharacters Lerche.parse(DrelTools.drel_parser,expr)
    end
end

