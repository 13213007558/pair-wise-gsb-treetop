module Treetop
  module Compiler
    class ParsingRule < Runtime::SyntaxNode

      # When set (see ExplicitStack), this rule is compiled with an explicit
      # execution stack instead of Ruby recursion.
      attr_accessor :stack_machine

      def compile(builder)
        compile_inline_module_declarations(builder)
        if stack_machine
          generate_explicit_stack_methods(builder)
        else
          generate_method_definition(builder)
        end
      end
      
      def compile_inline_module_declarations(builder)
        parsing_expression.inline_modules.each_with_index do |inline_module, i|
          inline_module.compile(i, builder, self)
          builder.newline
        end
      end
      
      def generate_method_definition(builder)
        builder.reset_addresses
        expression_address = builder.next_address
        result_var = "r#{expression_address}"
        
        builder.method_declaration(method_name) do
          builder.assign 'start_index', 'index'
          generate_cache_lookup(builder)
          builder.newline
          parsing_expression.compile(expression_address, builder)
          builder.newline
          generate_cache_storage(builder, result_var)
          builder.newline          
          builder << result_var
        end
      end

      # Generates an entry method with the usual memo cache lookup that
      # delegates to CompiledParser#__es_drive, a step method holding the
      # rule body with tail-position recursive calls replaced by frame
      # pushes, and one continuation method per such call site.
      def generate_explicit_stack_methods(builder)
        builder.reset_addresses
        expression_address = builder.next_address
        result_var = "r#{expression_address}"
        stack_machine.result_var = result_var

        builder.method_declaration(method_name) do
          builder.assign 'start_index', 'index'
          generate_cache_lookup(builder)
          builder.newline
          builder << "__es_drive(:#{name}, start_index)"
        end
        builder.newline

        builder.method_declaration(stack_machine.step_method_name) do
          builder.assign '@index', 'start_index'
          stack_machine.compile_step_expression(parsing_expression, expression_address, builder, [], nil)
          builder.newline
          generate_cache_storage(builder, result_var)
          builder.newline
          builder << "[:__es_value, #{result_var}]"
        end

        stack_machine.each_cont do |cont|
          builder.newline
          builder.method_declaration(cont.method_signature) do
            builder.assign cont.result_var, '__es_result'
            stack_machine.emit_frames(cont.frames, builder)
          end
        end
      end
      
      def generate_cache_lookup(builder)
        builder.if_ "node_cache[:#{name}].has_key?(index)" do
          cache_address = "node_cache[:#{name}][index]"
          builder.assign 'cached', cache_address
          builder.if_ "cached" do
            # Handle lazily instantiated nodes:
            builder << "#{cache_address} = cached = SyntaxNode.new(input, index...(index + 1)) if cached == true"
            builder << '@index = cached.interval.end'
          end
          builder << 'return cached'
        end
      end
      
      def generate_cache_storage(builder, result_var)
        builder.assign "node_cache[:#{name}][start_index]", result_var
      end
      
      def method_name
        "_nt_#{name}"
      end
      
      def name
        nonterminal.text_value
      end
    end
  end
end
