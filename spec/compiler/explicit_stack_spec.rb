require 'spec_helper'

module ExplicitStackSpec
  class ListNode < Treetop::Runtime::SyntaxNode
  end

  module CallSiteModule
    def call_site_marker
      :marked
    end
  end

  describe 'a directly right-recursive rule' do
    testing_grammar %{
      grammar Test
        rule list
          first:item rest:list / last:item
        end
        rule item
          'x' {
            def letter
              text_value
            end
          }
        end
      end
    }

    it 'compiles the recursive rule with an explicit stack' do
      self.class.parser_code.should include('__es_drive')
    end

    it 'produces the same nested nodes, intervals and labels as plain recursion' do
      parse('xxx') do |result|
        result.should_not be_nil
        result.interval.should == (0...3)
        result.text_value.should == 'xxx'
        result.first.text_value.should == 'x'
        result.first.letter.should == 'x'
        rest = result.rest
        rest.interval.should == (1...3)
        rest.first.text_value.should == 'x'
        innermost = rest.rest
        innermost.interval.should == (2...3)
        innermost.last.text_value.should == 'x'
        innermost.last.letter.should == 'x'
      end
    end

    it 'matches at a non-zero index' do
      parse('--xx', :index => 2) do |result|
        result.should_not be_nil
        result.interval.should == (2...4)
      end
    end

    it 'parses a very long input without exhausting the Ruby call stack' do
      parse('x' * 25_000) do |result|
        result.should_not be_nil
        result.interval.should == (0...25_000)
        depth = 0
        node = result
        while node.respond_to?(:rest)
          depth += 1
          node = node.rest
        end
        depth.should == 24_999
        node.last.text_value.should == 'x'
      end
    end

    it 'parses a very long input on a thread with a small fixed stack' do
      result = nil
      Thread.new(stack_size: 128 * 1024) do
        result = parser_class_under_test.new.parse('x' * 25_000)
      end.join
      result.should_not be_nil
      result.interval.should == (0...25_000)
    end

    it 'reports the correct failure position when the input fails near the end' do
      parse('x' * 5000 + 'y') do |result|
        result.should be_nil
        parser.failure_index.should == 5000
        parser.failure_reason.should include("Expected 'x'")
      end
    end

    it 'returns the longest valid prefix when not consuming all input' do
      parse('xxy', :consume_all_input => false) do |result|
        result.should_not be_nil
        result.interval.should == (0...2)
        parser.index.should == 2
      end
    end
  end

  describe 'mutually right-recursive rules' do
    testing_grammar %{
      grammar Test
        rule a
          'x' b / 'x'
        end
        rule b
          'y' a / 'y'
        end
      end
    }

    it 'produces nested nodes alternating between the two rules' do
      parse('xyx') do |result|
        result.should_not be_nil
        result.interval.should == (0...3)
        result.elements[0].text_value.should == 'x'
        b = result.elements[1]
        b.elements[0].text_value.should == 'y'
        b.elements[1].text_value.should == 'x'
      end
    end

    it 'parses a very long alternating input' do
      parse('xy' * 15_000 + 'x') do |result|
        result.should_not be_nil
        result.interval.should == (0...30_001)
      end
    end

    it 'fails with the correct position near the end' do
      parse('xy' * 4000 + 'z') do |result|
        result.should be_nil
        parser.failure_index.should == 8000
      end
    end
  end

  describe 'a recursive rule with several recursive alternatives' do
    testing_grammar %{
      grammar Test
        rule a
          'x' a / 'y' a / 'x'
        end
      end
    }

    it 'backtracks into later alternatives while unwinding the explicit stack' do
      parse('xyx') do |result|
        result.should_not be_nil
        result.interval.should == (0...3)
        result.elements[0].text_value.should == 'x'
        result.elements[1].elements[0].text_value.should == 'y'
        result.elements[1].elements[1].text_value.should == 'x'
      end
    end

    it 'uses memoized results for repeated tail calls at the same index' do
      parse('xx') do |result|
        result.should_not be_nil
        result.interval.should == (0...2)
      end
    end
  end

  describe 'memoization of a right-recursive rule' do
    testing_grammar %{
      grammar Test
        rule top
          list '!' / list
        end
        rule list
          item list / item
        end
        rule item
          'x'
        end
      end
    }

    it 'returns the memoized node and restores the index on a cache hit' do
      parse('xxx') do |result|
        result.should_not be_nil
        result.interval.should == (0...3)
        parser.index.should == 3
      end
    end
  end

  describe 'a rule referencing a right-recursive rule twice' do
    testing_grammar %{
      grammar Test
        rule top
          list list / list
        end
        rule list
          item list / item
        end
        rule item
          'x'
        end
      end
    }

    it 'returns the memoized list node for the repeated reference' do
      parse('xxx') do |result|
        result.should_not be_nil
        result.interval.should == (0...3)
        result.elements.size.should == 2
      end
    end
  end

  describe 'semantic node construction in a right-recursive rule' do
    testing_grammar %{
      grammar Test
        rule list
          first:item rest:list <ExplicitStackSpec::ListNode> {
            def count
              1 + rest.count
            end
          }
          /
          last:item {
            def count
              1
            end
          }
        end
        rule item
          'x'
        end
      end
    }

    it 'constructs nodes with the declared class and inline modules at every level including the tail' do
      parse('xxx') do |result|
        result.should be_an_instance_of(ListNode)
        result.count.should == 3
        result.rest.should be_an_instance_of(ListNode)
        result.rest.count.should == 2
        result.rest.rest.count.should == 1
        result.rest.rest.should_not be_an_instance_of(ListNode)
      end
    end
  end

  describe 'a recursive call site carrying a node module' do
    testing_grammar %{
      grammar Test
        rule a
          'x' b / 'x'
        end
        rule b
          a <ExplicitStackSpec::CallSiteModule> / 'y'
        end
      end
    }

    it 'extends the result of the recursive call with the module' do
      parse('xxy') do |result|
        result.should_not be_nil
        inner = result.elements[1]
        inner.should respond_to(:call_site_marker)
        inner.call_site_marker.should == :marked
      end
    end
  end

  describe 'a recursive rule with a transient prefix in tail position' do
    testing_grammar %{
      grammar Test
        rule a
          'x' ~a / 'x'
        end
      end
    }

    it 'parses recursively without wrapping the tail result' do
      parse('xxx') do |result|
        result.should_not be_nil
        result.interval.should == (0...3)
        result.elements.size.should == 2
        result.elements[1].text_value.should == 'xx'
      end
    end
  end

  describe 'a recursive rule with a parenthesized choice in tail position' do
    testing_grammar %{
      grammar Test
        rule a
          item (a / item) / item
        end
        rule item
          'x'
        end
      end
    }

    it 'parses through the nested tail chain' do
      parse('xxx') do |result|
        result.should_not be_nil
        result.interval.should == (0...3)
        result.elements[1].interval.should == (1...3)
      end
    end
  end

  describe 'grammars that cannot be compiled with an explicit stack' do
    def compile_grammar(grammar)
      grammar_node = parse_with_metagrammar(grammar.strip, :grammar)
      warnings = nil
      begin
        original_stderr = $stderr
        $stderr = StringIO.new
        code = grammar_node.compile
        warnings = $stderr.string
      ensure
        $stderr = original_stderr
      end
      [code, warnings]
    end

    it 'reports recursive references outside tail position and falls back to plain recursion' do
      code, warnings = compile_grammar(%{
        grammar Test
          rule a
            'x' a / 'y' a 'y' / 'z'
          end
        end
      })
      warnings.should include('cannot compile right-recursive rule(s) `a`')
      warnings.should include('does not appear in a tail position')
      code.should_not include('__es_drive')
      Object.class_eval(code)
      TestParser.new.parse('yzy').interval.should == (0...3)
    end

    it 'reports embedded Ruby semantic predicate blocks and falls back to plain recursion' do
      code, warnings = compile_grammar(%{
        grammar Test
          rule a
            'x' &{ |v| true } a / 'x'
          end
        end
      })
      warnings.should include('cannot compile right-recursive rule(s) `a`')
      warnings.should include('semantic predicate block')
      code.should_not include('__es_drive')
      Object.class_eval(code)
      TestParser.new.parse('xx').interval.should == (0...2)
    end

    it 'reports the use of super in a recursive rule' do
      code, warnings = compile_grammar(%{
        grammar Test
          rule a
            'x' a / super
          end
        end
      })
      warnings.should include('cannot compile right-recursive rule(s) `a`')
      warnings.should include('super')
      code.should_not include('__es_drive')
    end

    it 'does not warn or change compilation for non-recursive grammars' do
      code, warnings = compile_grammar(%{
        grammar Test
          rule a
            'x' 'y'
          end
        end
      })
      warnings.should == ''
      code.should_not include('__es_drive')
    end

    it 'does not warn for recursion that only occurs inside a repetition' do
      code, warnings = compile_grammar(%{
        grammar Test
          rule a
            ('x' a)? 'z'
          end
        end
      })
      warnings.should == ''
      code.should_not include('__es_drive')
    end
  end
end
