module Treetop
  module Compiler
    # Compiles a Treetop grammar into a BytecodeProgram: a serializable
    # instruction artifact interpreted by Treetop::Runtime::BytecodeParser.
    #
    # Supported: all core PEG expressions (sequences, ordered choice,
    # terminals incl. insensitive/regexp modifiers, character classes, the
    # anything symbol, repetitions + * and n..m, optionals, and/not
    # predicates, nonterminals), labels, node class declarations (<NodeClass>)
    # and memoization.
    #
    # Not supported (they embed arbitrary Ruby, which this backend never
    # evaluates): semantic predicate blocks (&{ ... } / !{ ... }), inline
    # modules ({ ... }), the 'super' nonterminal, and non-literal require
    # statements. These raise UnsupportedConstructError at compile time.
    class BytecodeCompiler
      class UnsupportedConstructError < StandardError; end

      # Accumulates instructions for one rule, then resolves label operands
      # to absolute instruction indices.
      class Emitter
        Label = Struct.new(:id)

        attr_reader :code

        def initialize
          @code = []
          @labels = {}
          @next_label_id = 0
        end

        def emit(op, *operands)
          @code << [op, *operands]
        end

        def label
          Label.new(@next_label_id += 1)
        end

        def place(label)
          @labels[label] = @code.length
        end

        def resolve
          @code.map do |instr|
            instr.map { |operand| operand.is_a?(Label) ? @labels.fetch(operand) : operand }
          end
        end
      end

      def compile(source)
        parser = MetagrammarParser.new
        result = parser.parse(source)
        raise RuntimeError, (parser.failure_reason || 'could not parse grammar') unless result
        @constants = []
        @constant_indices = {}
        @modules = []
        @module_map = {}
        @includes = []
        @rules = []
        @namespace = []
        @grammar_name = nil
        compile_treetop_file(result)
        BytecodeProgram.new(
          'format'          => BytecodeProgram::FORMAT,
          'version'         => BytecodeProgram::VERSION,
          'treetop_version' => Treetop::VERSION::STRING,
          'grammar'         => @grammar_name,
          'namespace'       => @namespace,
          'root'            => @rules.first && @rules.first['name'],
          'constants'       => @constants,
          'modules'         => @modules,
          'includes'        => @includes,
          'rules'           => @rules
        )
      end

      private

      def compile_treetop_file(node)
        process_requires(node.requires.text_value)
        compile_module_or_grammar(node.module_or_grammar)
      end

      def process_requires(text)
        text.scan(/require[ \t]+([^\n\r]+)/).each do |(target)|
          target = target.strip
          if target =~ /\A"(.*)"\z/ || target =~ /\A'(.*)'\z/
            require $1
          else
            raise UnsupportedConstructError,
              "non-literal require #{target.inspect} is not supported by the bytecode backend"
          end
        end
      end

      def compile_module_or_grammar(node)
        if node.respond_to?(:module_contents)
          kind = node.module_prefix.text_value.strip =~ /\Aclass/ ? 'class' : 'module'
          @namespace << { 'name' => node.module_prefix.name.text_value, 'kind' => kind }
          compile_module_or_grammar(node.module_contents)
        else
          compile_grammar(node)
        end
      end

      def compile_grammar(node)
        @grammar_name = node.grammar_name.text_value
        declaration_sequence = node.declaration_sequence
        declarations = declaration_sequence.respond_to?(:declarations) ? declaration_sequence.declarations : []
        declarations.each do |declaration|
          if declaration.is_a?(ParsingRule)
            compile_rule(declaration)
          else
            @includes << declaration.text_value.strip.sub(/\Ainclude[ \t]+/, '')
          end
        end
      end

      def compile_rule(rule)
        name = rule.name
        rule.parsing_expression.inline_modules.each_with_index do |mod, i|
          case mod
          when SequenceElementAccessorModule
            @module_map[mod.object_id] = @modules.size
            @modules << {
              'name'      => "#{name.treetop_camelize}#{i}",
              'accessors' => accessor_table(mod)
            }
          when InlineModule
            raise UnsupportedConstructError,
              "inline modules { ... } embed Ruby code and are not supported by the bytecode backend (rule #{name})"
          end
        end
        emitter = Emitter.new
        emit_expression(rule.parsing_expression, nil, emitter)
        @rules << { 'name' => name, 'code' => emitter.resolve }
      end

      # Replicates SequenceElementAccessorModule's label method generation.
      def accessor_table(accessor_module)
        elements = accessor_module.sequence_elements
        by_name = {}
        elements.each { |e| (by_name[e.label_name.to_s] ||= []) << e }
        table = {}
        elements.each_with_index do |element, index|
          next unless element.label_name
          repetitions = by_name[element.label_name.to_s]
          label = element.label_name + (repetitions.size > 1 ? (repetitions.index(element) + 1).to_s : '')
          table[label] = index
        end
        table
      end

      def const(value)
        index = @constant_indices[value]
        unless index
          index = @constants.size
          @constants << value
          @constant_indices[value] = index
        end
        index
      end

      # Node class operand for an expression decorated by its parent, or nil
      # for the default SyntaxNode.
      def node_class_operand(parent)
        return nil unless parent
        name = parent.node_class_name
        return nil if name.nil? || name == 'SyntaxNode'
        const(name)
      end

      def emit_expression(node, parent, emitter)
        case node
        when Sequence
          emit_sequence(node, emitter)
        when Choice
          emit_choice(node, parent, emitter)
        when Terminal
          emit_terminal(node, parent, emitter)
        when CharacterClass
          emit_character_class(node, parent, emitter)
        when AnythingSymbol
          emit_anything(node, parent, emitter)
        when Nonterminal
          emit_nonterminal(node, parent, emitter)
        when PredicateBlock
          raise UnsupportedConstructError,
            'semantic predicate blocks (&{ ... } / !{ ... }) embed Ruby code and are not supported by the bytecode backend'
        when AndPredicate, NotPredicate
          emit_predicate(node, parent, emitter)
        when TransientPrefix
          emit_expression(parent.prefixed_expression, nil, emitter)
        when Optional
          emit_optional(node, parent, emitter)
        when Repetition
          emit_repetition(node, parent, emitter)
        when ParenthesizedExpression
          emit_expression(node.elements[2], parent, emitter)
        else
          emit_wrapped(node, parent, emitter)
        end
      end

      # Primary/sequence_primary wrapper nodes defined by metagrammar inline
      # modules: delegate exactly like their generated compile methods do.
      def emit_wrapped(node, parent, emitter)
        if node.respond_to?(:sequence_primary)
          emit_expression(node.sequence_primary, nil, emitter)
        elsif node.respond_to?(:prefix)
          emit_expression(node.prefix, node, emitter)
        elsif node.respond_to?(:suffix)
          emit_expression(node.suffix, node, emitter)
        elsif node.respond_to?(:atomic)
          emit_expression(node.atomic, node, emitter)
        else
          raise UnsupportedConstructError,
            "cannot compile expression #{node.text_value.inspect} with the bytecode backend"
        end
      end

      def emit_sequence(node, emitter)
        fail_label = emitter.label
        end_label = emitter.label
        emitter.emit(:mark)
        emitter.emit(:acc_push)
        node.sequence_elements.each do |element|
          emit_expression(element, nil, emitter)
          emitter.emit(:acc_append)
          emitter.emit(:jmp_unless_acc_last, fail_label)
        end
        emitter.emit(:build_seq_node, sequence_class_operand(node), [accessor_module_index(node)])
        emitter.emit(:jmp, end_label)
        emitter.place(fail_label)
        emitter.emit(:reset)
        emitter.emit(:acc_pop)
        emitter.emit(:push_nil)
        emitter.place(end_label)
      end

      def sequence_class_operand(sequence)
        name = sequence.node_class_name
        (name.nil? || name == 'SyntaxNode') ? nil : const(name)
      end

      def accessor_module_index(sequence)
        @module_map.fetch(sequence.sequence_element_accessor_module.object_id)
      end

      def emit_choice(node, parent, emitter)
        end_label = emitter.label
        emitter.emit(:mark)
        emit_alternatives(node.alternatives, parent, emitter, end_label)
        emitter.place(end_label)
      end

      def emit_alternatives(alternatives, parent, emitter, end_label)
        next_label = emitter.label
        emit_expression(alternatives.first, nil, emitter)
        emitter.emit(:dup)
        emitter.emit(:jmp_if_false, next_label)
        emitter.emit(:unmark)
        if parent && (declared = parent.node_class_name)
          emitter.emit(:extend_result, const(declared))
        end
        emitter.emit(:jmp, end_label)
        emitter.place(next_label)
        emitter.emit(:pop)
        if alternatives.size == 1
          emitter.emit(:reset)
          emitter.emit(:push_nil)
        else
          emit_alternatives(alternatives[1..-1], parent, emitter, end_label)
        end
      end

      def emit_terminal(node, parent, emitter)
        insensitive = node.modifiers.text_value.include?('i')
        regexp = node.modifiers.text_value.include?('r')
        node_class = node_class_operand(parent)
        expected = const(node.string)
        if regexp
          source = "\\A#{eval(node.string)}"
          flags = insensitive ? Regexp::IGNORECASE : 0
          emitter.emit(:match_regexp, const(source), flags, expected, node_class, [])
        elsif insensitive
          emitter.emit(:match_insens, const(eval(node.string).downcase), expected, node_class, [])
        else
          emitter.emit(:match_str, const(eval(node.string)), expected, node_class, [])
        end
      end

      def emit_character_class(node, parent, emitter)
        source = "\\A#{node.text_value}"
        emitter.emit(:match_char_class, const(source), const("[#{node.characters}]"), node_class_operand(parent), [])
      end

      def emit_anything(node, parent, emitter)
        emitter.emit(:match_any, const('any character'), node_class_operand(parent), [])
      end

      def emit_nonterminal(node, parent, emitter)
        name = node.text_value
        if name == 'super'
          raise UnsupportedConstructError,
            "the 'super' nonterminal is not supported by the bytecode backend"
        end
        declared = parent && parent.node_class_name
        emitter.emit(:call, const(name), declared ? const(declared) : nil)
      end

      def emit_optional(node, parent, emitter)
        epsilon_label = emitter.label
        end_label = emitter.label
        emit_expression(parent.atomic, nil, emitter)
        emitter.emit(:dup)
        emitter.emit(:jmp_if_false, epsilon_label)
        emitter.emit(:jmp, end_label)
        emitter.place(epsilon_label)
        emitter.emit(:pop)
        emitter.emit(:epsilon)
        emitter.place(end_label)
      end

      def emit_repetition(node, parent, emitter)
        min, max = repetition_bounds(node)
        node_class = node_class_operand(parent)
        top_label = emitter.label
        done_label = emitter.label
        end_label = emitter.label
        emitter.emit(:mark)
        emitter.emit(:acc_push)
        emitter.place(top_label)
        emit_expression(parent.atomic, nil, emitter)
        emitter.emit(:dup)
        emitter.emit(:jmp_if_false, done_label)
        emitter.emit(:acc_append)
        emitter.emit(:acc_size_jmp_eq, max, done_label) if max
        emitter.emit(:jmp, top_label)
        emitter.place(done_label)
        emitter.emit(:pop)
        fail_label = nil
        if min && min > 0
          fail_label = emitter.label
          emitter.emit(:acc_size_jmp_lt, min, fail_label)
        end
        if max && max > 0
          skip_label = emitter.label
          emitter.emit(:acc_size_jmp_ge, max, skip_label)
          emitter.emit(:pop_terminal_failure)
          emitter.place(skip_label)
        end
        emitter.emit(:build_seq_node, node_class, [])
        emitter.emit(:jmp, end_label)
        if fail_label
          emitter.place(fail_label)
          emitter.emit(:reset)
          emitter.emit(:acc_pop)
          emitter.emit(:push_nil)
        end
        emitter.place(end_label)
      end

      def repetition_bounds(node)
        case node
        when ZeroOrMore
          [0, nil]
        when OneOrMore
          [1, nil]
        else
          min = node.min.empty? ? nil : node.min.text_value.to_i
          max = node.max.empty? ? nil : node.max.text_value.to_i
          [min, max]
        end
      end

      def emit_predicate(node, parent, emitter)
        prefixed = parent.prefixed_expression
        if prefixed.is_a?(PredicateBlock)
          raise UnsupportedConstructError,
            'semantic predicate blocks (&{ ... } / !{ ... }) embed Ruby code and are not supported by the bytecode backend'
        end
        inner_failed = emitter.label
        end_label = emitter.label
        emitter.emit(:mark)
        emit_expression(prefixed, nil, emitter)
        if node.is_a?(AndPredicate)
          emitter.emit(:jmp_if_false, inner_failed)
          emitter.emit(:reset)
          emitter.emit(:epsilon)
          emitter.emit(:jmp, end_label)
          emitter.place(inner_failed)
          emitter.emit(:reset)
          emitter.emit(:push_nil)
        else
          expected = expected_value(parent.atomic)
          emitter.emit(:jmp_if_false, inner_failed)
          emitter.emit(:reset)
          emitter.emit(:record_unexpected_failure, const(expected)) if expected
          emitter.emit(:push_nil)
          emitter.emit(:jmp, end_label)
          emitter.place(inner_failed)
          emitter.emit(:pop_terminal_failure) if expected
          emitter.emit(:reset)
          emitter.emit(:epsilon)
        end
        emitter.place(end_label)
      end

      # The failure expectation string the Ruby backend would report for an
      # atomic expression, or nil when it has none.
      def expected_value(node)
        case node
        when Terminal
          node.string
        when CharacterClass
          "[#{node.characters}]"
        when AnythingSymbol
          'any character'
        when Sequence
          '<a sequence>'
        when Choice
          '(any alternative)'
        when ParenthesizedExpression
          expected_value(node.elements[2])
        else
          nil
        end
      end
    end
  end
end
