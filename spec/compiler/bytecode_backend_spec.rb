require 'spec_helper'
require 'tmpdir'

module BytecodeBackendSpec
  class ExprNode < Treetop::Runtime::SyntaxNode; end
  class PairNode < Treetop::Runtime::SyntaxNode; end

  CALC_GRAMMAR = <<-'G'
grammar Calc
  rule expression
    head:term tail:(space op:addop space rhs:term)* <BytecodeBackendSpec::ExprNode>
  end
  rule addop
    '+' / '-'
  end
  rule term
    number / '(' space expression space ')'
  end
  rule number
    [0-9]+ ('.' [0-9]+)?
  end
  rule space
    ' '*
  end
end
  G

  JSON_LIKE_GRAMMAR = <<-'G'
grammar JsonLike
  rule document
    space value:value space !.
  end
  rule value
    object / array / string / number / keyword
  end
  rule keyword
    'true' / 'false' / 'null'
  end
  rule object
    '{' space pairs:(pair (',' space pair)*)? space '}' <BytecodeBackendSpec::PairNode>
  end
  rule pair
    key:string space ':' space val:value
  end
  rule array
    '[' space first:value rest:(',' space value)* space ']'
  end
  rule string
    '"' chars:([^"\\] / '\\' .)* '"'
  end
  rule number
    '-'? [0-9]+ ('.' [0-9]+)? ([eE] '-'? [0-9]+)?
  end
  rule space
    [ \t\n]*
  end
end
  G

  TOKENS_GRAMMAR = <<-'G'
grammar Tokens
  rule document
    first:line rest:("\n" line)* "\n"? !.
  end
  rule line
    &[a-z] word:([a-z]+) !'zzz' count:([0-9]1..3)? tags:('[' [a-z]2..4 ']')* terminator:'x'i?
  end
end
  G

  WORDS_GRAMMAR = <<-'G'
grammar Words
  rule sentence
    words:(word (','? ' '+ word)*) '.'?
  end
  rule word
    '[a-z]+'ri / [0-9]+ / .
  end
end
  G

  MEMO_GRAMMAR = <<-'G'
grammar Memo
  rule top
    ab / ac
  end
  rule ab
    a 'b'
  end
  rule ac
    a 'c'
  end
  rule a
    'a'
  end
end
  G

  describe 'the bytecode backend' do
    after do
      # Keep parser/module constants defined by these grammars from leaking
      # into other specs (the ruby backend reopens Grammar::Parser, which
      # conflicts with a bytecode parser class of the same name).
      Object.class_eval do
        %w[Calc JsonLike Tokens Words Memo Sample Test
           CalcParser JsonLikeParser TokensParser WordsParser MemoParser SampleParser].each do |const_name|
          remove_const(const_name) if const_defined?(const_name, false)
        end
      end
    end

    def compile_with_ruby_backend(grammar_source)
      grammar_node = parse_with_metagrammar(grammar_source.strip, :module_or_grammar)
      # The ruby backend reopens Grammar::Parser instead of replacing it, so
      # remove any parser class a previous bytecode build installed there.
      grammar_scope = grammar_node.parser_name.sub(/Parser\z/, '').split('::').inject(Object) do |scope, const_name|
        break nil unless scope.const_defined?(const_name, false)
        scope.const_get(const_name, false)
      end
      grammar_scope.send(:remove_const, :Parser) if grammar_scope && grammar_scope.const_defined?(:Parser, false)
      Object.class_eval(grammar_node.compile)
      grammar_node.parser_name.split('::').inject(Object) { |scope, const_name| scope.const_get(const_name) }
    end

    def compile_with_bytecode_backend(grammar_source)
      Treetop::Compiler::BytecodeCompiler.new.compile(grammar_source).build_parser
    end

    def assert_same_tree(old_node, new_node)
      new_node.class.should == old_node.class
      new_node.interval.should == old_node.interval
      new_node.text_value.should == old_node.text_value
      new_node.terminal?.should == old_node.terminal?
      new_node.extension_modules.map(&:name).should == old_node.extension_modules.map(&:name)
      old_elements = old_node.terminal? ? [] : old_node.elements
      new_elements = new_node.terminal? ? [] : new_node.elements
      new_elements.size.should == old_elements.size
      old_elements.zip(new_elements).each { |o, n| assert_same_tree(o, n) }
    end

    def assert_same_failure(old_parser, new_parser)
      new_parser.failure_index.should == old_parser.failure_index
      new_parser.failure_line.should == old_parser.failure_line
      new_parser.failure_column.should == old_parser.failure_column
      new_parser.failure_reason.should == old_parser.failure_reason
      old_failures = old_parser.terminal_failures.map { |f| [f.index, f.expected_string, f.unexpected] }
      new_failures = new_parser.terminal_failures.map { |f| [f.index, f.expected_string, f.unexpected] }
      new_failures.should == old_failures
    end

    def assert_backends_agree(grammar_source, inputs, options = {})
      old_class = compile_with_ruby_backend(grammar_source)
      new_class = compile_with_bytecode_backend(grammar_source)
      inputs.each do |input|
        old_parser = old_class.new
        new_parser = new_class.new
        old_result = old_parser.parse(input, options)
        new_result = new_parser.parse(input, options)
        if old_result.nil?
          new_result.should be_nil, "expected bytecode backend to reject #{input.inspect}"
          assert_same_failure(old_parser, new_parser)
        else
          new_result.should_not be_nil, "expected bytecode backend to accept #{input.inspect}"
          assert_same_tree(old_result, new_result)
          new_parser.index.should == old_parser.index
        end
      end
    end

    describe 'compared with the ruby code generating backend' do
      it 'produces identical trees and failures for a recursive grammar with labels and node classes' do
        assert_backends_agree(CALC_GRAMMAR, [
          '1 + (2.5 - 3)',
          '(((((1)))))',
          '42',
          '1 + 2 - 3 + 4.25',
          '1 + (2 -',
          '1 ++ 2',
          '(1))',
          ''
        ])
      end

      it 'produces identical trees and failures for a json-like grammar' do
        assert_backends_agree(JSON_LIKE_GRAMMAR, [
          '{"a": 1, "b": [true, null, "x\\"y"]}',
          '[1, 2.5, -3e-4]',
          '  [ ]  ',
          '{ }',
          'null',
          '{"a": 1,}',
          '[1,',
          '"unclosed',
          'true false',
          '[1 2]'
        ])
      end

      it 'produces identical trees and failures for predicates and occurrence ranges' do
        assert_backends_agree(TOKENS_GRAMMAR, [
          'abc12[ab]x',
          "abc\nqrs9[tuv]X",
          'abc[ab][cde]',
          'zzz',
          '9abc',
          'abc1234',
          'abc[abcde]',
          "abc\n",
          'abc1x trailing'
        ])
      end

      it 'produces identical trees and failures for regexp terminals and the anything symbol' do
        assert_backends_agree(WORDS_GRAMMAR, [
          'Hello, world 123!',
          'abc',
          '???...',
          'One Two.',
          ',,' 
        ])
      end

      it 'produces identical trees and failures when not consuming all input' do
        assert_backends_agree(CALC_GRAMMAR, ['1 + 2xyz', '(1) trailing'], :consume_all_input => false)
      end

      it 'produces identical results for grammars in existing .treetop files' do
        dir = File.dirname(__FILE__)
        %w[test_grammar.treetop test_grammar_do.treetop].each do |file|
          source = File.read(File.join(dir, file))
          assert_backends_agree(source, ['foo', 'bar', 'foox'])
        end
      end
    end

    describe 'grammar composition' do
      before(:all) do
        dir = File.expand_path('../composition', File.dirname(__FILE__))
        Treetop.load(File.join(dir, 'a.treetop'))
        Treetop.load(File.join(dir, 'b.treetop'))
      end

      it 'calls rules included from ruby-backend grammars' do
        source = File.read(File.expand_path('../composition/c.treetop', File.dirname(__FILE__)))
        assert_backends_agree(source, ['abbc', 'abb', 'abbcx', 'abc'])
      end
    end

    describe 'memoization' do
      it 'caches rule results per start index like the ruby backend' do
        assert_backends_agree(MEMO_GRAMMAR, ['ab', 'ac', 'ad', 'a'])
        parser = compile_with_bytecode_backend(MEMO_GRAMMAR).new
        result = parser.parse('ac')
        result.should_not be_nil
        result.interval.should == (0...2)
        cache = parser.send(:node_cache)
        cache[:a].should_not be_empty
        cache[:a][0].interval.should == (0...1)
        cache[:ab][0].should be_nil
        cache[:ac][0].interval.should == (0...2)
      end

      it 'memoizes recursive rules' do
        parser = compile_with_bytecode_backend(CALC_GRAMMAR).new
        parser.parse('1 + (2.5 - 3)').should_not be_nil
        cache = parser.send(:node_cache)
        cache[:expression].should_not be_empty
        cache[:term].should_not be_empty
        cache[:number].should_not be_empty
      end
    end

    describe 'labels' do
      it 'exposes labeled sequence elements through accessor modules' do
        parser_class = compile_with_bytecode_backend(CALC_GRAMMAR)
        result = parser_class.new.parse('1 + 2')
        result.head.text_value.should == '1'
        result.head.interval.should == (0...1)
        result.tail.elements.size.should == 1
        result.tail.elements[0].op.text_value.should == '+'
        result.tail.elements[0].rhs.text_value.should == '2'
      end
    end

    describe 'bytecode artifacts' do
      def compile_program(source = CALC_GRAMMAR)
        Treetop::Compiler::BytecodeCompiler.new.compile(source)
      end

      def tampered_copy(program)
        Marshal.load(Marshal.dump(program.to_h))
      end

      it 'carries a format version' do
        program = compile_program
        program.to_h['format'].should == Treetop::Compiler::BytecodeProgram::FORMAT
        program.to_h['version'].should == Treetop::Compiler::BytecodeProgram::VERSION
      end

      it 'round-trips through dump/load and parses identically' do
        program = compile_program
        loaded = Treetop::Compiler::BytecodeProgram.load(program.dump)
        assert_same_tree(program.build_parser.new.parse('1 + (2 - 3)'),
                         loaded.build_parser.new.parse('1 + (2 - 3)'))
      end

      it 'rejects an artifact with an unsupported version' do
        data = tampered_copy(compile_program)
        data['version'] = 999
        lambda {
          Treetop::Compiler::BytecodeProgram.new(data)
        }.should raise_error(Treetop::Compiler::BytecodeProgram::InvalidArtifactError, /version/)
      end

      it 'rejects an artifact with an out-of-range jump target' do
        data = tampered_copy(compile_program)
        rule = data['rules'].find { |r| r['code'].any? { |instr| instr[0] == :jmp } }
        instr = rule['code'].find { |i| i[0] == :jmp }
        instr[1] = 999_999
        lambda {
          Treetop::Compiler::BytecodeProgram.new(data)
        }.should raise_error(Treetop::Compiler::BytecodeProgram::InvalidArtifactError, /jump/)
      end

      it 'rejects an artifact with an out-of-range constant reference' do
        data = tampered_copy(compile_program)
        rule = data['rules'].find { |r| r['code'].any? { |instr| instr[0] == :match_str } }
        instr = rule['code'].find { |i| i[0] == :match_str }
        instr[1] = 999_999
        lambda {
          Treetop::Compiler::BytecodeProgram.new(data)
        }.should raise_error(Treetop::Compiler::BytecodeProgram::InvalidArtifactError, /const/)
      end

      it 'rejects an artifact with an out-of-range module reference' do
        data = tampered_copy(compile_program)
        rule = data['rules'].find { |r| r['code'].any? { |instr| instr[0] == :build_seq_node && !instr[2].empty? } }
        instr = rule['code'].find { |i| i[0] == :build_seq_node && !i[2].empty? }
        instr[2] = [999_999]
        lambda {
          Treetop::Compiler::BytecodeProgram.new(data)
        }.should raise_error(Treetop::Compiler::BytecodeProgram::InvalidArtifactError, /modlist/)
      end

      it 'rejects an artifact that references an undefined root rule' do
        data = tampered_copy(compile_program)
        data['root'] = 'nonexistent'
        lambda {
          Treetop::Compiler::BytecodeProgram.new(data)
        }.should raise_error(Treetop::Compiler::BytecodeProgram::InvalidArtifactError, /root/)
      end

      it 'rejects malformed data' do
        lambda {
          Treetop::Compiler::BytecodeProgram.load('this is not a bytecode artifact')
        }.should raise_error(Treetop::Compiler::BytecodeProgram::InvalidArtifactError)
        lambda {
          Treetop::Compiler::BytecodeProgram.load(Marshal.dump({'format' => 'something-else'}))
        }.should raise_error(Treetop::Compiler::BytecodeProgram::InvalidArtifactError)
      end
    end

    describe 'unsupported constructs' do
      def compile_error(grammar_source)
        lambda {
          Treetop::Compiler::BytecodeCompiler.new.compile(grammar_source)
        }.should raise_error(Treetop::Compiler::BytecodeCompiler::UnsupportedConstructError)
      end

      it 'rejects semantic predicate blocks instead of attempting a safe eval' do
        compile_error("grammar G\n  rule a\n    'a' &{ |v| true }\n  end\nend")
      end

      it 'rejects negated semantic predicate blocks' do
        compile_error("grammar G\n  rule a\n    'a' !{ |v| false }\n  end\nend")
      end

      it 'rejects inline modules with ruby code' do
        compile_error("grammar G\n  rule a\n    'a' { def a_method; 1; end }\n  end\nend")
      end

      it 'rejects the super nonterminal' do
        compile_error("grammar G\n  rule a\n    super 'x'\n  end\nend")
      end

      it 'rejects non-literal require statements' do
        compile_error("require File.dirname(__FILE__) + '/x'\ngrammar G\n  rule a\n    'a'\n  end\nend")
      end
    end

    describe 'GrammarCompiler bytecode compilation' do
      it 'writes a versioned .ttbc artifact that can be loaded without eval' do
        Dir.mktmpdir do |dir|
          source_path = File.join(dir, 'sample.treetop')
          File.open(source_path, 'w') do |f|
            f.write("grammar Sample\n  rule pair\n    left:'a' right:'b'\n  end\nend\n")
          end
          target_path = Compiler::GrammarCompiler.new.compile_bytecode(source_path)
          target_path.should =~ /\.ttbc\z/
          File.exist?(target_path).should be_truthy

          parser_class = Treetop.load_bytecode(target_path)
          result = parser_class.new.parse('ab')
          result.should_not be_nil
          result.left.text_value.should == 'a'
          result.right.text_value.should == 'b'
          parser_class.new.parse('ac').should be_nil
        end
      end
    end
  end
end
