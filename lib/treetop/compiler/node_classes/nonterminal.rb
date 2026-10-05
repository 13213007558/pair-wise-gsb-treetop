module Treetop
  module Compiler    
    class Nonterminal < AtomicExpression
      def compile(address, builder, parent_expression = nil)
        super
        use_vars :result
        assign_result text_value == 'super' ? 'super' : "_nt_#{text_value}"
        extend_result_with_declared_module
        extend_result_with_inline_module parent_expression
      end

      # Compiles a recursive call in tail position for a rule that is
      # compiled with an explicit stack. Instead of calling the rule's
      # method (which would grow the Ruby call stack), a continuation frame
      # capturing the current state is pushed and a call state is returned
      # to the driver loop (see CompiledParser#__es_drive).
      def compile_step(address, builder, context, parent_expression, machine)
        if machine.tail_call_target?(self)
          @address = address
          @builder = builder
          @parent_expression = parent_expression
          cont = machine.register_cont(context, self)
          builder << "__stack << [:#{cont.name}#{cont.frame_arguments}]"
          builder << "return [:__es_call, :#{text_value}, index]"
        else
          compile(address, builder, parent_expression)
        end
      end

      def inline_module
        nil
      end
    end
  end
end
