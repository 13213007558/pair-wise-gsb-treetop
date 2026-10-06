require 'spec_helper'
require 'stringio'

describe Compiler::LoopChecker do
  def diagnostics_for(grammar_source)
    parser = Compiler::MetagrammarParser.new
    result = parser.parse(grammar_source)
    raise parser.failure_reason unless result
    Compiler::LoopChecker.new.check(result)
  end

  def capture_stderr
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end

  describe 'recursion that cannot consume input' do
    it 'flags direct left recursion with the call chain' do
      diagnostics = diagnostics_for(<<-GRAMMAR)
        grammar Test
          rule a
            a 'x' / 'y'
          end
        end
      GRAMMAR
      diagnostics.size.should == 1
      diagnostic = diagnostics.first
      diagnostic.kind.should == :recursion
      diagnostic.status.should == :definite
      diagnostic.chain.should == %w(a a)
      diagnostic.message.should include('a -> a')
    end

    it 'flags mutual recursion that consumes nothing per round' do
      diagnostics = diagnostics_for(<<-GRAMMAR)
        grammar Test
          rule a
            b 'x' / 'z'
          end
          rule b
            c a / 'w'
          end
          rule c
            'v'?
          end
        end
      GRAMMAR
      diagnostics.size.should == 1
      diagnostic = diagnostics.first
      diagnostic.kind.should == :recursion
      diagnostic.status.should == :definite
      diagnostic.chain.first.should == diagnostic.chain.last
      (diagnostic.chain - %w(a b)).should be_empty
    end

    it 'flags recursion hidden behind lookahead' do
      diagnostics = diagnostics_for(<<-GRAMMAR)
        grammar Test
          rule a
            &b 'x' / 'y'
          end
          rule b
            a 'z'
          end
        end
      GRAMMAR
      diagnostics.size.should == 1
      diagnostics.first.status.should == :definite
    end

    it 'flags recursion when an ordered choice alternative is nullable' do
      diagnostics = diagnostics_for(<<-GRAMMAR)
        grammar Test
          rule a
            ('x' / '') a
          end
        end
      GRAMMAR
      diagnostics.size.should == 1
      diagnostics.first.status.should == :definite
    end

    it 'marks recursion gated by a semantic predicate as unknown, not safe' do
      diagnostics = diagnostics_for(<<-GRAMMAR)
        grammar Test
          rule a
            &{ |v| true } a / 'x'
          end
        end
      GRAMMAR
      diagnostics.size.should == 1
      diagnostic = diagnostics.first
      diagnostic.kind.should == :recursion
      diagnostic.status.should == :unknown
      diagnostic.chain.should == %w(a a)
    end
  end

  describe 'recursion that consumes input (legal)' do
    it 'accepts right recursion' do
      diagnostics_for(<<-GRAMMAR).should be_empty
        grammar Test
          rule a
            'x' a / 'y'
          end
        end
      GRAMMAR
    end

    it 'accepts mutual recursion that consumes a character each round' do
      diagnostics_for(<<-GRAMMAR).should be_empty
        grammar Test
          rule a
            'x' b / 'y'
          end
          rule b
            'z' a / 'w'
          end
        end
      GRAMMAR
    end

    it 'compiles and runs a mutually recursive grammar that consumes a character each round' do
      warnings = capture_stderr do
        Treetop.load_from_string(<<-GRAMMAR)
          grammar Mutual
            rule a
              'x' b / 'y'
            end
            rule b
              'z' a / 'w'
            end
          end
        GRAMMAR
      end
      warnings.should be_empty
      MutualParser.new.parse('xzy').should_not be_nil
      MutualParser.new.parse('xzxzy').should_not be_nil
      MutualParser.new.parse('y').should_not be_nil
      MutualParser.new.parse('xzq').should be_nil
    end
  end

  describe 'repetition of nullable expressions' do
    it 'flags zero_or_more of a nullable expression' do
      diagnostics = diagnostics_for(<<-GRAMMAR)
        grammar Test
          rule a
            ('x'?)*
          end
        end
      GRAMMAR
      diagnostics.size.should == 1
      diagnostic = diagnostics.first
      diagnostic.kind.should == :repetition
      diagnostic.status.should == :definite
      diagnostic.message.should include("('x'?)*")
    end

    it 'flags one_or_more of a rule that can succeed on empty input' do
      diagnostics = diagnostics_for(<<-GRAMMAR)
        grammar Test
          rule a
            b+
          end
          rule b
            'x'?
          end
        end
      GRAMMAR
      diagnostics.size.should == 1
      diagnostics.first.kind.should == :repetition
      diagnostics.first.status.should == :definite
    end

    it 'accepts repetition of expressions that consume input' do
      diagnostics_for(<<-GRAMMAR).should be_empty
        grammar Test
          rule a
            ('x' 'y'?)* b+
          end
          rule b
            [0-9]
          end
        end
      GRAMMAR
    end

    it 'accepts bounded occurrence ranges of nullable expressions' do
      diagnostics_for(<<-GRAMMAR).should be_empty
        grammar Test
          rule a
            ('x'?)2..3
          end
        end
      GRAMMAR
    end

    it 'marks repetition gated by a semantic predicate as unknown, not safe' do
      diagnostics = diagnostics_for(<<-GRAMMAR)
        grammar Test
          rule a
            (&{ |v| true })*
          end
        end
      GRAMMAR
      diagnostics.size.should == 1
      diagnostic = diagnostics.first
      diagnostic.kind.should == :repetition
      diagnostic.status.should == :unknown
    end
  end

  describe 'compiler loop_check modes' do
    left_recursive = <<-GRAMMAR
      grammar Test
        rule a
          a 'x' / 'y'
        end
      end
    GRAMMAR

    predicate_gated = <<-GRAMMAR
      grammar Test
        rule a
          &{ |v| true } a / 'x'
        end
      end
    GRAMMAR

    it 'warns but compiles by default' do
      warnings = capture_stderr do
        Compiler::GrammarCompiler.new.ruby_source_from_string(left_recursive).should_not be_nil
      end
      warnings.should include('warning')
      warnings.should include('a -> a')
    end

    it 'rejects provably non-consuming loops in :error mode' do
      compiler = Compiler::GrammarCompiler.new(loop_check: :error)
      lambda {
        compiler.ruby_source_from_string(left_recursive)
      }.should raise_error(Compiler::NonConsumingLoopError, /a -> a/)
    end

    it 'only warns about unprovable loops in :error mode' do
      compiler = Compiler::GrammarCompiler.new(loop_check: :error)
      warnings = capture_stderr do
        compiler.ruby_source_from_string(predicate_gated).should_not be_nil
      end
      warnings.should include('semantic predicates')
    end

    it 'stays silent in :off mode' do
      compiler = Compiler::GrammarCompiler.new(loop_check: :off)
      warnings = capture_stderr do
        compiler.ruby_source_from_string(left_recursive).should_not be_nil
      end
      warnings.should be_empty
    end
  end
end
