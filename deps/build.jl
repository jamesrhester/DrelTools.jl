using Lerche
using Serialization

include("../src/lark_grammar.ebnf")

lark_grammar() = begin
#    grammar_text = read(joinpath(@__DIR__,drel_grammar),String)
    ll = Lerche.Lark(_drel_grammar_spec,start="input",parser="lalr",lexer="contextual")
    return ll
end

Serialization.serialize(joinpath(@__DIR__,"drel_grammar_serialised.jli"),lark_grammar())
