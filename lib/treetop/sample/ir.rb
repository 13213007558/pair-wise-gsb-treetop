module Treetop
  module Sample
    # Normalised intermediate representation of a Treetop grammar.
    #
    # Kinds:
    #   :choice     children = alternatives in order; value = {branch_id, rule}
    #   :seq        children = sequence expressions
    #   :terminal   value = literal String
    #   :char_class value = raw character-set text (inside [...])
    #   :any_char   value = nil (.)
    #   :nonterminal value = rule name
    #   :optional   children = [inner]
    #   :repeat     children = [inner]; value = {min:, max:} (max nil = unbounded)
    #   :and/:not   children = [inner] (lookahead predicates)
    #   :semantic   embedded Ruby block; outcome cannot be evaluated
    #   :epsilon    empty string
    Node = Struct.new(:kind, :children, :value, keyword_init: true) do
      def each_choice(&block)
        if kind == :choice
          block.call(self)
          children.each { |child| child.each_choice(&block) }
        else
          children.each { |child| child.each_choice(&block) }
        end
      end

      def contains?(wanted)
        kind == wanted || children.any? { |child| child.contains?(wanted) }
      end

      def inspect
        "##{kind}#{value.inspect}"
      end
    end

    Rule = Struct.new(:name, :expr, :index)

    class Grammar
      attr_reader :rules, :root_name, :module_name

      def initialize(module_name, root_name, rules)
        @module_name = module_name
        @root_name = root_name
        @rules = rules
      end

      def [](name)
        @rules[name]
      end

      def each_choice
        @rules.each_value do |rule|
          rule.expr.each_choice { |choice| yield(rule, choice) }
        end
      end
    end

    # Converts the metagrammar parse tree into IR. The grammar must have been
    # compiled once with Treetop::Compiler.branch_coverage? == true so that
    # Choice branch ids are available in Compiler.choice_branch_registry.
    class Normaliser
      DECORATED = {
        'Choice' => :choice,
        'Sequence' => :seq,
        'Terminal' => :terminal,
        'CharacterClass' => :char_class,
        'AnythingSymbol' => :any_char,
        'Nonterminal' => :nonterminal,
        'ParenthesizedExpression' => :paren,
        'Optional' => :optional,
        'ZeroOrMore' => :zero,
        'OneOrMore' => :one,
        'OccurrenceRange' => :range,
        'AndPredicate' => :and,
        'NotPredicate' => :not,
        'TransientPrefix' => :transient,
        'PredicateBlock' => :semantic
      }.freeze

      def self.from_treetop_file(root_node)
        new.send(:from_root, root_node)
      end

      private

      def from_root(root_node)
        mod_or_grammar = root_node.module_or_grammar
        module_names = []
        grammar = mod_or_grammar
        until grammar.is_a?(Treetop::Compiler::Grammar)
          module_names << grammar.module_prefix.name.text_value
          grammar = grammar.module_contents
        end

        rule_nodes = grammar.declaration_sequence.rules
        rules = {}
        rule_nodes.each_with_index do |rule_node, index|
          rules[rule_node.name] =
            Rule.new(rule_node.name, convert(rule_node.parsing_expression), index)
        end
        Grammar.new(module_names.empty? ? nil : module_names.join('::'),
                    rule_nodes.first.name, rules)
      end

      def kind_of(node)
        DECORATED[node.class.name.sub(/\ATreetop::Compiler::/, '')] rescue nil
      end

      # Convert any metagrammar node (decorated or wrapper) into IR.
      def convert(node)
        kind = kind_of(node)
        case kind
        when :choice then convert_choice(node)
        when :seq
          Node.new(kind: :seq,
                   children: node.sequence_elements.map { |elt| convert(elt.sequence_primary) },
                   value: nil)
        when :terminal
          Node.new(kind: :terminal, children: [], value: literal_string(node))
        when :char_class
          Node.new(kind: :char_class, children: [], value: node.characters)
        when :any_char then Node.new(kind: :any_char, children: [], value: nil)
        when :nonterminal then Node.new(kind: :nonterminal, children: [], value: node.text_value)
        when :paren then convert(node.elements[2])
        when :optional
          Node.new(kind: :optional, children: [convert(node.parent_expression.atomic)], value: nil)
        when :zero
          Node.new(kind: :repeat, children: [convert(node.parent_expression.atomic)],
                   value: {min: 0, max: nil})
        when :one
          Node.new(kind: :repeat, children: [convert(node.parent_expression.atomic)],
                   value: {min: 1, max: nil})
        when :range
          min = node.min.text_value.empty? ? 0 : node.min.text_value.to_i
          max = node.max.text_value.empty? ? nil : node.max.text_value.to_i
          Node.new(kind: :repeat, children: [convert(node.parent_expression.atomic)],
                   value: {min: min, max: max})
        when :and
          Node.new(kind: :and, children: [convert(node.parent_expression.prefixed_expression)], value: nil)
        when :not
          Node.new(kind: :not, children: [convert(node.parent_expression.prefixed_expression)], value: nil)
        when :transient then convert(node.parent_expression.prefixed_expression)
        when :semantic then Node.new(kind: :semantic, children: [], value: node.text_value)
        else
          convert_wrapper(node)
        end
      end

      def convert_choice(node)
        rule_name, address = Treetop::Compiler.choice_branch_registry[node.object_id]
        raise "missing branch registry entry for a choice; compile with coverage enabled" unless rule_name
        Node.new(kind: :choice,
                 children: node.alternatives.map { |alt| convert_alternative(alt) },
                 value: {branch_id: "#{rule_name}@#{address}", rule: rule_name, address: address})
      end

      # alternative := sequence / primary. Plain SyntaxNode; find the actual
      # decorated child structurally.
      def convert_alternative(node)
        if kind_of(node)
          convert(node)
        else
          convert_wrapper(node)
        end
      end

      def first_decorated_descendant(node)
        return node if kind_of(node)
        node.elements.each do |element|
          found = first_decorated_descendant(element)
          return found if found
        end
        nil
      end

      # Undecorated wrapper rules: primary, sequence_primary, suffix, prefix,
      # sequence_body, optionally_labeled_sequence_primary.
      def convert_wrapper(node)
        if node.respond_to?(:sequence_primary)
          convert(node.sequence_primary)
        elsif node.respond_to?(:prefix) && node.respond_to?(:atomic) &&
              node.atomic.is_a?(Treetop::Compiler::PredicateBlock)
          # Primary form: prefix space? atomic:predicate_block
          body = Node.new(kind: :semantic, children: [], value: node.atomic.text_value)
          apply_predicate_prefix(node.prefix, body)
        elsif node.respond_to?(:suffix)
          body = convert(node.atomic)
          apply_suffix(node.suffix, body)
        elsif node.respond_to?(:prefix) && node.respond_to?(:atomic)
          apply_predicate_prefix(node.prefix, convert(node.atomic))
        elsif node.respond_to?(:atomic)
          convert(node.atomic)
        elsif node.respond_to?(:parsing_expression)
          convert(node.parsing_expression)
        else
          decorated = first_decorated_descendant(node)
          decorated ? convert(decorated) : Node.new(kind: :epsilon, children: [], value: nil)
        end
      end

      def apply_suffix(suffix, body)
        case kind_of(suffix)
        when :optional then Node.new(kind: :optional, children: [body], value: nil)
        when :zero then Node.new(kind: :repeat, children: [body], value: {min: 0, max: nil})
        when :one then Node.new(kind: :repeat, children: [body], value: {min: 1, max: nil})
        when :range
          min = suffix.min.text_value.empty? ? 0 : suffix.min.text_value.to_i
          max = suffix.max.text_value.empty? ? nil : suffix.max.text_value.to_i
          Node.new(kind: :repeat, children: [body], value: {min: min, max: max})
        else body
        end
      end

      def apply_prefix(prefix, body)
        case kind_of(prefix)
        when :and then Node.new(kind: :and, children: [body], value: nil)
        when :not then Node.new(kind: :not, children: [body], value: nil)
        else body
        end
      end

      # predicate_block primaries are always wrapped in & or ! (the metagrammar
      # requires a prefix there), but be defensive about a bare block.
      def apply_predicate_prefix(prefix, body)
        case kind_of(prefix)
        when :and then Node.new(kind: :and, children: [body], value: nil)
        when :not then Node.new(kind: :not, children: [body], value: nil)
        else body
        end
      end

      def literal_string(terminal_node)
        raw = terminal_node.string
        quote = raw[0]
        closing = raw.rindex(quote)
        if quote == '"'
          eval(raw[0..closing])
        else
          body = raw[1...closing]
          body.gsub(/\\(?:\\|')/m) { |m| m == "\\'" ? "'" : '\\' }
        end
      end
    end
  end
end
