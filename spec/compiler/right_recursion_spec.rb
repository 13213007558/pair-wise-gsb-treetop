require 'spec_helper'

module RightRecursionSpec
  ListNode = Module.new

  describe "a directly right-recursive rule" do
    testing_grammar %{
      grammar Test
        rule list
          head:item ',' tail:list {
            def comma_count
              1 + (tail.respond_to?(:comma_count) ? tail.comma_count : 0)
            end
          }
          /
          last:item {
            def base?
              true
            end
          }
        end
        rule item
          [a-z]
        end
      end
    }

    it "produces the same AST, capture intervals and labels for short input" do
      result = parse('a,b,c')
      result.should_not be_nil
      result.interval.should == (0...5)
      result.text_value.should == 'a,b,c'
      result.elements.size.should == 3
      result.head.text_value.should == 'a'
      result.head.interval.should == (0...1)
      result.tail.interval.should == (2...5)
      result.tail.head.text_value.should == 'b'
      result.tail.tail.interval.should == (4...5)
      result.tail.tail.last.text_value.should == 'c'
    end

    it "constructs semantic nodes at the tail end of the recursion" do
      innermost = parse('a,b,c').tail.tail
      innermost.base?.should == true
      innermost.respond_to?(:comma_count).should == false
    end

    it "keeps inline node module methods callable at every level" do
      result = parse('a,b,c')
      result.comma_count.should == 2
      result.tail.comma_count.should == 1
    end

    it "memoizes every recursion level" do
      parse('a,b,c')
      parser.send(:node_cache)[:list].keys.sort.should == [0, 2, 4]
    end

    it "reports failures near the end at the correct position" do
      parse('a,b,').should be_nil
      parser.failure_index.should == 4
      parser.failure_reason.should =~ /Expected \[a-z\]/
    end

    it "backtracks to the base alternative when the recursion fails" do
      result = parse('a,b,', :consume_all_input => false)
      result.should_not be_nil
      result.interval.should == (0...3)
      result.text_value.should == 'a,b'
    end

    it "parses a very long list without growing the Ruby call stack" do
      count = 30_000
      input = (['a'] * count).join(',')
      result = nil
      Thread.new { result = parser_class_under_test.new.parse(input) }.join
      result.should_not be_nil
      result.interval.should == (0...input.size)
      items = 0
      node = result
      while node.respond_to?(:tail)
        items += 1
        node = node.tail
      end
      items += 1
      items.should == count
      node.last.text_value.should == 'a'
    end

    it "returns the correct failure position at the end of a very long list" do
      count = 20_000
      input = (['a'] * count).join(',') + ','
      parser = nil
      Thread.new do
        parser = parser_class_under_test.new
        parser.parse(input).should be_nil
      end.join
      parser.failure_index.should == input.size
    end
  end

  describe "memoization across re-entrant calls" do
    testing_grammar %{
      grammar Test
        rule top
          list '!' / list
        end
        rule list
          item ',' list / item
        end
        rule item
          [a-z]
        end
      end
    }

    it "reuses cached nodes for every recursion level" do
      result = parse('a,b')
      result.should_not be_nil
      result.interval.should == (0...3)
      cache = parser.send(:node_cache)
      cache[:list].keys.sort.should == [0, 2]
      result.should equal(cache[:list][0])
      result.elements[2].should equal(cache[:list][2])
    end
  end

  describe "mutually right-recursive rules" do
    testing_grammar %{
      grammar Test
        rule ab
          'a' bc / 'a'
        end
        rule bc
          'b' ab / 'b'
        end
      end
    }

    it "parses alternating input with the same AST" do
      result = parse('abab')
      result.should_not be_nil
      result.interval.should == (0...4)
      result.elements.size.should == 2
      result.elements[0].text_value.should == 'a'
      result.elements[1].interval.should == (1...4)
      result.elements[1].elements[1].interval.should == (2...4)
      result.elements[1].elements[1].elements[1].interval.should == (3...4)
    end

    it "parses a very long alternating input" do
      input = 'ab' * 15_000
      result = nil
      Thread.new { result = parser_class_under_test.new.parse(input) }.join
      result.should_not be_nil
      result.interval.should == (0...input.size)
    end

    it "backtracks to base alternatives on failure" do
      result = parse('ababx', :consume_all_input => false)
      result.should_not be_nil
      result.interval.should == (0...4)
      result.text_value.should == 'abab'
    end
  end

  describe "right recursion through a bare nonterminal alternative" do
    testing_grammar %{
      grammar Test
        rule a
          b / 'x' a
        end
        rule b
          'y' a / 'z'
        end
      end
    }

    it "parses with identity recursion" do
      result = parse('xxz')
      result.should_not be_nil
      result.interval.should == (0...3)
      result.elements[0].text_value.should == 'x'
      result.elements[1].elements[0].text_value.should == 'x'
      result.elements[1].elements[1].text_value.should == 'z'
    end
  end

  describe "right recursion through a parenthesized tail call" do
    testing_grammar %{
      grammar Test
        rule a
          'x' rest:(a) / 'y'
        end
      end
    }

    it "treats the parentheses as transparent" do
      result = parse('xxy')
      result.should_not be_nil
      result.interval.should == (0...3)
      result.rest.text_value.should == 'xy'
      result.rest.interval.should == (1...3)
      result.rest.rest.text_value.should == 'y'
      result.rest.rest.interval.should == (2...3)
    end
  end

  describe "right recursion with a node class declaration" do
    testing_grammar %{
      grammar Test
        rule list
          head:item ',' tail:list <RightRecursionSpec::ListNode> / last:item
        end
        rule item
          [a-z]
        end
      end
    }

    it "extends nodes at every level with the declared module" do
      result = parse('a,b,c')
      result.extension_modules.should include(RightRecursionSpec::ListNode)
      result.tail.extension_modules.should include(RightRecursionSpec::ListNode)
    end
  end

  describe "compile-time reporting of inapplicable embedded Ruby" do
    it "reports semantic predicates in right-recursive rules" do
      compiling_grammar(%{
        grammar Test
          rule list
            item &{ |v| true } ',' list / item
          end
          rule item
            [a-z]
          end
        end
      }).should raise_error(Treetop::Compiler::RightRecursionError, /rule 'list'.*semantic predicate/)
    end

    it "reports node class declarations on the recursive reference" do
      compiling_grammar(%{
        grammar Test
          rule a
            'x' a / a <Foo> / 'y'
          end
        end
      }).should raise_error(Treetop::Compiler::RightRecursionError, /node class declaration or inline module/)
    end

    it "reports inline modules on the recursive reference" do
      compiling_grammar(%{
        grammar Test
          rule a
            'x' a / a { def foo; end } / 'y'
          end
        end
      }).should raise_error(Treetop::Compiler::RightRecursionError, /node class declaration or inline module/)
    end

    it "reports inline modules wrapping the recursive expression" do
      compiling_grammar(%{
        grammar Test
          rule a
            ('x' a / 'y') { def foo; end }
          end
        end
      }).should raise_error(Treetop::Compiler::RightRecursionError, /wraps the recursive expression/)
    end
  end

  describe "recursive shapes that fall back to standard compilation" do
    it "compiles recursion under an optional suffix" do
      compiling_grammar(%{
        grammar Test
          rule a
            'x' a? / 'y'
          end
        end
      }).should_not raise_error
    end

    it "compiles recursion nested in a parenthesized repetition" do
      compiling_grammar(%{
        grammar Test
          rule a
            ('x' a)* / 'y'
          end
        end
      }).should_not raise_error
    end

    it "compiles recursion that never reaches a base alternative" do
      compiling_grammar(%{
        grammar Test
          rule a
            'x' a
          end
        end
      }).should_not raise_error
    end
  end

  describe "right recursion combined with super" do
    Treetop.load_from_string(%{
      grammar Base
        rule a
          'x' a / 'y'
        end
      end
    })

    testing_grammar %{
      grammar Test
        include Base
        rule a
          'z' a / super
        end
      end
    }

    it "falls back to standard recursive compilation" do
      result = parse('zxy')
      result.should_not be_nil
      result.interval.should == (0...3)
      result.text_value.should == 'zxy'
    end
  end
end
