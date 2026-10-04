module Treetop
  module Compiler
    class Choice < ParsingExpression
      def compile(address, builder, parent_expression = nil)
        super
        begin_comment(self)
        use_vars :result, :start_index
        compile_alternatives(alternatives, parent_expression, 0)
        end_comment(self)
      end

      def compile_alternatives(alternatives, parent_expression, branch_index)
        obtain_new_subexpression_address
        alternatives.first.compile(subexpression_address, builder)
        builder.if__ subexpression_success? do
          # Undo lazy instantiation:
          builder << "#{subexpression_result_var} = SyntaxNode.new(input, (index-1)...index) if #{subexpression_result_var} == true"
          assign_result "treetop_mark_choice_coverage(#{subexpression_result_var}, #{choice_coverage_id(branch_index)})"
          extend_result_with_declared_module
          extend_result_with_inline_module parent_expression
        end
        builder.else_ do
          if alternatives.size == 1
            reset_index
            assign_failure start_index_var
          else
            compile_alternatives(alternatives[1..-1], parent_expression, branch_index + 1)
          end
        end
      end

      def choice_coverage_id(branch_index)
        %{"choice:#{interval.begin}:#{branch_index}"}
      end

      def expected
        '"(any alternative)"'
      end
    end
  end
end
