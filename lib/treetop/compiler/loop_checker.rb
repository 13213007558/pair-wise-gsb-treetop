module Treetop
  module Compiler
    # Raised when a grammar is rejected because static analysis found a
    # rule invocation cycle or repetition that can loop forever without
    # consuming input.
    class NonConsumingLoopError < RuntimeError; end

    # Static analysis that detects expressions which may loop forever
    # without consuming input: left-recursive rule call chains and
    # repetitions whose body can succeed on empty input.
    #
    # Nullability, lookahead (&/!) and ordered choice are combined to
    # decide whether a rule can be re-entered before any input has been
    # consumed. User semantic predicates (&{ ... } / !{ ... }) and other
    # unanalyzable constructs (such as +super+) cannot be proven either
    # way, so any result depending on them is reported as :unknown
    # rather than assumed safe.
    class LoopChecker
      UNKNOWN = :unknown
      DEFINITE = :definite

      Diagnostic = Struct.new(:kind, :status, :message, :chain)

      # Analyzes every grammar in a metagrammar parse tree and returns
      # an array of Diagnostics (empty when no loops were found).
      def check(root)
        find_grammars(root).inject([]) do |diagnostics, grammar|
          diagnostics + check_grammar(grammar)
        end
      end

      private

      def find_grammars(node, grammars = [])
        grammars << node if node.is_a?(Grammar)
        elements = node.respond_to?(:elements) ? node.elements : nil
        elements.each { |elt| find_grammars(elt, grammars) } if elements
        grammars
      end

      def check_grammar(grammar)
        declaration_sequence = grammar.declaration_sequence
        rule_nodes = declaration_sequence.respond_to?(:rules) ? declaration_sequence.rules : []
        @rules = {}
        rule_nodes.each { |rule| @rules[rule.name] = rule }
        compute_nullability
        recursion_diagnostics + repetition_diagnostics
      end

      # Tri-state nullability, computed as a fixpoint over the rules of
      # the grammar. true means the expression can provably succeed
      # without consuming input, false that it provably cannot, and
      # UNKNOWN that success on empty input depends on user code.
      def compute_nullability
        @nullable = {}
        @rules.each_key { |name| @nullable[name] = false }
        loop do
          changed = false
          @rules.each do |name, rule|
            value = nullable(rule.parsing_expression)
            if @nullable[name] != value
              @nullable[name] = value
              changed = true
            end
          end
          break unless changed
        end
      end

      def nullable(node)
        case node
        when Choice
          node.alternatives.inject(false) { |acc, alt| tri_or(acc, nullable(alt)) }
        when Sequence
          node.sequence_elements.inject(true) { |acc, elt| tri_and(acc, nullable(elt)) }
        when Nonterminal
          nullable_nonterminal(node.text_value)
        when Terminal
          terminal_nullable(node)
        when CharacterClass, AnythingSymbol
          false
        when ParenthesizedExpression
          nullable(node.elements[2])
        else
          nullable_wrapper(node)
        end
      end

      def nullable_nonterminal(name)
        return UNKNOWN if name == 'super'
        @nullable.fetch(name, UNKNOWN)
      end

      def terminal_nullable(node)
        eval(node.string).empty?
      rescue StandardError
        UNKNOWN
      end

      # Primary expressions parse into anonymous SyntaxNodes whose shape
      # is identified by their labeled children.
      def nullable_wrapper(node)
        if node.respond_to?(:sequence_primary)
          nullable(node.sequence_primary)
        elsif node.respond_to?(:prefix) && node.respond_to?(:atomic)
          nullable_prefixed(node)
        elsif node.respond_to?(:suffix) && node.respond_to?(:atomic)
          nullable_suffixed(node)
        elsif node.respond_to?(:atomic)
          nullable(node.atomic)
        else
          UNKNOWN
        end
      end

      def nullable_prefixed(node)
        inner = node.atomic
        return UNKNOWN if inner.is_a?(PredicateBlock)
        case node.prefix
        when TransientPrefix
          nullable(inner)
        when AndPredicate
          # &e succeeds without consuming whenever e succeeds; only
          # provable when e itself can succeed on empty input.
          nullable(inner) == true ? true : UNKNOWN
        when NotPredicate
          UNKNOWN
        else
          UNKNOWN
        end
      end

      def nullable_suffixed(node)
        case node.suffix
        when Optional, ZeroOrMore
          true
        when OneOrMore
          nullable(node.atomic)
        when OccurrenceRange
          node.suffix.min.text_value.to_i == 0 ? true : nullable(node.atomic)
        else
          UNKNOWN
        end
      end

      def tri_and(a, b)
        return false if a == false || b == false
        a == true && b == true ? true : UNKNOWN
      end

      def tri_or(a, b)
        return true if a == true || b == true
        a == false && b == false ? false : UNKNOWN
      end

      # The set of rules that +node+ may invoke before any input is
      # consumed, as a hash of rule name => DEFINITE/UNKNOWN. An edge is
      # UNKNOWN when reaching the call depends on a semantic predicate.
      def first_calls(node)
        case node
        when Choice
          node.alternatives.inject({}) { |acc, alt| merge_calls(acc, first_calls(alt)) }
        when Sequence
          calls = {}
          confidence = DEFINITE
          node.sequence_elements.each do |elt|
            merge_calls(calls, first_calls(elt), confidence)
            case nullable(elt)
            when false then break
            when UNKNOWN then confidence = UNKNOWN
            end
          end
          calls
        when Nonterminal
          node.text_value == 'super' ? {} : { node.text_value => DEFINITE }
        when ParenthesizedExpression
          first_calls(node.elements[2])
        when Terminal, CharacterClass, AnythingSymbol, PredicateBlock
          {}
        else
          first_calls_wrapper(node)
        end
      end

      def first_calls_wrapper(node)
        if node.respond_to?(:sequence_primary)
          first_calls(node.sequence_primary)
        elsif node.respond_to?(:prefix) && node.respond_to?(:atomic)
          # Lookahead evaluates its body at the current position, so
          # calls inside &e/!e/~e still happen before input is consumed.
          node.atomic.is_a?(PredicateBlock) ? {} : first_calls(node.atomic)
        elsif node.respond_to?(:suffix) && node.respond_to?(:atomic)
          first_calls(node.atomic)
        elsif node.respond_to?(:atomic)
          first_calls(node.atomic)
        else
          {}
        end
      end

      def merge_calls(calls, other, confidence = DEFINITE)
        other.each do |name, conf|
          conf = UNKNOWN if confidence == UNKNOWN
          calls[name] = calls[name] == DEFINITE ? DEFINITE : conf
        end
        calls
      end

      def rule_edges
        @rule_edges ||= @rules.inject({}) do |edges, (name, rule)|
          calls = first_calls(rule.parsing_expression).select { |target, _| @rules.key?(target) }
          edges.merge(name => calls)
        end
      end

      def recursion_diagnostics
        edges = rule_edges
        strongly_connected_components(edges).inject([]) do |diagnostics, scc|
          next diagnostics unless scc.size > 1 || edges[scc.first].key?(scc.first)
          chain = cycle_chain(scc, edges)
          status = chain_status(chain, edges)
          diagnostics << Diagnostic.new(:recursion, status, recursion_message(chain, status), chain)
        end
      end

      def cycle_chain(scc, edges)
        start = scc.first
        return [start, start] if scc.size == 1
        find_cycle(start, start, scc, edges, {}, []) || [start, start]
      end

      def find_cycle(current, start, scc, edges, visited, path)
        path << current
        return path.dup if current == start && path.size > 1
        unless visited[current]
          visited[current] = true
          edges[current].each_key do |nxt|
            next unless scc.include?(nxt)
            result = find_cycle(nxt, start, scc, edges, visited, path)
            return result if result
          end
        end
        path.pop
        nil
      end

      def chain_status(chain, edges)
        chain.each_cons(2) do |from, to|
          return UNKNOWN if edges[from][to] == UNKNOWN
        end
        DEFINITE
      end

      def recursion_message(chain, status)
        chain_text = chain.join(' -> ')
        if status == DEFINITE
          "rule `#{chain.first}` can recurse without consuming input " +
            "(call chain: #{chain_text}); parsing will loop forever"
        else
          "rule `#{chain.first}` may recurse without consuming input " +
            "(call chain: #{chain_text}); semantic predicates prevent proving it safe"
        end
      end

      def repetition_diagnostics
        diagnostics = []
        @rules.each do |name, rule|
          each_expression(rule.parsing_expression) do |node|
            next unless node.respond_to?(:suffix) && node.respond_to?(:atomic)
            next unless unbounded_repetition?(node.suffix)
            status = nullable(node.atomic)
            next if status == false
            status = status == true ? DEFINITE : UNKNOWN
            diagnostics << Diagnostic.new(:repetition, status, repetition_message(name, node, status), nil)
          end
        end
        diagnostics
      end

      def unbounded_repetition?(suffix)
        case suffix
        when ZeroOrMore, OneOrMore
          true
        when OccurrenceRange
          suffix.max.text_value.empty?
        else
          false
        end
      end

      def each_expression(node, &block)
        yield node
        elements = node.respond_to?(:elements) ? node.elements : nil
        elements.each { |elt| each_expression(elt, &block) } if elements
      end

      def repetition_message(rule_name, node, status)
        expression = node.text_value.strip.gsub(/\s+/, ' ')
        if status == DEFINITE
          "rule `#{rule_name}` repeats an expression that can succeed " +
            "without consuming input: #{expression}; parsing will loop forever"
        else
          "rule `#{rule_name}` repeats an expression that may succeed " +
            "without consuming input: #{expression}; semantic predicates prevent proving it safe"
        end
      end

      def strongly_connected_components(edges)
        index = {}
        lowlink = {}
        on_stack = {}
        stack = []
        counter = [0]
        sccs = []
        strongconnect = lambda do |v|
          index[v] = lowlink[v] = counter[0]
          counter[0] += 1
          stack.push(v)
          on_stack[v] = true
          edges[v].each_key do |w|
            if !index.key?(w)
              strongconnect.call(w)
              lowlink[v] = [lowlink[v], lowlink[w]].min
            elsif on_stack[w]
              lowlink[v] = [lowlink[v], index[w]].min
            end
          end
          if lowlink[v] == index[v]
            scc = []
            begin
              w = stack.pop
              on_stack.delete(w)
              scc << w
            end while w != v
            sccs << scc
          end
        end
        edges.each_key { |v| strongconnect.call(v) unless index.key?(v) }
        sccs
      end
    end
  end
end
