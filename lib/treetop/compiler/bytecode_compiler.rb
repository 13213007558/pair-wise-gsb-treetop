require 'treetop/version'

module Treetop
  module Compiler
    # Raised when a grammar uses a feature the bytecode backend cannot
    # compile without evaluating embedded Ruby source (semantic predicates,
    # inline modules, super, include declarations, ...).
    class UnsupportedFeatureError < StandardError; end

    # Compiles a Treetop grammar into a versioned, eval-free bytecode
    # artifact (a plain Ruby data structure, serialized with Marshal).
    # The artifact is executed by Treetop::Runtime::InterpretedParser and
    # loaded through Treetop::Runtime::BytecodeLoader.
    class BytecodeCompiler
      FORMAT = 'treetop-bytecode'.freeze
      VERSION = 1

      CONSTANT_PATH = /\A[A-Z]\w*(::[A-Z]\w*)*\z/

      def compile(source_path, target_path = source_path.gsub(/\.(treetop|tt)\Z/, '.ttc'))
        artifact = compile_to_artifact(File.read(source_path))
        File.open(target_path, 'wb') do |target_file|
          target_file.write(Marshal.dump(artifact))
        end
        target_path
      end

      # Compile a string of Treetop source into an artifact Hash.
      def compile_to_artifact(source)
        parser = MetagrammarParser.new
        result = parser.parse(source)
        unless result
          raise RuntimeError.new(parser.failure_reason)
        end
        compile_treetop_file(result)
      end

      private

      def compile_treetop_file(node)
        requires = extract_requires(node)
        module_path = []
        grammar_node = unwrap_modules(node.module_or_grammar, module_path)
        compile_grammar(grammar_node, module_path, requires)
      end

      def extract_requires(treetop_file)
        treetop_file.requires.text_value.scan(/require\s+['"]([^'"]+)['"]/).flatten
      end

      def unwrap_modules(node, module_path)
        while node.respond_to?(:module_prefix)
          kind = node.module_prefix.text_value.strip.start_with?('class') ? 'class' : 'module'
          node.module_prefix.name.text_value.split('::').each do |name|
            module_path << [name, kind]
          end
          node = node.module_contents
        end
        node
      end

      def compile_grammar(grammar_node, module_path, requires)
        @constants = []
        @constant_index = {}
        @accessors = []
        @accessor_index = {}

        rules = []
        grammar_node.declaration_sequence.declarations.each do |declaration|
          if declaration.instance_of?(ParsingRule)
            rules << compile_rule(declaration)
          else
            raise UnsupportedFeatureError,
              "'include' declarations are not supported by the bytecode backend: " + declaration.text_value.strip
          end
        end

        {
          'format'          => FORMAT,
          'version'         => VERSION,
          'treetop_version' => Treetop::VERSION::STRING,
          'module_path'     => module_path,
          'grammar_name'    => grammar_node.grammar_name.text_value,
          'root'            => rules.first && rules.first['name'],
          'requires'        => requires,
          'constants'       => @constants,
          'accessors'       => @accessors,
          'rules'           => rules
        }
      end

      def compile_rule(rule)
        check_supported!(rule.parsing_expression)
        @code = []
        @slots = 1 # slot 0 holds the rule's start_index, used for memoization
        emit(:save_index, 0)
        cache_lookup = emit(:cache_lookup, rule.name, nil)
        compile_expression(rule.parsing_expression, :root => true, :parent => nil)
        emit(:cache_store, rule.name, 0)
        return_ip = emit(:return)
        patch(cache_lookup, 2, return_ip)
        { 'name' => rule.name, 'slots' => @slots, 'code' => @code }
      end

      # Reject grammar constructs that would require evaluating embedded Ruby.
      def check_supported!(node)
        case node
        when InlineModule
          raise UnsupportedFeatureError,
            'inline modules { ... } embed Ruby code and are not supported by the bytecode backend'
        when PredicateBlock
          raise UnsupportedFeatureError,
            'semantic predicates embed Ruby code and are not supported by the bytecode backend'
        end
        return unless node.respond_to?(:elements) && node.elements
        node.elements.each do |element|
          check_supported!(element) unless element == true
        end
      end

      def compile_expression(node, root:, parent:)
        if node.instance_of?(Sequence)
          compile_sequence(node)
        elsif node.instance_of?(Choice)
          compile_choice(node, parent)
        elsif primary_wrapper?(node)
          compile_primary_wrapper(node, root)
        else
          compile_leaf(node, root, parent)
        end
      end

      # Metagrammar "primary"/"sequence_primary" alternatives are plain
      # SyntaxNodes extended with accessor modules; only user-level
      # sequences and choices carry the Sequence/Choice node classes.
      def primary_wrapper?(node)
        node.respond_to?(:prefixed_expression) ||
          (node.respond_to?(:suffix) && node.respond_to?(:atomic)) ||
          (node.respond_to?(:node_class_declarations) && node.respond_to?(:atomic)) ||
          node.respond_to?(:sequence_primary)
      end

      def compile_primary_wrapper(node, root)
        if node.respond_to?(:prefixed_expression)
          # prefix atomic / prefix predicate_block
          compile_expression(node.prefix, :root => root, :parent => node)
        elsif node.respond_to?(:suffix)
          # atomic suffix (node_class_declarations)?
          compile_expression(node.suffix, :root => root, :parent => node)
        elsif node.respond_to?(:node_class_declarations)
          # atomic node_class_declarations
          compile_expression(node.atomic, :root => root, :parent => node)
        elsif node.respond_to?(:sequence_primary)
          # labeled / unlabeled sequence primary
          compile_expression(node.sequence_primary, :root => root, :parent => nil)
        else
          raise 'Bytecode compiler cannot compile: ' + node.text_value.inspect
        end
      end

      def compile_leaf(node, root, parent)
        case node
        when Terminal
          compile_terminal(node, root, parent)
        when CharacterClass
          compile_character_class(node, root, parent)
        when AnythingSymbol
          compile_anything(node, root, parent)
        when Nonterminal
          compile_nonterminal(node, parent)
        when Repetition
          compile_repetition(node, parent)
        when Optional
          compile_optional(node, parent)
        when AndPredicate
          compile_and_predicate(node, parent)
        when NotPredicate
          compile_not_predicate(node, parent)
        when TransientPrefix
          compile_expression(parent.prefixed_expression, :root => root, :parent => nil)
        when ParenthesizedExpression
          compile_expression(node.elements[2], :root => root, :parent => parent)
        when PredicateBlock
          raise UnsupportedFeatureError,
            'semantic predicates embed Ruby code and are not supported by the bytecode backend'
        else
          raise 'Bytecode compiler cannot compile ' + node.class.to_s + ': ' + node.text_value.inspect
        end
      end

      def compile_sequence(node)
        start_slot = alloc_slot
        acc_slot = alloc_slot
        emit(:save_index, start_slot)
        emit(:new_acc, acc_slot)
        failure_fixups = []
        node.sequence_elements.each do |element|
          compile_expression(element, :root => false, :parent => nil)
          emit(:accumulate, acc_slot)
          failure_fixups << emit(:jump_unless, nil)
        end
        emit(:make_node, start_slot, acc_slot, const_ref(node.node_class_declarations.node_class_name), accessor_ref(node))
        done = emit(:jump, nil)
        failure_ip = here
        failure_fixups.each { |fixup| patch(fixup, 1, failure_ip) }
        emit(:restore_index, start_slot)
        emit(:set_nil)
        patch(done, 1, here)
      end

      def compile_choice(node, parent)
        start_slot = alloc_slot
        emit(:save_index, start_slot)
        compile_alternatives(node.alternatives, parent, start_slot)
      end

      def compile_alternatives(alternatives, parent, start_slot)
        compile_expression(alternatives.first, :root => false, :parent => nil)
        else_fixup = emit(:jump_unless, nil)
        emit(:materialize_lazy)
        if parent && parent.node_class_name
          emit(:extend_result, const_ref(parent.node_class_name))
        end
        done_fixup = emit(:jump, nil)
        patch(else_fixup, 1, here)
        if alternatives.size == 1
          emit(:restore_index, start_slot)
          emit(:set_nil)
        else
          compile_alternatives(alternatives[1..-1], parent, start_slot)
        end
        patch(done_fixup, 1, here)
      end

      def compile_terminal(node, root, parent)
        modifiers = node.modifiers.text_value
        insensitive = modifiers.include?('i')
        content = unquote(node.string)
        decorated = parent && parent.node_class_name
        class_ref = const_ref(parent && parent.node_class_name)
        if modifiers.include?('r')
          emit(:match_regexp, "\\A" + content, insensitive ? Regexp::IGNORECASE : 0, node.string, false, class_ref)
        elsif insensitive
          emit(:match_string, content.downcase, :insens, node.string, false, class_ref)
        else
          lazy = !(root || decorated || content.length > 1)
          emit(:match_string, content, false, node.string, lazy, class_ref)
        end
      end

      def compile_character_class(node, root, parent)
        decorated = parent && parent.node_class_name
        lazy = !(root || decorated)
        emit(:match_regexp, "\\A" + node.text_value, 0, '[' + node.characters + ']', lazy, const_ref(parent && parent.node_class_name))
      end

      def compile_anything(node, root, parent)
        decorated = parent && parent.node_class_name
        lazy = !(root || decorated)
        emit(:match_any, lazy, const_ref(parent && parent.node_class_name))
      end

      def compile_nonterminal(node, parent)
        name = node.text_value
        if name == 'super'
          raise UnsupportedFeatureError,
            "'super' is not supported by the bytecode backend"
        end
        emit(:call, name)
        if parent && parent.node_class_name
          emit(:extend_result, const_ref(parent.node_class_name))
        end
      end

      def compile_repetition(node, parent)
        repeated = parent.atomic
        start_slot = alloc_slot
        acc_slot = alloc_slot
        emit(:save_index, start_slot)
        emit(:new_acc, acc_slot)
        loop_ip = here
        compile_expression(repeated, :root => false, :parent => nil)
        exit_fixup = emit(:jump_unless, nil)
        emit(:accumulate, acc_slot)
        max = occurrence_max(node)
        max_fixup = nil
        if max
          emit(:acc_size, acc_slot)
          max_fixup = emit(:jump_if_test_eq, max, nil)
        end
        emit(:jump, loop_ip)
        end_ip = here
        patch(exit_fixup, 1, end_ip)
        patch(max_fixup, 2, end_ip) if max_fixup

        case node
        when OneOrMore
          emit(:acc_size, acc_slot)
          empty_fixup = emit(:jump_if_test_eq, 0, nil)
          emit(:make_node, start_slot, acc_slot, const_ref(parent.node_class_name), nil)
          done_fixup = emit(:jump, nil)
          patch(empty_fixup, 2, here)
          emit(:restore_index, start_slot)
          emit(:set_nil)
          patch(done_fixup, 1, here)
        when OccurrenceRange
          min = node.min.empty? ? 0 : node.min.text_value.to_i
          if min > 0
            emit(:acc_size, acc_slot)
            short_fixup = emit(:jump_if_test_lt, min, nil)
            emit_clean_unsaturated(acc_slot, max) if max
            emit(:make_node, start_slot, acc_slot, const_ref(parent.node_class_name), nil)
            done_fixup = emit(:jump, nil)
            patch(short_fixup, 2, here)
            emit(:restore_index, start_slot)
            emit(:set_nil)
            patch(done_fixup, 1, here)
          else
            emit_clean_unsaturated(acc_slot, max) if max
            emit(:make_node, start_slot, acc_slot, const_ref(parent.node_class_name), nil)
          end
        else # ZeroOrMore
          emit(:make_node, start_slot, acc_slot, const_ref(parent.node_class_name), nil)
        end
      end

      def occurrence_max(node)
        node.instance_of?(OccurrenceRange) && !node.max.empty? ? node.max.text_value.to_i : nil
      end

      # Mirror OccurrenceRange#clean_unsaturated: when fewer than the maximum
      # occurrences matched, the trailing terminal failure is discarded.
      def emit_clean_unsaturated(acc_slot, max)
        emit(:acc_size, acc_slot)
        saturated_fixup = emit(:jump_if_test_lt, max, nil)
        done_fixup = emit(:jump, nil)
        patch(saturated_fixup, 2, here)
        emit(:pop_failure)
        patch(done_fixup, 1, here)
      end

      def compile_optional(node, parent)
        compile_expression(parent.atomic, :root => false, :parent => nil)
        else_fixup = emit(:jump_unless, nil)
        done_fixup = emit(:jump, nil)
        patch(else_fixup, 1, here)
        emit(:make_epsilon)
        patch(done_fixup, 1, here)
      end

      def compile_and_predicate(node, parent)
        start_slot = alloc_slot
        emit(:save_index, start_slot)
        compile_expression(parent.prefixed_expression, :root => false, :parent => nil)
        failure_fixup = emit(:jump_unless, nil)
        emit(:restore_index, start_slot)
        emit(:make_epsilon)
        done_fixup = emit(:jump, nil)
        patch(failure_fixup, 1, here)
        emit(:restore_index, start_slot)
        emit(:set_nil)
        patch(done_fixup, 1, here)
      end

      def compile_not_predicate(node, parent)
        expected = expected_of(parent.atomic)
        start_slot = alloc_slot
        emit(:save_index, start_slot)
        compile_expression(parent.prefixed_expression, :root => false, :parent => nil)
        failure_fixup = emit(:jump_unless, nil)
        emit(:restore_index, start_slot)
        emit(:set_nil)
        emit(:record_failure, expected, true) if expected
        done_fixup = emit(:jump, nil)
        patch(failure_fixup, 1, here)
        emit(:pop_failure) if expected
        emit(:restore_index, start_slot)
        emit(:make_epsilon)
        patch(done_fixup, 1, here)
      end

      def expected_of(node)
        case node
        when Terminal
          node.string
        when CharacterClass
          '[' + node.characters + ']'
        when AnythingSymbol
          'any character'
        when ParenthesizedExpression
          expected_of(node.elements[2])
        when Choice
          '(any alternative)'
        when Sequence
          '<a sequence>'
        else
          nil
        end
      end

      # Unquote a string literal as written in the grammar. The metagrammar
      # only allows backslash, quote and double-quote escape sequences
      # inside terminals.
      def unquote(quoted)
        body = quoted[1...-1]
        result = +''
        index = 0
        while index < body.length
          char = body[index]
          if char == "\\" && index + 1 < body.length && ["\\", "'", '"'].include?(body[index + 1])
            result << body[index + 1]
            index += 2
          else
            result << char
            index += 1
          end
        end
        result
      end

      def const_ref(name)
        return nil if name.nil?
        unless name =~ CONSTANT_PATH
          raise UnsupportedFeatureError,
            'node class ' + name.inspect + ' is not a constant path and is not supported by the bytecode backend'
        end
        @constant_index[name] ||= begin
          @constants << name
          @constants.size - 1
        end
      end

      def accessor_ref(sequence_node)
        labels = sequence_labels(sequence_node)
        return nil if labels.empty?
        key = labels.sort_by { |name, _| name }
        @accessor_index[key] ||= begin
          @accessors << labels
          @accessors.size - 1
        end
      end

      # Mirror SequenceElementAccessorModule: later duplicates of a label get
      # a numeric suffix.
      def sequence_labels(sequence_node)
        elements = sequence_node.sequence_elements
        by_name = {}
        elements.each do |element|
          (by_name[element.label_name.to_s] ||= []) << element
        end
        labels = {}
        elements.each_with_index do |element, index|
          next unless element.label_name
          repetitions = by_name[element.label_name.to_s]
          name = element.label_name
          name += (repetitions.index(element) + 1).to_s if repetitions.size > 1
          labels[name] = index
        end
        labels
      end

      def alloc_slot
        slot = @slots
        @slots += 1
        slot
      end

      def emit(*instruction)
        @code << instruction
        @code.size - 1
      end

      def here
        @code.size
      end

      def patch(instruction_index, operand_index, value)
        @code[instruction_index][operand_index] = value
      end
    end
  end
end
