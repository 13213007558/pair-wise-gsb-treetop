require 'set'

module Treetop
  module Sample
    # Builds bounded language tries for every IR expression using a memoised,
    # depth-limited abstract interpretation of the PEG grammar.
    #
    # Soundness conventions
    # ---------------------
    # * Every concrete string stored in a trie is really accepted by the
    #   expression (under-approximation of strings, used to propose samples).
    # * Whenever the bound is reached, or an embedded Ruby semantic predicate
    #   is encountered, the trie is marked unknown. Shadow tests then refuse
    #   to claim unreachability through the affected language.
    class Analyzer
      attr_reader :grammar, :domain, :max_depth, :max_repeat

      def initialize(grammar, domain, max_depth: 6, max_repeat: 3)
        @grammar = grammar
        @domain = domain
        @max_depth = max_depth
        @max_repeat = max_repeat
        @memo = {}
        @on_stack = {}
      end

      # Returns the trie for a rule (or arbitrary expression). The depth budget
      # guards recursive nonterminal unfolding; repeat_budget bounds # of loop
      # unrolls synthesised statically.
      def language_of(node, depth: @max_depth, repeat_budget: @max_repeat)
        key = [node.kind, node.value, depth, repeat_budget, structure_id(node)]
        return @memo[key] if @memo.key?(key)
        if @on_stack[key] || depth.negative?
          return @memo[key] = Trie.unknown
        end
        @on_stack[key] = true
        trie = compute(node, depth, repeat_budget)
        @on_stack.delete(key)
        @memo[key] = trie
      end

      private

      def structure_id(node)
        # Identity of the structural node; values are immutable in the IR.
        node.object_id
      end

      def compute(node, depth, repeat_budget)
        case node.kind
        when :epsilon then Trie.epsilon
        when :terminal then terminal_trie(node.value)
        when :char_class then char_class_trie(node.value)
        when :any_char
          edges = @domain.characters.each_with_object({}) do |char, hash|
            hash[char] = Trie.epsilon
          end
          Trie.new(edges: edges)
        when :nonterminal then nonterminal_trie(node.value, depth)
        when :seq then sequence_trie(node.children, depth, repeat_budget)
        when :choice then union_tries(node.children.map { |c| language_of(c, depth: depth, repeat_budget: repeat_budget) })
        when :optional
          inner = language_of(node.children.first, depth: depth, repeat_budget: repeat_budget)
          inner.union(Trie.epsilon)
        when :repeat then repeat_trie(node, depth, repeat_budget)
        when :and then predicate_trie(node, depth, repeat_budget, true)
        when :not then predicate_trie(node, depth, repeat_budget, false)
        when :semantic then Trie.unknown
        else Trie.unknown
        end
      end

      def terminal_trie(literal)
        node = if literal.empty?
                 Trie.epsilon
               else
                  chars = literal.each_char.to_a
                  chars.reverse.reduce(Trie.epsilon) do |child, char|
                    Trie.new(edges: {char => child})
                  end
                end
        # Keep trie exact even if the literal leaves the configured domain:
        # terminals are legitimate grammar inputs.
        node
      end

      def char_class_trie(body)
        chars = @domain.matching(body)
        Trie.new(edges: chars.each_with_object({}) { |c, h| h[c] = Trie.epsilon })
      end

      def nonterminal_trie(name, depth)
        rule = @grammar[name]
        return Trie.unknown unless rule
        language_of(rule.expr, depth: depth - 1)
      end

      def sequence_trie(children, depth, repeat_budget)
        children.reduce(Trie.epsilon) do |acc, child|
          acc.concat(language_of(child, depth: depth, repeat_budget: repeat_budget))
        end
      end

      def union_tries(tries)
        result = Trie.empty
        tries.each { |trie| result.union!(trie) }
        result
      end

      def repeat_trie(node, depth, repeat_budget)
        min, max = node.value[:min], node.value[:max]
        # Static unroll up to a bounded count. The cap only limits which
        # strings are enumerated; it never fabricates acceptance, and the
        # unknown flag records that longer strings may exist.
        upper = max || (repeat_budget + [min, 1].max)
        upper = [upper, repeat_budget + [min, 1].max].min unless max
        inner = node.children.first
        result = Trie.empty
        (0..upper).each do |count|
          trie = Trie.epsilon
          count.times do
            trie = trie.concat(language_of(inner, depth: depth, repeat_budget: repeat_budget - 1))
          end
          if count >= min
            result.union!(trie)
          end
        end
        bounded_out = max.nil? || max > upper || repeat_budget.zero?
        result.unknown = true if bounded_out && inner_can_grow?(inner)
        result
      end

      def inner_can_grow?(inner)
        trie = language_of(inner)
        !trie.known_empty?
      end

      # Lookahead predicates accept no characters themselves (epsilon on
      # success), but success depends on whether the inner expression matches.
      # The trie contributes epsilon so following sequence elements still
      # yield concrete candidates, but is marked unknown whenever the guard
      # cannot be evaluated exactly; shadow proofs then abstain.
      def predicate_trie(node, depth, repeat_budget, positive)
        inner = node.children.first
        if positive
          if inner.contains?(:semantic)
            Trie.epsilon_with_unknown
          elsif language_of(inner, depth: depth, repeat_budget: repeat_budget).known_empty?
            Trie.empty
          else
            Trie.epsilon_with_unknown
          end
        else
          # Negative lookahead: the complement cannot be exhausted.
          Trie.epsilon_with_unknown
        end
      end
    end

    # Nullability of an expression with respect to the whole grammar. A
    # semantic predicate makes nullability unknown.
    class Nullability
      TRUE = :true
      FALSE = :false
      UNKNOWN = :unknown

      def initialize(grammar)
        @grammar = grammar
        @memo = {}
        @stack = Set.new
      end

      def nullable?(node)
        return @memo[node] if @memo.key?(node)
        return UNKNOWN if @stack.include?(node)
        @stack.add(node)
        result = compute(node)
        @stack.delete(node)
        @memo[node] = result
        result
      end

      private

      def compute(node)
        case node.kind
        when :epsilon, :optional then TRUE
        when :terminal then node.value.empty? ? TRUE : FALSE
        when :char_class, :any_char then FALSE
        when :nonterminal
          rule = @grammar[node.value]
          rule ? nullable?(rule.expr) : FALSE
        when :seq
          node.children.all? { |c| nullable?(c) == TRUE } ? TRUE :
            (node.children.any? { |c| nullable?(c) == UNKNOWN } ? UNKNOWN : FALSE)
        when :choice
          results = node.children.map { |c| nullable?(c) }
          results.include?(TRUE) ? TRUE : (results.include?(UNKNOWN) ? UNKNOWN : FALSE)
        when :repeat
          node.value[:min].zero? ? TRUE : nullable?(node.children.first)
        when :and
          # &e accepts epsilon when e can match some prefix (not specifically
          # epsilon). Treat existence as unknown in general; only known-false
          # inner yields false.
          UNKNOWN
        when :not then UNKNOWN
        when :semantic then UNKNOWN
        else UNKNOWN
        end
      end
    end
  end
end
