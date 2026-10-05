module Treetop
  module Compiler
    class Choice < ParsingExpression
      def compile(address, builder, parent_expression = nil)
        super
        begin_comment(self)
        use_vars :result, :start_index
        compile_alternatives(alternatives, parent_expression)
        end_comment(self)
      end

      def compile_alternatives(alternatives, parent_expression)
        obtain_new_subexpression_address
        alternatives.first.compile(subexpression_address, builder)
        builder.if__ subexpression_success? do
          compile_success_assignment(subexpression_result_var)
        end
        builder.else_ do
          if alternatives.size == 1
            reset_index
            assign_failure start_index_var
          else
            compile_alternatives(alternatives[1..-1], parent_expression)
          end
        end
      end

      def compile_success_assignment(result_var)
        # Undo lazy instantiation:
        builder << "#{result_var} = SyntaxNode.new(input, (index-1)...index) if #{result_var} == true"
        assign_result result_var
        extend_result_with_declared_module
        extend_result_with_inline_module parent_expression
      end

      # Compiles this choice for a rule that is compiled with an explicit
      # stack. Alternatives containing recursive calls in tail position are
      # compiled with compile_step_expression; the choice's result check is
      # replayed in the continuation (see ExplicitStack::ChoiceFrame).
      def compile_step(address, builder, context, parent_expression, machine)
        @address = address
        @builder = builder
        @parent_expression = parent_expression
        begin_comment(self)
        use_vars :result, :start_index
        compile_alternatives_step(alternatives, context, machine)
        end_comment(self)
      end

      def compile_alternatives_step(alternatives, context, machine)
        obtain_new_subexpression_address
        if machine.subtree_has_tail_call?(alternatives.first)
          machine.compile_step_expression(alternatives.first, subexpression_address, builder, context + [ExplicitStack::ChoiceFrame.new(self, subexpression_address, alternatives[1..-1])], nil)
        else
          alternatives.first.compile(subexpression_address, builder)
        end
        builder.if__ subexpression_success? do
          compile_success_assignment(subexpression_result_var)
        end
        builder.else_ do
          if alternatives.size == 1
            reset_index
            assign_failure start_index_var
          else
            compile_alternatives_step(alternatives[1..-1], context, machine)
          end
        end
      end

      def expected
        '"(any alternative)"'
      end
    end
  end
end
