require 'spec_helper'
require 'stringio'

describe Compiler::LeftRecursionDetector do
  def compile_grammar(grammar, options = {})
    Compiler::GrammarCompiler.new(options).ruby_source_from_string(grammar)
  end

  def capturing_stderr
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end

  def grammar_named(name, rules)
    "grammar #{name}\n#{rules}end\n"
  end

  describe 'in :error mode' do
    it 'rejects direct left recursion, reporting the call chain' do
      grammar = grammar_named('Direct', <<-GRAMMAR)
  rule a
    a 'x' / 'y'
  end
      GRAMMAR
      lambda {
        compile_grammar(grammar, :left_recursion => :error)
      }.should raise_error(Compiler::LeftRecursionError, /a -> a/)
    end

    it 'rejects indirect left recursion, reporting the whole call chain' do
      grammar = grammar_named('Indirect', <<-GRAMMAR)
  rule a
    b 'x'
  end
  rule b
    a 'y' / 'z'
  end
      GRAMMAR
      lambda {
        compile_grammar(grammar, :left_recursion => :error)
      }.should raise_error(Compiler::LeftRecursionError, /a -> b -> a/)
    end

    it 'rejects left recursion hidden behind an optional prefix' do
      grammar = grammar_named('OptionalPrefix', <<-GRAMMAR)
  rule a
    'x'? a 'y' / 'z'
  end
      GRAMMAR
      lambda {
        compile_grammar(grammar, :left_recursion => :error)
      }.should raise_error(Compiler::LeftRecursionError, /left recursion/)
    end

    it 'rejects left recursion in a later alternative of an ordered choice' do
      grammar = grammar_named('ChoiceHidden', <<-GRAMMAR)
  rule a
    ('x' / a) 'y'
  end
      GRAMMAR
      lambda {
        compile_grammar(grammar, :left_recursion => :error)
      }.should raise_error(Compiler::LeftRecursionError, /left recursion/)
    end

    it 'rejects repetition of an expression that can match the empty string' do
      grammar = grammar_named('NullableRepetition', <<-GRAMMAR)
  rule a
    ('x'?)* 'y'
  end
      GRAMMAR
      lambda {
        compile_grammar(grammar, :left_recursion => :error)
      }.should raise_error(Compiler::LeftRecursionError, /repeats an expression/)
    end

    it 'accepts ordinary right recursion' do
      warnings = capturing_stderr do
        compile_grammar(grammar_named('RightRecursive', <<-GRAMMAR), :left_recursion => :error)
  rule a
    'x' a / 'y'
  end
        GRAMMAR
      end
      warnings.should == ''
    end

    it 'accepts mutual recursion where each round consumes input first' do
      grammar = grammar_named('Mutual', <<-GRAMMAR)
  rule a
    'x' b / 'x'
  end
  rule b
    'y' a / 'y'
  end
      GRAMMAR
      warnings = capturing_stderr do
        Object.class_eval(compile_grammar(grammar, :left_recursion => :error))
      end
      warnings.should == ''
      MutualParser.new.parse('xyx').should_not be_nil
      MutualParser.new.parse('xyxy').should_not be_nil
      MutualParser.new.parse('x').should_not be_nil
      MutualParser.new.parse('yx').should be_nil
    end

    it 'accepts repetition of expressions that always consume input' do
      warnings = capturing_stderr do
        compile_grammar(grammar_named('ConsumingRepetition', <<-GRAMMAR), :left_recursion => :error)
  rule a
    ('x' / 'y')+ 'z'
  end
        GRAMMAR
      end
      warnings.should == ''
    end

    it 'accepts a bounded occurrence range of a nullable expression' do
      warnings = capturing_stderr do
        compile_grammar(grammar_named('BoundedRange', <<-GRAMMAR), :left_recursion => :error)
  rule a
    ('x'?)1..3 'y'
  end
        GRAMMAR
      end
      warnings.should == ''
    end

    it 'accepts lookahead predicates over consuming expressions' do
      warnings = capturing_stderr do
        compile_grammar(grammar_named('Lookahead', <<-GRAMMAR), :left_recursion => :error)
  rule a
    &'x' 'x' b
  end
  rule b
    !'z' .
  end
        GRAMMAR
      end
      warnings.should == ''
    end
  end

  describe 'with user semantic predicates' do
    it 'reports recursion it cannot disprove as unknown instead of rejecting it' do
      grammar = grammar_named('PredicateRecursion', <<-GRAMMAR)
  rule a
    &{ |v| true } a 'x' / 'y'
  end
      GRAMMAR
      warnings = capturing_stderr do
        compile_grammar(grammar, :left_recursion => :error)
      end
      warnings.should =~ /possible left recursion/
      warnings.should =~ /a -> a/
    end

    it 'reports repetition of unknown nullability as unknown instead of rejecting it' do
      grammar = grammar_named('PredicateRepetition', <<-GRAMMAR)
  rule a
    (&{ |v| true })* 'x'
  end
      GRAMMAR
      warnings = capturing_stderr do
        compile_grammar(grammar, :left_recursion => :error)
      end
      warnings.should =~ /may loop forever/
    end
  end

  describe 'in :warn mode' do
    it 'warns about definite left recursion but compiles anyway' do
      grammar = grammar_named('Warned', <<-GRAMMAR)
  rule a
    a 'x' / 'y'
  end
      GRAMMAR
      warnings = capturing_stderr do
        compile_grammar(grammar, :left_recursion => :warn).should_not be_nil
      end
      warnings.should =~ /left recursion/
      warnings.should =~ /a -> a/
    end

    it 'is the default mode' do
      grammar = grammar_named('DefaultMode', <<-GRAMMAR)
  rule a
    a 'x' / 'y'
  end
      GRAMMAR
      warnings = capturing_stderr do
        compile_grammar(grammar).should_not be_nil
      end
      warnings.should =~ /left recursion/
    end

    it 'stays quiet for grammars without problems' do
      warnings = capturing_stderr do
        compile_grammar(grammar_named('Quiet', <<-GRAMMAR), :left_recursion => :warn)
  rule a
    'x' a / 'y'
  end
        GRAMMAR
      end
      warnings.should == ''
    end
  end

  it 'rejects an invalid mode' do
    lambda {
      Compiler::GrammarCompiler.new(:left_recursion => :bogus)
    }.should raise_error(ArgumentError)
  end
end
