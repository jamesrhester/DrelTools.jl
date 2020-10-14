#Testing dREL runtime support
using CrystalInfoFramework
using DataContainer
using CIF_dREL
using Test

prepare_system() = begin
    t = DDLm_Dictionary(joinpath(@__DIR__,"cif_mag.dic"))
    u = NativeCif(joinpath(@__DIR__,"AgCrS2.mcif"))
    ud = assign_dictionary(u["AgCrS2_OG"],t)
end

setup() = begin
    p = DDLm_Dictionary("/home/jrh/COMCIFS/cif_core/cif_core.dic")
    define_dict_funcs(p)
    n = NativeCif(joinpath(@__DIR__,"nick1.cif"))
    b = n["saly2_all_aniso"]
    t = TypedDataSource(b,p)
    return DynamicDDLmRC(t,p)
end

include("./dynamic.jl")
include("./expressions.jl")
include("./drel_exec.jl")
