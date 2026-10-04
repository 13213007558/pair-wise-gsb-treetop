# Sample generation and branch reachability

When maintaining a grammar it is often unclear whether every branch of an
ordered choice (`/`) can actually be reached by some input. Treetop ships a
sample generator that produces short inputs and reports which rule branches
they really exercise.

Reachability follows PEG ordered-choice semantics: when an earlier alternative
matches (even just a prefix), later alternatives at the same position are never
tried. The generator accounts for bounded expansion, lookahead predicates and
nullable rules. Embedded Ruby semantic predicates (`&{ ... }`, `!{ ... }`) can
not be evaluated statically, so any conclusion that would depend on them is
reported as `unknown` rather than guessed.

## Command line

    tt-samples --domain a,b my_grammar.treetop

Useful options: `--max-depth`, `--max-repeat`, `--max-length`, `--budget` and
`--format json`.

## Ruby API

    require 'treetop/sample/sample_generator'

    report = Treetop::Sample.for_grammar(source, domain: 'a,b')
    report.accepted_samples.each do |sample|
      puts sample.inspect        # input + branch ids hit in the real parser
    end
    report.branches.each do |branch|
      puts [branch.branch_id, branch.alternative_index, branch.status]
    end

## Branch statuses

* `covered` - a generated sample was parsed successfully and the instrumented
  parser really selected this alternative. A witness input is included.
* `proven_unreachable` - PEG analysis shows no input can select the branch:
  either a preceding alternative accepts the empty string, or it commits to a
  prefix of every string the branch accepts.
* `unknown` - an embedded Ruby semantic predicate or an unanalysable guard
  participates in the decision; reachability can not be decided.
* `not_found` - the branch may be reachable, but no witness was found before
  the search budget/length limits were exhausted.

## How coverage is measured

Grammars are compiled with branch instrumentation
(`Treetop::Compiler.branch_coverage = true`). Every successful ordered-choice
alternative calls `Treetop::Runtime.branch_covered!`, and a per-parse
`BranchRecorder` keeps the hits. The generator only marks a branch covered
when the witness input, fed to the real parser, produces exactly that hit, so
the report can not claim coverage from a purely static expansion.

## Ordered-choice example

With `a / ab`, the first alternative matches the prefix `a` of `ab` and PEG
commits, so the second branch is provably unreachable:

    choice start@0
      alt #0  COVERED  witness="a"
      alt #1  PROVEN UNREACHABLE

Swapping the order to `ab / a` lets both branches run (`ab` takes the first,
`a` falls through to the second).
