module Treetop
  module Compiler
    class Choice < ParsingExpression
      # When the grammar is compiled with branch coverage enabled
      # (Treetop::Compiler.branch_coverage?), every successful alternative of
      # an ordered choice is reported through
      # Treetop::Runtime.branch_covered!. The reported id is stable and is also
      # assigned to the corresponding Choice branch by the sample generator.
      def compile(address, builder, parent_expression = nil)
        super
        if Treetop::Compiler.branch_coverage?
          rule_name = builder.current_rule_name
          Treetop::Compiler.record_choice_branch(self, rule_name, address)
        end
        begin_comment(self)
        use_vars :result, :start_index
        compile_alternatives(alternatives, 0, parent_expression, branch_choice_id(builder))
        end_comment(self)
      end

      def compile_alternatives(alternatives, alternative_index, parent_expression, choice_id = nil)
        builder << "Treetop::Runtime.branch_begin_choice!" if choice_id
        obtain_new_subexpression_address
        alternatives.first.compile(subexpression_address, builder)
        builder.if__ subexpression_success? do
          if choice_id
            builder << "Treetop::Runtime.branch_covered!(#{choice_id.inspect}, #{alternative_index})"
            builder << "Treetop::Runtime.branch_commit_choice!"
          end
          # Undo lazy instantiation:
          builder << "#{subexpression_result_var} = SyntaxNode.new(input, (index-1)...index) if #{subexpression_result_var} == true"
          assign_result subexpression_result_var
          extend_result_with_declared_module
          extend_result_with_inline_module parent_expression
        end
        builder.else_ do
          builder << "Treetop::Runtime.branch_rollback_choice!" if choice_id
          if alternatives.size == 1
            reset_index
            assign_failure start_index_var
          else
            compile_alternatives(alternatives[1..-1], alternative_index + 1, parent_expression, choice_id)
          end
        end
      end

      # The rule name is available on the enclosing ParsingRule while the
      # expression tree is compiled.
      def branch_choice_id(builder)
        return nil unless Treetop::Compiler.branch_coverage?
        rule_name = builder.current_rule_name
        rule_name && "#{rule_name}@#{address}"
      end

      def expected
        '"(any alternative)"'
      end
    end
  end
end
