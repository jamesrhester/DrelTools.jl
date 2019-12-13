ALL: lark-grammar.ebnf 

lark-grammar.ebnf:  annotated-grammar.rst
	egrep '^ {4,}' $< | ./ebnf_to_lark.py > lark_grammar.ebnf
