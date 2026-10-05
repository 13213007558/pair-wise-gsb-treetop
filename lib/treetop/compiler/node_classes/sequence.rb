module Treetop
  module Compiler    
    class Sequence < ParsingExpression
      def compile(address, builder, parent_expression = nil)
        super
        begin_comment(self)
        use_vars :result, :start_index, :accumulator
        compile_sequence_elements(sequence_elements)
        compile_result_assignment
        end_comment(self)
      end

      def compile_result_assignment
        builder.if__ "#{accumulator_var}.last" do
          assign_result "instantiate_node(#{node_class_name},input, #{start_index_var}...index, #{accumulator_var})"
          extend_result sequence_element_accessor_module_name if sequence_element_accessor_module_name
          extend_result_with_inline_module parent_expression
        end
        builder.else_ do
          reset_index
          assign_failure start_index_var
        end
      end
      
      def node_class_name
        node_class_declarations.node_class_name || 'SyntaxNode'
      end
      
      # Compiles this sequence for a rule that is compiled with an explicit
      # stack. Only called when the sequence's last element contains a
      # recursive call in tail position; the call itself is compiled as a
      # frame push plus a state return, and the accumulation of its result
      # happens in the continuation (see ExplicitStack::SequenceFrame).
      def compile_step(address, builder, context, parent_expression, machine)
        @address = address
        @builder = builder
        @parent_expression = parent_expression
        begin_comment(self)
        use_vars :result, :start_index, :accumulator
        compile_sequence_elements_step(sequence_elements, context, machine)
        compile_result_assignment
        end_comment(self)
      end

      def compile_sequence_elements_step(elements, context, machine)
        obtain_new_subexpression_address
        if elements.size == 1
          machine.compile_step_expression(elements.first, subexpression_address, builder, context + [ExplicitStack::SequenceFrame.new(self, subexpression_address)], nil)
          accumulate_subexpression_result
        else
          elements.first.compile(subexpression_address, builder)
          accumulate_subexpression_result
          builder.if_ subexpression_success? do
            compile_sequence_elements_step(elements[1..-1], context, machine)
          end
        end
      end

      def compile_sequence_elements(elements)
        obtain_new_subexpression_address
        elements.first.compile(subexpression_address, builder)
        accumulate_subexpression_result
        if elements.size > 1
          builder.if_ subexpression_success? do
            compile_sequence_elements(elements[1..-1])
          end
        end
      end
      
      def sequence_element_accessor_module
        @sequence_element_accessor_module ||= SequenceElementAccessorModule.new(sequence_elements)
      end
      
      def sequence_element_accessor_module_name
        sequence_element_accessor_module.module_name
      end

      def expected
        '"<a sequence>"'
      end
    end
    
    class SequenceElementAccessorModule
      include InlineModuleMixin   
      attr_reader :sequence_elements
      
      def initialize(sequence_elements)
        @sequence_elements = sequence_elements
      end
      
      def compile(idx, builder, rule)
        super
        builder.module_declaration(module_name) do
          elements_by_name = sequence_elements.inject({}){|h,e| (h[e.label_name.to_s] ||= []) << e; h}
          sequence_elements.each_with_index do |element, index|
            if element.label_name
              repetitions = elements_by_name[element.label_name.to_s]
              label_name = element.label_name + (repetitions.size > 1 ? (repetitions.index(element)+1).to_s : "")
              builder.method_declaration(label_name) do
                builder << "elements[#{index}]"
              end
              builder.newline unless index == sequence_elements.size - 1
            end
          end
        end
      end
    end
  end
end
