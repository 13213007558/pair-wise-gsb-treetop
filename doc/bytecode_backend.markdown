# The Bytecode Backend

The standard Treetop compiler generates Ruby source code from a grammar and
loads it with `eval`. Some deployment environments forbid dynamically
evaluated Ruby. For those, Treetop ships an alternative **bytecode backend**:
grammars are compiled ahead of time into a serializable instruction artifact,
and a small interpreter (`Treetop::Runtime::BytecodeParser`) executes the
artifact at parse time. No Ruby source is generated or evaluated on load.

## Compiling and loading

```ruby
# Ahead of time (build host): compile a grammar to a .ttbc artifact
Treetop::Compiler::GrammarCompiler.new.compile_bytecode('my_grammar.treetop')
# => writes my_grammar.ttbc

# In the deployment environment: load the artifact and parse
parser_class = Treetop.load_bytecode('my_grammar.ttbc')
parser = parser_class.new
parser.parse(input)
```

You can also compile from a string and keep the program object:

```ruby
program = Treetop::Compiler::BytecodeCompiler.new.compile(grammar_source)
artifact = program.dump                 # binary String (Marshal)
program  = Treetop::Compiler::BytecodeProgram.load(artifact)
parser_class = program.build_parser
```

`Treetop.load_bytecode_from_string(grammar_source)` compiles and builds in
one step.

## Artifact validation

Every artifact carries a format name and a version number
(`Treetop::Compiler::BytecodeProgram::VERSION`). Loading validates the
artifact before any parser is built and raises
`Treetop::Compiler::BytecodeProgram::InvalidArtifactError` when:

* the format or version is not supported,
* a jump target lands outside its rule's instruction sequence,
* a constant, module, or rule reference points outside its table,
* the root rule is not defined, or the structure is otherwise malformed.

## Supported grammar features

* Sequences, ordered choice, and parenthesized subexpressions
* Terminals: quoted strings (including the `i` and `r` modifiers),
  character classes, and the anything symbol `.`
* Repetition: `*`, `+`, and occurrence ranges (`2..4`, `2..`, `..4`)
* Optionals (`?`), and/not predicates (`&`, `!`), transient prefix (`~`)
* Nonterminals, including rules from grammars `include`d from other
  (Ruby-compiled) grammar modules
* Labels on sequence elements (accessor modules are built with
  `define_method`, not `eval`)
* Node class declarations (`<NodeClass>`), resolved by constant name
* Memoization, with the same per-rule, per-index cache semantics as the
  Ruby backend

Parse trees, failure indices, and failure reasons are identical to those
produced by the Ruby-generating backend for the same grammar and input.

## Unsupported constructs

Constructs that embed arbitrary Ruby source are rejected at compile time
with `Treetop::Compiler::BytecodeCompiler::UnsupportedConstructError`.
The bytecode backend never attempts a "safe eval":

* Semantic predicate blocks (`&{ ... }` / `!{ ... }`)
* Inline modules (`{ ... }`)
* The `super` nonterminal
* Non-literal `require` statements (literal `require 'foo'` is honored at
  compile time)
