module Treetop
  module Compiler
    # Raised when a right-recursive grammar cannot be compiled to an
    # explicit-stack parser because of embedded Ruby code.
    class RightRecursionError < StandardError; end

    # Analyzes the parsing rules of a grammar for right-recursive structure
    # (rules whose final alternative element recurses on the rule itself or
    # on a mutually recursive set of rules) and compiles such rules to an
    # explicit-stack machine instead of nested Ruby method calls. This lets
    # parsers handle arbitrarily deep right recursion, such as very long
    # right-recursive lists, without exhausting the Ruby call stack.
    #
    # A group of mutually right-recursive rules is compiled to an iterative
    # machine when every recursive reference appears in tail position as a
    # bare nonterminal (optionally labeled or parenthesized). Right-recursive
    # rules that rely on embedded Ruby the machine cannot replay (semantic
    # predicates, or node class declarations and inline modules attached to
    # the recursive reference itself or wrapped around the whole recursive
    # expression) are reported at compile time. Recursive shapes the machine
    # cannot express (recursion under a suffix or prefix operator, nested
    # inside a parenthesized subexpression, or through +super+) fall back to
    # standard recursive compilation.
    module RightRecursion
      extend self

      RecursiveClause = Struct.new(:sequence, :prefix, :tail, :builder_id)
      IdentityClause  = Struct.new(:tail, :builder_id)
      BaseClause      = Struct.new(:alternative)

      def analyze(rules)
        plan = Plan.new
        return plan if rules.nil? || rules.empty?

        by_name = {}
        rules.each { |rule| by_name[rule.name] = rule }
        edges = {}
        rules.each do |rule|
          edges[rule.name] = tail_refs(rule.parsing_expression).uniq & by_name.keys
        end

        problems = []
        classified = []
        recursive_groups(edges, rules).each do |members|
          clauses_by_rule, embedded, structural = classify_group(members, by_name)
          problems.concat(embedded)
          classified << [members, clauses_by_rule, structural]
        end

        unless problems.empty?
          raise RightRecursionError,
                "Cannot compile right-recursive rules with the explicit-stack parser:\n" +
                problems.map { |problem| "  - #{problem}" }.join("\n")
        end

        classified.each_with_index do |(members, clauses_by_rule, structural), group_id|
          next if structural
          group = Group.new(group_id)
          members.each { |name| group.add_rule(name, clauses_by_rule[name]) }
          plan.add(group)
        end
        plan
      end

      # Names of nonterminals referenced in tail position of the given
      # expression (through choices, sequence tails, labels, primary
      # wrappers and parentheses).
      def tail_refs(expression)
        case
        when expression.is_a?(Choice)
          expression.alternatives.flat_map { |alternative| tail_refs(alternative) }
        when expression.respond_to?(:sequence_elements)
          tail_refs(expression.sequence_elements.last.sequence_primary)
        when expression.is_a?(ParenthesizedExpression)
          tail_refs(expression.elements[2])
        when expression.is_a?(Nonterminal)
          [expression.text_value]
        when expression.respond_to?(:atomic)
          tail_refs(expression.atomic)
        else
          []
        end
      end

      # Strongly connected components of the tail-call graph that contain a
      # cycle (direct or mutual recursion), in declaration order.
      def recursive_groups(edges, rules)
        order = {}
        rules.each_with_index { |rule, i| order[rule.name] = i }
        cyclic = strongly_connected_components(edges).select do |component|
          component.size > 1 || edges[component.first].include?(component.first)
        end
        cyclic.each { |component| component.sort_by! { |name| order[name] } }
        cyclic.sort_by { |component| order[component.first] }
      end

      def strongly_connected_components(edges)
        index_of = {}
        lowlink = {}
        on_stack = {}
        stack = []
        components = []
        counter = 0
        edges.each_key do |root|
          next if index_of.key?(root)
          work = [[root, 0]]
          until work.empty?
            node, child_index = work.last
            if child_index == 0
              index_of[node] = lowlink[node] = counter
              counter += 1
              stack.push(node)
              on_stack[node] = true
            end
            recursed = false
            successors = edges[node] || []
            i = child_index
            while i < successors.size
              successor = successors[i]
              if !index_of.key?(successor)
                work.last[1] = i + 1
                work.push([successor, 0])
                recursed = true
                break
              elsif on_stack[successor]
                lowlink[node] = [lowlink[node], index_of[successor]].min
              end
              i += 1
            end
            next if recursed
            if lowlink[node] == index_of[node]
              component = []
              begin
                member = stack.pop
                on_stack[member] = false
                component << member
              end until member == node
              components << component
            end
            work.pop
            unless work.empty?
              parent = work.last[0]
              lowlink[parent] = [lowlink[parent], lowlink[node]].min
            end
          end
        end
        components
      end

      # Classifies the alternatives of every rule in a recursive group into
      # recursive clauses (sequence with a bare tail call), identity clauses
      # (a bare tail call as a whole primary alternative) and base clauses.
      # Returns [clauses_by_rule, embedded_problems, structural_fallback].
      def classify_group(members, by_name)
        clauses_by_rule = {}
        embedded = []
        structural = false
        has_base = false
        members.each do |name|
          rule = by_name[name]
          expression = rule.parsing_expression
          if contains_node?(expression) { |node| node.is_a?(PredicateBlock) }
            embedded << "rule '#{name}' uses a semantic predicate (&{...} or !{...}); embedded Ruby that runs during parsing cannot be replayed by the explicit-stack parser"
          end
          if contains_node?(expression) { |node| node.is_a?(Nonterminal) && node.text_value == 'super' }
            structural = true
          end
          expression, wrapper_problem = unwrap_rule_expression(expression)
          if wrapper_problem
            embedded << "rule '#{name}' #{wrapper_problem}"
            next
          end
          alternatives = expression.is_a?(Choice) ? expression.alternatives : [expression]
          clauses = []
          alternatives.each do |alternative|
            status = alternative_tail_status(alternative, members)
            case status[0]
            when :bare
              if alternative.respond_to?(:sequence_elements)
                clauses << RecursiveClause.new(alternative, alternative.sequence_elements[0..-2], status[1])
              else
                clauses << IdentityClause.new(status[1])
              end
            when :none
              clauses << BaseClause.new(alternative)
              has_base = true
            when :decorated
              embedded << "rule '#{name}' #{status[1]}"
            when :structural
              structural = true
            end
          end
          clauses_by_rule[name] = clauses
        end
        structural = true unless has_base
        [clauses_by_rule, embedded, structural]
      end

      def alternative_tail_status(alternative, members)
        if alternative.respond_to?(:sequence_elements)
          primary_tail_status(alternative.sequence_elements.last.sequence_primary, members)
        else
          primary_tail_status(alternative, members)
        end
      end

      def primary_tail_status(node, members)
        case
        when node.is_a?(Nonterminal)
          members.include?(node.text_value) ? [:bare, node.text_value] : [:none]
        when node.is_a?(ParenthesizedExpression)
          inner = node.elements[2]
          bare = bare_nonterminal_name(inner)
          if bare && members.include?(bare)
            [:bare, bare]
          elsif (tail_refs(inner) & members).empty?
            [:none]
          else
            [:structural, 'has a recursive reference nested inside parentheses']
          end
        when node.respond_to?(:prefixed_expression)
          (tail_refs(node.atomic) & members).empty? ? [:none] : [:structural, "has a recursive reference under a '&', '!' or '~' prefix"]
        when node.respond_to?(:suffix)
          (tail_refs(node.atomic) & members).empty? ? [:none] : [:structural, "has a recursive reference under a '?', '*', '+' or '..' suffix"]
        when node.respond_to?(:atomic)
          refs = tail_refs(node.atomic) & members
          if refs.empty?
            [:none]
          elsif node.node_class_name || !node.node_class_declarations.inline_modules.empty?
            [:decorated, 'applies a node class declaration or inline module to the recursive reference']
          else
            primary_tail_status(node.atomic, members)
          end
        else
          [:none]
        end
      end

      def bare_nonterminal_name(expression)
        case
        when expression.is_a?(Nonterminal)
          expression.text_value
        when expression.is_a?(ParenthesizedExpression)
          bare_nonterminal_name(expression.elements[2])
        when undecorated_atomic_wrapper?(expression)
          bare_nonterminal_name(expression.atomic)
        end
      end

      def undecorated_atomic_wrapper?(expression)
        atomic_wrapper?(expression) &&
          expression.node_class_name.nil? &&
          expression.node_class_declarations.inline_modules.empty?
      end

      def decorated_atomic_wrapper?(expression)
        atomic_wrapper?(expression) &&
          !(expression.node_class_name.nil? && expression.node_class_declarations.inline_modules.empty?)
      end

      def atomic_wrapper?(expression)
        return false if expression.respond_to?(:sequence_elements)
        return false unless expression.respond_to?(:atomic)
        return false unless expression.respond_to?(:node_class_name)
        return false if expression.respond_to?(:suffix)
        return false if expression.respond_to?(:prefixed_expression)
        true
      end

      # Unwraps transparent parentheses and empty primary wrappers around a
      # rule's parsing expression. Returns [expression, problem].
      def unwrap_rule_expression(expression)
        loop do
          if expression.is_a?(ParenthesizedExpression)
            expression = expression.elements[2]
          elsif undecorated_atomic_wrapper?(expression)
            expression = expression.atomic
          elsif decorated_atomic_wrapper?(expression)
            return [nil, 'wraps the recursive expression in a node class declaration or inline module']
          else
            return [expression, nil]
          end
        end
      end

      def contains_node?(node, &predicate)
        return true if predicate.call(node)
        if node.respond_to?(:elements) && node.elements
          node.elements.any? { |element| element.is_a?(Runtime::SyntaxNode) && contains_node?(element, &predicate) }
        else
          false
        end
      end

      class Plan
        def initialize
          @groups_by_rule = {}
        end

        def add(group)
          group.rule_names.each { |name| @groups_by_rule[name] = group }
        end

        def [](rule_name)
          @groups_by_rule[rule_name]
        end
      end

      # A group of mutually right-recursive rules compiled to a single
      # explicit-stack machine. Each rule keeps a memoizing _nt_ wrapper;
      # the recursion itself runs iteratively in _rr_machine_<id>.
      class Group
        attr_reader :id

        def initialize(id)
          @id = id
          @clauses_by_rule = {}
          @rule_order = []
          @machine_compiled = false
        end

        def add_rule(name, clauses)
          builder_id = @clauses_by_rule.values.flatten.count { |clause| !clause.is_a?(BaseClause) }
          clauses.each do |clause|
            unless clause.is_a?(BaseClause)
              clause.builder_id = builder_id
              builder_id += 1
            end
          end
          @clauses_by_rule[name] = clauses
          @rule_order << name
        end

        def rule_names
          @rule_order
        end

        def compile_rule(rule, builder)
          compile_machine(builder) unless @machine_compiled
          @machine_compiled = true
          clauses = @clauses_by_rule[rule.name]
          builder.method_declaration("_nt_#{rule.name}") do
            builder.assign 'start_index', 'index'
            rule.generate_cache_lookup(builder)
            builder.newline
            builder.assign 'result', "_rr_machine_#{id}(:#{rule.name}, start_index)"
            rule.generate_cache_storage(builder, 'result')
            builder.newline
            builder << 'result'
          end
          clauses.each_with_index do |clause, i|
            case clause
            when RecursiveClause
              next if clause.prefix.empty?
              builder.newline
              builder.method_declaration("_rr_#{rule.name}_clause_#{i}") do
                clause.sequence.compile_tail_prefix(builder.next_address, builder, clause.prefix)
              end
            when BaseClause
              builder.newline
              builder.method_declaration("_rr_#{rule.name}_base_#{i}") do
                address = builder.next_address
                clause.alternative.compile(address, builder)
                builder << "r#{address} = SyntaxNode.new(input, (index-1)...index) if r#{address} == true"
                builder << "r#{address}"
              end
            end
          end
        end

        def compile_machine(builder)
          builder.newline
          builder.method_declaration("_rr_machine_#{id}(start_rule, start_index)") do
            builder << machine_source
          end
        end

        # The body of the explicit-stack machine. Frames on +stack+ are
        # [rule, level_start, elements, resume_clause, builder_id]; +active+
        # detects recursion that does not consume input.
        def machine_source
          lines = []
          lines << 'stack = []'
          lines << 'active = {}'
          lines << 'rule = start_rule'
          lines << 'clause = 0'
          lines << 'level_start = start_index'
          lines << 'result = nil'
          lines << 'loop do'
          lines << '  if clause == 0'
          lines << '    level_start = index'
          lines << '    if node_cache[rule].has_key?(index)'
          lines << '      cached = node_cache[rule][index]'
          lines << '      if cached'
          lines << '        node_cache[rule][index] = cached = SyntaxNode.new(input, index...(index + 1)) if cached == true'
          lines << '        @index = cached.interval.end'
          lines << '      end'
          lines << '      result = cached'
          lines << '      clause = -1'
          lines << '    else'
          lines << '      active_key = [rule, level_start]'
          lines << '      if active[active_key]'
          lines << '        raise "Right-recursive rule #{rule} re-entered at index #{level_start} without consuming input (infinite recursion)"'
          lines << '      end'
          lines << '      active[active_key] = true'
          lines << '    end'
          lines << '  end'
          lines << '  if clause >= 0'
          lines << '    progressed = false'
          lines << '    loop do'
          lines << '      case rule'
          @rule_order.each do |name|
            clauses = @clauses_by_rule[name]
            lines << "      when :#{name}"
            lines << '        case clause'
            clauses.each_with_index do |clause, i|
              lines << "        when #{i}"
              case clause
              when RecursiveClause
                if clause.prefix.empty?
                  lines << "          stack.push([:#{name}, level_start, [], #{i + 1}, #{clause.builder_id}])"
                  lines << "          rule = :#{clause.tail}"
                  lines << '          clause = 0'
                  lines << '          progressed = true'
                else
                  lines << "          if (elements = _rr_#{name}_clause_#{i})"
                  lines << "            stack.push([:#{name}, level_start, elements, #{i + 1}, #{clause.builder_id}])"
                  lines << "            rule = :#{clause.tail}"
                  lines << '            clause = 0'
                  lines << '            progressed = true'
                  lines << '          else'
                  lines << "            clause = #{i + 1}"
                  lines << '          end'
                end
              when IdentityClause
                lines << "          stack.push([:#{name}, level_start, [], #{i + 1}, #{clause.builder_id}])"
                lines << "          rule = :#{clause.tail}"
                lines << '          clause = 0'
                lines << '          progressed = true'
              when BaseClause
                lines << "          if (base = _rr_#{name}_base_#{i})"
                lines << '            result = base'
                lines << '            clause = -1'
                lines << '            progressed = true'
                lines << '          else'
                lines << "            clause = #{i + 1}"
                lines << '          end'
              end
            end
            lines << '        else'
            lines << '          break'
            lines << '        end'
          end
          lines << '      else'
          lines << '        break'
          lines << '      end'
          lines << '      break if progressed'
          lines << '    end'
          lines << '    unless progressed'
          lines << '      node_cache[rule][level_start] = nil'
          lines << '      result = nil'
          lines << '      clause = -1'
          lines << '    end'
          lines << '  end'
          lines << '  if clause < 0'
          lines << '    active.delete([rule, level_start])'
          lines << '    if result'
          lines << '      node_cache[rule][level_start] = result'
          lines << '      if stack.empty?'
          lines << '        return result'
          lines << '      end'
          lines << '      frame = stack.pop'
          lines << '      case frame[4]'
          @rule_order.each do |name|
            @clauses_by_rule[name].each do |clause|
              next if clause.is_a?(BaseClause)
              lines << "      when #{clause.builder_id}"
              case clause
              when RecursiveClause
                sequence = clause.sequence
                lines << '        frame[2] << result'
                lines << "        result = instantiate_node(#{sequence.node_class_name}, input, frame[1]...index, frame[2])"
                if (accessor = sequence.sequence_element_accessor_module_name)
                  lines << "        result.extend(#{accessor})"
                end
                if (inline_module = sequence.inline_module_name)
                  lines << "        result.extend(#{inline_module})"
                end
              when IdentityClause
                lines << '        nil'
              end
            end
          end
          lines << '      else'
          lines << '        raise "Unknown frame builder #{frame[4]}"'
          lines << '      end'
          lines << '      rule = frame[0]'
          lines << '      level_start = frame[1]'
          lines << '    else'
          lines << '      if stack.empty?'
          lines << '        @index = start_index'
          lines << '        return nil'
          lines << '      end'
          lines << '      frame = stack.pop'
          lines << '      @index = frame[1]'
          lines << '      rule = frame[0]'
          lines << '      level_start = frame[1]'
          lines << '      clause = frame[3]'
          lines << '    end'
          lines << '  end'
          lines << 'end'
          lines.join("\n")
        end
      end
    end
  end
end
