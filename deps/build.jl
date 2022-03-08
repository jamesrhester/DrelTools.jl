using Lerche
using Serialization
using Scratch

include("../src/lark_grammar.ebnf")

lark_grammar() = begin
    ll = Lerche.Lark(_drel_grammar_spec,start="input",parser="lalr",lexer="contextual")
    return ll
end

const my_uuid = Base.UUID("fc805444-c5ec-4e06-bf74-6216be16ab28")

# Store the analysed grammar for fast loading. See drel_execution.jl

Serialization.serialize(joinpath(get_scratch!(my_uuid,"lark_grammar"),"drel_grammar_serialised.jli"),lark_grammar())
