module Treetop
  module Compiler
    class LeftRecursionError < StandardError; end

    # How problems found by LeftRecursionDetector are reported:
    # :warn (the default) prints a warning to stderr and compiles anyway;
    # :error rejects grammars with definite problems by raising
    # LeftRecursionError. Problems whose certainty is :unknown (they
    # depend on user-supplied semantic predicates) are always warnings,
    # since they cannot be proven.
    class << self
      attr_writer :left_recursion_mode

      def left_recursion_mode
        @left_recursion_mode ||= :warn
      end

      def with_left_recursion_mode(mode)
        previous = @left_recursion_mode
        @left_recursion_mode = mode
        yield
      ensure
        @left_recursion_mode = previous
      end
    end

    # Static analysis over the rules of a grammar, run at compile time,
    # that detects expressions which can loop forever without consuming
    # any input:
    #
    # * left recursion: a rule that can invoke itself (directly or
    #   through a chain of other rules) before anything has been consumed
    # * repetition of an expression that can succeed without consuming
    #   input (the body of a +, * or unbounded .. loop)
    #
    # The analysis combines nullability (can an expression succeed
    # without consuming input?), lookahead predicates and ordered choice
    # (later alternatives are only reachable if earlier ones can fail).
    #
    # Results are three-valued: true, false or :unknown. User-supplied
    # semantic predicate blocks cannot be evaluated statically, so any
    # conclusion that depends on one is reported as :unknown (a possible
    # problem) rather than optimistically treated as safe.
    class LeftRecursionDetector
      DEFINITE = :definite
      POSSIBLE = :possible

      Problem = Struct.new(:certainty, :message) do
        def definite?
          certainty == DEFINITE
        end
      end

      # nullable and can_fail are three-valued: true, false or :unknown.
      # calls maps rule names invoked before any input is consumed to
      # DEFINITE or POSSIBLE.
      class ExpressionInfo
        attr_reader :nullable, :can_fail, :calls

        def initialize(nullable, can_fail, calls = {})
          @nullable = nullable
          @can_fail = can_fail
          @calls = calls
        end
      end

      def initialize(rules)
        @rules = rules
        @rule_map = {}
        rules.each { |rule| @rule_map[rule.name] = rule }
        @nullable = {}
        @can_fail = {}
        @left_calls = {}
        @cycles = {}
        @problems = []
        @reporting = false
      end

      def analyze
        compute_fixpoint
        @reporting = true
        @rules.each do |rule|
          @current_rule = rule
          @left_calls[rule.name] = expression_info(rule.parsing_expression).calls
        end
        detect_cycles
        report_cycles
        @problems
      end

      private

      # Compute nullability and fallibility of every rule by least
      # fixpoint, starting from the bottom of the three-valued lattice
      # (false) and iterating until nothing changes.
      def compute_fixpoint
        @rules.each do |rule|
          @nullable[rule.name] = false
          @can_fail[rule.name] = false
        end
        loop do
          changed = false
          @rules.each do |rule|
            info = expression_info(rule.parsing_expression)
            changed = true if update(@nullable, rule.name, info.nullable)
            changed = true if update(@can_fail, rule.name, info.can_fail)
          end
          break unless changed
        end
      end

      def update(map, key, value)
        return false if map[key] == value
        map[key] = value
        true
      end

      def tri_and(a, b)
        return false if a == false || b == false
        return :unknown if a == :unknown || b == :unknown
        true
      end

      def tri_or(a, b)
        return true if a == true || b == true
        return :unknown if a == :unknown || b == :unknown
        false
      end

      def expression_info(node)
        case node
        when Choice
          choice_info(node.alternatives)
        when Sequence
          sequence_info(node.sequence_elements)
        when Nonterminal
          nonterminal_info(node.text_value)
        when Terminal
          terminal_info(node)
        when CharacterClass, AnythingSymbol
          ExpressionInfo.new(false, true)
        when ParenthesizedExpression
          expression_info(node.elements[2])
        when PredicateBlock
          # A user-supplied semantic predicate block: its result cannot
          # be determined statically.
          ExpressionInfo.new(:unknown, :unknown)
        else
          primary_info(node)
        end
      end

      # Nodes for primaries are anonymous (they carry no node class
      # declaration in the metagrammar), so dispatch on the labeled
      # children they expose.
      def primary_info(node)
        if node.respond_to?(:sequence_primary)
          expression_info(node.sequence_primary)
        elsif node.respond_to?(:prefix)
          prefix_info(node.prefix, node.atomic)
        elsif node.respond_to?(:suffix)
          suffix_info(node.suffix, node.atomic)
        elsif node.respond_to?(:atomic)
          expression_info(node.atomic)
        else
          ExpressionInfo.new(:unknown, :unknown)
        end
      end

      def terminal_info(node)
        # An empty string terminal always matches without consuming input.
        if eval(node.string).empty?
          ExpressionInfo.new(true, false)
        else
          ExpressionInfo.new(false, true)
        end
      end

      def nonterminal_info(name)
        if @rule_map.key?(name)
          ExpressionInfo.new(@nullable[name], @can_fail[name], { name => DEFINITE })
        else
          # Defined in an included grammar or module (or 'super'):
          # nothing can be proven about it.
          ExpressionInfo.new(:unknown, :unknown)
        end
      end

      def prefix_info(prefix, atomic)
        inner = expression_info(atomic)
        case prefix
        when AndPredicate
          # &e succeeds (without consuming) exactly when e succeeds.
          ExpressionInfo.new(inner.nullable, inner.can_fail, inner.calls)
        when NotPredicate
          # !e succeeds (without consuming) exactly when e fails, which
          # generally depends on the input.
          ExpressionInfo.new(:unknown, :unknown, inner.calls)
        else
          # TransientPrefix (~) behaves like the expression itself.
          inner
        end
      end

      def suffix_info(suffix, atomic)
        inner = expression_info(atomic)
        case suffix
        when Optional
          ExpressionInfo.new(true, false, inner.calls)
        when ZeroOrMore
          check_repetition(inner)
          ExpressionInfo.new(true, false, inner.calls)
        when OneOrMore
          check_repetition(inner)
          ExpressionInfo.new(inner.nullable, inner.can_fail, inner.calls)
        when OccurrenceRange
          check_repetition(inner) if suffix.max.text_value.empty?
          if suffix.min.text_value.to_i.zero?
            ExpressionInfo.new(true, false, inner.calls)
          else
            ExpressionInfo.new(inner.nullable, inner.can_fail, inner.calls)
          end
        else
          inner
        end
      end

      def check_repetition(inner)
        return unless @reporting
        return if inner.nullable == false
        if inner.nullable == true
          add_problem(DEFINITE,
            "rule '#{@current_rule.name}' repeats an expression that can " +
            "succeed without consuming input, so it will loop forever")
        else
          add_problem(POSSIBLE,
            "rule '#{@current_rule.name}' repeats an expression whose " +
            "nullability cannot be determined statically (it involves a " +
            "semantic predicate), so it may loop forever")
        end
      end

      def sequence_info(elements)
        nullable = true
        can_fail = false
        calls = {}
        elements.each do |element|
          info = expression_info(element)
          # An element sits at the left edge only if everything before
          # it can match without consuming input.
          merge_calls(calls, info.calls, nullable) unless nullable == false
          nullable = tri_and(nullable, info.nullable)
          can_fail = tri_or(can_fail, info.can_fail)
        end
        ExpressionInfo.new(nullable, can_fail, calls)
      end

      def choice_info(alternatives)
        nullable = false
        can_fail = true
        reachable = true
        calls = {}
        alternatives.each do |alternative|
          info = expression_info(alternative)
          # Ordered choice: an alternative is only reached if every
          # preceding alternative can fail.
          unless reachable == false
            merge_calls(calls, info.calls, reachable)
            nullable = tri_or(nullable, tri_and(reachable, info.nullable))
          end
          can_fail = tri_and(can_fail, info.can_fail)
          reachable = tri_and(reachable, info.can_fail)
        end
        ExpressionInfo.new(nullable, can_fail, calls)
      end

      def merge_calls(target, source, position_nullable)
        source.each do |name, certainty|
          certainty = POSSIBLE if certainty == POSSIBLE || position_nullable != true
          if certainty == DEFINITE
            target[name] = DEFINITE
          else
            target[name] ||= POSSIBLE
          end
        end
      end

      def detect_cycles
        @left_calls.each_key do |start|
          find_cycles_from(start, start, [start], DEFINITE)
        end
      end

      def find_cycles_from(start, current, path, certainty)
        @left_calls[current].each do |next_rule, edge_certainty|
          cycle_certainty = (certainty == DEFINITE && edge_certainty == DEFINITE) ? DEFINITE : POSSIBLE
          if next_rule == start
            record_cycle(path, cycle_certainty)
          elsif !path.include?(next_rule)
            find_cycles_from(start, next_rule, path + [next_rule], cycle_certainty)
          end
        end
      end

      def record_cycle(path, certainty)
        normalized = normalize_cycle(path)
        @cycles[normalized] = certainty unless @cycles[normalized] == DEFINITE
      end

      # Rotate the cycle so its lexicographically smallest rule comes
      # first, allowing the same cycle to be recognized from any start.
      def normalize_cycle(path)
        path.rotate(path.each_with_index.min_by { |name, _| name }.last)
      end

      def report_cycles
        @cycles.each do |cycle, certainty|
          chain = (cycle + [cycle.first]).join(' -> ')
          if certainty == DEFINITE
            add_problem(DEFINITE,
              "left recursion detected: rule '#{cycle.first}' can invoke " +
              "itself without consuming any input (call chain: #{chain})")
          else
            add_problem(POSSIBLE,
              "possible left recursion: static analysis cannot prove that " +
              "rule '#{cycle.first}' cannot invoke itself without consuming " +
              "input, because the chain involves lookahead or semantic " +
              "predicates (call chain: #{chain})")
          end
        end
      end

      def add_problem(certainty, message)
        return if @problems.any? { |problem| problem.message == message }
        @problems << Problem.new(certainty, message)
      end
    end
  end
end
