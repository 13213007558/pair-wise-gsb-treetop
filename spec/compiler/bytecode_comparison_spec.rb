require 'spec_helper'

# Referenced by a node class declaration in arithmetic_no_actions.treetop,
# mirroring examples/lambda_calculus/arithmetic_node_classes.rb.
class BinaryOperation < Treetop::Runtime::SyntaxNode; end

# Parses a set of existing Ruby-action-free grammars with both the
# traditional eval-based backend and the eval-free bytecode backend, and
# compares parse tree intervals and failure positions.
module BytecodeComparisonSpec
  describe 'bytecode backend compatibility' do
    FIXTURE_DIR = File.expand_path('bytecode', __dir__)

    # Parser classes installed by both backends under shared constant names
    # must not leak into other specs (a Parser class left behind with a
    # different superclass breaks recompilation of the same grammar).
    CREATED_CONSTANTS = %i[
      Test Arithmetic ArithmeticParser SeqPar SeqParParser
      PegFeatures PegFeaturesParser BinaryOperation
    ]

    after(:all) do
      CREATED_CONSTANTS.each do |const|
        Object.send(:remove_const, const) if Object.const_defined?(const, false)
      end
    end

    def self.fixture(name)
      File.join(FIXTURE_DIR, name)
    end

    # Compile the same grammar source with both backends. Both define the
    # same top-level constants; we keep direct references to the classes.
    def parser_classes_for(source)
      artifact = Treetop::Compiler::BytecodeCompiler.new.compile_to_artifact(source)
      namespace = Object
      (artifact['module_path'] || []).each do |name, _kind|
        break unless namespace.const_defined?(name, false)
        namespace = namespace.const_get(name)
      end
      if namespace.const_defined?(artifact['grammar_name'], false)
        grammar_module = namespace.const_get(artifact['grammar_name'])
        if grammar_module.const_defined?(:Parser, false)
          # the generated class Parser < CompiledParser would clash with the
          # previously defined InterpretedParser subclass (or vice versa)
          grammar_module.send(:remove_const, :Parser)
        end
      end
      ruby = Treetop::Compiler::GrammarCompiler.new.ruby_source_from_string(source)
      Object.class_eval(ruby)
      namespace = (artifact['module_path'] || []).inject(Object) do |ns, (name, _kind)|
        ns.const_get(name)
      end
      old_parser_class = namespace.const_get(artifact['grammar_name'] + 'Parser')
      new_parser_class = Treetop::Runtime::BytecodeLoader.load_artifact(artifact)
      [old_parser_class, new_parser_class]
    end

    def terminal_failures_of(parser)
      parser.terminal_failures.map { |f| [f.index, f.expected_string, f.unexpected] }
    end

    def compare_nodes(old_node, new_node, path = 'root')
      new_node.interval.should == old_node.interval
      new_node.text_value.should == old_node.text_value
      new_node.terminal?.should == old_node.terminal?
      unless old_node.terminal?
        old_elements = old_node.elements
        new_elements = new_node.elements
        new_elements.size.should == old_elements.size
        old_elements.zip(new_elements).each_with_index do |(old_child, new_child), i|
          compare_nodes(old_child, new_child, "#{path}/#{i}")
        end
      end
    end

    def compare_parses(parser_classes, input, options = {})
      old_parser_class, new_parser_class = parser_classes
      old_parser = old_parser_class.new
      new_parser = new_parser_class.new
      old_result = old_parser.parse(input, options.dup)
      new_result = new_parser.parse(input, options.dup)

      if old_result.nil?
        new_result.should be_nil
        new_parser.failure_index.should == old_parser.failure_index
        terminal_failures_of(new_parser).should == terminal_failures_of(old_parser)
        new_parser.failure_reason.should == old_parser.failure_reason
      else
        new_result.should_not be_nil
        compare_nodes(old_result, new_result)
      end
    end

    def self.compare_grammar(description, source, cases)
      describe description do
        before(:all) do
          @parser_classes = parser_classes_for(source)
        end

        cases.each do |case_options|
          input = case_options.delete(:input)
          it "parses #{input.inspect}#{' with ' + case_options.inspect unless case_options.empty?} like the Ruby backend" do
            compare_parses(@parser_classes, input, case_options)
          end
        end
      end
    end

    compare_grammar 'arithmetic_no_actions.treetop (from examples/lambda_calculus)',
      File.read(fixture('arithmetic_no_actions.treetop')),
      [
        { :input => '0' },
        { :input => '1' },
        { :input => 'x' },
        { :input => '1+2*3' },
        { :input => 'x == y' },
        { :input => 'x != y' },
        { :input => '(1 + 2) * x' },
        { :input => '1 + x * (2 - 3)' },
        { :input => '1 == 2 != 3' },
        { :input => '1 +' },
        { :input => '* 2' },
        { :input => '1 2' },
        { :input => '' },
        { :input => '  1+2', :index => 2 },
        { :input => '1+2 trailing', :consume_all_input => false },
      ]

    compare_grammar 'seqpar_no_actions.treetop (from benchmark)',
      File.read(fixture('seqpar_no_actions.treetop')),
      [
        { :input => 'seq A B end' },
        { :input => 'par A B end' },
        { :input => 'sequence A B end' },
        { :input => 'fit A B end' },
        { :input => 'art A B end' },
        { :input => 'artart A B end' },
        { :input => 'seq A par B C end D end' },
        { :input => 'Hello' },
        { :input => 'seq A' },
        { :input => 'seq A B' },
        { :input => 'seq A B end junk' },
        { :input => '' },
      ]

    compare_grammar 'peg_features.treetop (core PEG constructs)',
      File.read(fixture('peg_features.treetop')),
      [
        { :input => 'foo' },
        { :input => 'foo, bar, 12.5' },
        { :input => 'FOO, (bar, 1)' },
        { :input => 'foo,bar;baz' },
        { :input => 'foo,' },
        { :input => ',foo' },
        { :input => 'foo bar' },
        { :input => 'aabb', :root => :repeated },
        { :input => 'aaaab', :root => :repeated },
        { :input => 'ab', :root => :repeated },
        { :input => 'aaaaab', :root => :repeated },
        { :input => 'xxy', :root => :open_range },
        { :input => 'xxxxxy', :root => :open_range },
        { :input => 'xy', :root => :open_range },
        { :input => 'zzq', :root => :max_only_range },
        { :input => 'q', :root => :max_only_range },
        { :input => 'zzzzq', :root => :max_only_range },
        { :input => 'héllo世', :root => :multibyte },
        { :input => 'héllo', :root => :multibyte },
        { :input => 'hxllo', :root => :multibyte },
        { :input => 'startZ', :root => :predicated },
        { :input => 'startx', :root => :predicated },
        { :input => 'strt', :root => :predicated },
        { :input => 'abc', :root => :anyword },
        { :input => '9', :root => :anyword },
        { :input => '123%', :root => :regexp_terminal },
        { :input => 'abc', :root => :regexp_terminal },
        { :input => 'foo bar FOO', :root => :duplicates },
        { :input => 'foo bar', :root => :duplicates },
        { :input => '12.5', :root => :number },
        { :input => '12.', :root => :number },
      ]

    compare_grammar 'test_grammar.treetop (existing spec fixture, module-wrapped)',
      File.read(File.join(__dir__, 'test_grammar.treetop')),
      [
        { :input => 'foo' },
        { :input => 'bar' },
        { :input => 'fo' },
      ]

    describe 'labeled sequence accessors' do
      before(:all) do
        @parser_classes = parser_classes_for(File.read(File.join(FIXTURE_DIR, 'arithmetic_no_actions.treetop')))
      end

      it 'exposes the same labels as the Ruby backend' do
        old_parser_class, new_parser_class = @parser_classes
        old_result = old_parser_class.new.parse('1 + 22', :root => :additive)
        new_result = new_parser_class.new.parse('1 + 22', :root => :additive)
        new_result.head.text_value.should == old_result.head.text_value
        new_result.tail.elements.size.should == old_result.tail.elements.size
        new_result.tail.elements[0].operator.text_value.should == old_result.tail.elements[0].operator.text_value
        new_result.tail.elements[0].operand.interval.should == old_result.tail.elements[0].operand.interval
      end
    end

    describe 'duplicate labels' do
      before(:all) do
        @parser_classes = parser_classes_for(File.read(File.join(FIXTURE_DIR, 'peg_features.treetop')))
      end

      it 'suffixes repeated labels like the Ruby backend' do
        old_parser_class, new_parser_class = @parser_classes
        old_result = old_parser_class.new.parse('foo bar FOO', :root => :duplicates)
        new_result = new_parser_class.new.parse('foo bar FOO', :root => :duplicates)
        new_result.a1.text_value.should == old_result.a1.text_value
        new_result.a2.text_value.should == old_result.a2.text_value
        new_result.b.text_value.should == old_result.b.text_value
      end
    end

    describe 'node class declarations' do
      before(:all) do
        @parser_classes = parser_classes_for(File.read(File.join(FIXTURE_DIR, 'arithmetic_no_actions.treetop')))
      end

      it 'instantiates the declared node class' do
        _old_parser_class, new_parser_class = @parser_classes
        result = new_parser_class.new.parse('1 + 2')
        result.should be_an_instance_of(BinaryOperation)
      end
    end
  end
end
