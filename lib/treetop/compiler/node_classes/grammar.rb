module Treetop
  module Compiler
    class Grammar < Runtime::SyntaxNode
      def compile
        check_for_left_recursion
        builder = RubyBuilder.new

        builder.module_declaration "#{grammar_name.text_value}" do
          builder.in(indent_level) # account for initial indentation of grammar declaration
          builder << "include Treetop::Runtime"
          builder.newline
          declaration_sequence.compile(builder)
          builder.newline
          builder.class_declaration "Parser < Treetop::Runtime::CompiledParser" do
            builder << "include #{grammar_name.text_value}"
          end
        end
        builder.newline
        builder << "(remove_const(:#{parser_name}) if const_defined?(:#{parser_name})) rescue nil; #{parser_name} = #{grammar_name.text_value}::Parser"
      end

      def check_for_left_recursion
        mode = Treetop::Compiler.left_recursion_mode
        # An empty declaration sequence parses to a plain syntax node.
        rules = declaration_sequence.respond_to?(:rules) ? declaration_sequence.rules : []
        LeftRecursionDetector.new(rules).analyze.each do |problem|
          if problem.definite? && mode == :error
            raise LeftRecursionError.new(problem.message)
          else
            $stderr.puts "Warning: #{problem.message}"
          end
        end
      end

      def indent_level
        input.column_of(interval.begin) - 1
      end

      def parser_name
        grammar_name.text_value + 'Parser'
      end
    end
  end
end
