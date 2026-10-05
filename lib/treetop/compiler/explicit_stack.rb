module Treetop
  module Compiler
    # Compiles right-recursive rules (rules whose recursive calls appear only
    # in tail positions) so that parsing uses an explicit execution stack
    # instead of the Ruby call stack. This allows grammars such as
    #
    #   rule list
    #     item list / item
    #   end
    #
    # to parse inputs of unbounded length without raising SystemStackError,
    # while producing exactly the same nodes, intervals, failure positions
    # and memoization behaviour as the plain recursive compilation.
    #
    # For each eligible rule the compiler generates, next to the usual
    # _nt_<name> entry method, a _nt_<name>__step method containing the rule
    # body in which every recursive call in tail position is replaced by a
    # continuation frame push plus a state return, and one
    # _nt_<name>__cont_<n> method per such call site holding the code that
    # runs once the inner result is known (node construction, choice
    # backtracking and memo cache storage). CompiledParser#__es_drive
    # interprets these states, so the Ruby stack stays flat regardless of
    # recursion depth.
    module ExplicitStack
      # Analyzes the rules of a grammar and assigns each rule that takes part
      # in a cycle of the tail-call graph a Machine to compile itself with,
      # unless the cycle cannot be compiled with an explicit stack, in which
      # case the reason is reported and the rules compile as usual.
      def self.apply(rules)
        return if rules.empty?
        rules_by_name = {}
        rules.each { |rule| rules_by_name[rule.name] = rule }
        tail_edges = {}
        rules.each do |rule|
          tail_edges[rule.name] = tail_positions(rule.parsing_expression).map(&:text_value).uniq & rules_by_name.keys
        end
        cyclic_groups(rules.map(&:name), tail_edges).each do |group|
          problems = {}
          group.each { |name| problems[name] = eligibility_problems(rules_by_name[name], group) }
          if problems.values.all?(&:empty?)
            group.each { |name| rules_by_name[name].stack_machine = Machine.new(rules_by_name[name], group) }
          else
            warn_ineligible(group, problems)
          end
        end
      end

      # The nonterminal nodes of +expression+ that appear in tail position,
      # i.e. whose result becomes the result of the whole expression once the
      # enclosing constructs have been accounted for. Only choices, sequences
      # (last element), parenthesized expressions and transient prefixes
      # propagate tail position; anything else (repetitions, optionals,
      # predicates, earlier sequence elements) does not.
      def self.tail_positions(expression)
        case expression
        when Choice
          expression.alternatives.map { |alternative| tail_positions(alternative) }.flatten
        when Sequence
          tail_positions(expression.sequence_elements.last)
        when Nonterminal
          [expression]
        when ParenthesizedExpression
          tail_positions(expression.parsing_expression)
        else
          # See through the metagrammar's expression wrappers the way their
          # compile methods delegate to the expression they wrap.
          if expression.respond_to?(:sequence_primary)
            tail_positions(expression.sequence_primary)
          elsif expression.respond_to?(:prefixed_expression) && expression.respond_to?(:prefix)
            expression.prefix.is_a?(TransientPrefix) ? tail_positions(expression.prefixed_expression) : []
          elsif expression.respond_to?(:suffix)
            []
          elsif expression.respond_to?(:atomic)
            tail_positions(expression.atomic)
          else
            []
          end
        end
      end

      # Groups of rule names that are mutually reachable through tail calls;
      # these are the rules whose recursion can grow with the input.
      def self.cyclic_groups(names, tail_edges)
        reachable = {}
        names.each do |name|
          seen = {}
          stack = tail_edges[name].dup
          until stack.empty?
            other = stack.pop
            next if seen[other]
            seen[other] = true
            stack.concat(tail_edges[other] || [])
          end
          reachable[name] = seen
        end
        groups = []
        visited = {}
        names.each do |name|
          next if visited[name] || !reachable[name][name]
          group = names.select { |other| reachable[name][other] && reachable[other][name] }
          group.each { |member| visited[member] = true }
          groups << group
        end
        groups
      end

      # Reasons why +rule+ (a member of the recursive +group+) cannot be
      # compiled with an explicit stack. Empty when it can.
      def self.eligibility_problems(rule, group)
        problems = []
        tail_node_ids = tail_positions(rule.parsing_expression).map(&:object_id)
        each_expression_node(rule.parsing_expression) do |node|
          if node.is_a?(PredicateBlock)
            problems << "rule \`#{rule.name}\` embeds a Ruby semantic predicate block #{node.text_value.strip} " \
                        "whose closure over generated parser locals cannot be captured in an explicit stack frame"
          elsif node.is_a?(Nonterminal)
            if node.text_value == 'super'
              problems << "rule \`#{rule.name}\` uses \`super\`, which cannot be resumed from an explicit stack frame"
            elsif group.include?(node.text_value) && !tail_node_ids.include?(node.object_id)
              problems << "recursive reference \`#{node.text_value}\` in rule \`#{rule.name}\` does not appear in a tail position"
            end
          end
        end
        problems.uniq
      end

      def self.each_expression_node(node, &block)
        yield node
        elements = node.respond_to?(:elements) ? node.elements : nil
        elements.each { |element| each_expression_node(element, &block) } if elements
      end

      def self.warn_ineligible(group, problems)
        reasons = problems.values.flatten.uniq
        warn "Treetop: cannot compile right-recursive rule(s) #{group.map { |name| "\`#{name}\`" }.join(', ')} " \
             "with an explicit stack; falling back to Ruby recursion, which may raise " \
             "SystemStackError on deeply nested input:\n" + reasons.map { |reason| "  - #{reason}" }.join("\n")
      end

      # Per-rule generation state: knows which nonterminal nodes are
      # recursive calls in tail position, dispatches step-mode compilation,
      # and collects the continuation methods to generate.
      class Machine
        attr_reader :rule, :group, :conts
        attr_accessor :result_var

        def initialize(rule, group)
          @rule = rule
          @group = group
          @conts = []
          @cont_counter = 0
          @subtree_cache = {}
        end

        def step_method_name
          "_nt_#{rule.name}__step(__stack, start_index)"
        end

        def tail_call_target?(node)
          node.is_a?(Nonterminal) && tail_call_nodes.include?(node)
        end

        def tail_call_nodes
          @tail_call_nodes ||= ExplicitStack.tail_positions(rule.parsing_expression).select do |node|
            group.include?(node.text_value)
          end
        end

        def subtree_has_tail_call?(node)
          return @subtree_cache[node.object_id] if @subtree_cache.key?(node.object_id)
          @subtree_cache[node.object_id] = compute_subtree_has_tail_call(node)
        end

        # Compiles +node+ so that recursive calls in tail position push a
        # continuation frame and return a call state instead of invoking the
        # rule method. +context+ is the list of frames (outermost first) that
        # replay the enclosing constructs once the inner result is known.
        def compile_step_expression(node, address, builder, context, parent_expression)
          unless subtree_has_tail_call?(node)
            node.compile(address, builder, parent_expression)
            return
          end
          case node
          when Choice, Sequence, Nonterminal
            node.compile_step(address, builder, context, parent_expression, self)
          when ParenthesizedExpression
            compile_step_expression(node.parsing_expression, address, builder, context, parent_expression)
          else
            # See through the metagrammar's expression wrappers the way
            # their compile methods delegate to the expression they wrap.
            if node.respond_to?(:sequence_primary)
              compile_step_expression(node.sequence_primary, address, builder, context, nil)
            elsif node.respond_to?(:prefixed_expression) && node.respond_to?(:prefix) && node.prefix.is_a?(TransientPrefix)
              compile_step_expression(node.prefixed_expression, address, builder, context, nil)
            elsif node.respond_to?(:atomic) && !node.respond_to?(:suffix)
              compile_step_expression(node.atomic, address, builder, context, node)
            else
              node.compile(address, builder, parent_expression)
            end
          end
        end

        def register_cont(context, nonterminal)
          @cont_counter += 1
          frames = [CallSiteFrame.new(nonterminal)] + context.reverse
          frames << RuleFrame.new unless frames.last.is_a?(RuleFrame)
          cont = Cont.new("_nt_#{rule.name}__cont_#{@cont_counter}", frames, nonterminal.result_var)
          conts << cont
          cont
        end

        def emit_frames(frames, builder)
          frames.first.emit_after(self, builder, frames[1..-1]) unless frames.empty?
        end

        # Yields each registered continuation; more continuations may be
        # registered while generating (choice alternatives compiled into a
        # continuation can contain further tail calls).
        def each_cont
          index = 0
          while index < conts.size
            yield conts[index]
            index += 1
          end
        end

        private

        def compute_subtree_has_tail_call(node)
          return true if tail_call_target?(node)
          elements = node.respond_to?(:elements) ? node.elements : nil
          !!(elements && elements.any? { |element| subtree_has_tail_call?(element) })
        end
      end

      # A continuation method to generate: the code that runs when the result
      # of a tail call is known, up to and including memo cache storage.
      class Cont
        attr_reader :name, :frames, :result_var

        def initialize(name, frames, result_var)
          @name = name
          @frames = frames
          @result_var = result_var
        end

        def saved_vars
          @saved_vars ||= frames.map(&:saved_vars).flatten.uniq
        end

        def frame_arguments
          saved_vars.empty? ? '' : ", #{saved_vars.join(', ')}"
        end

        def method_signature
          "#{name}(__stack, __es_result#{frame_arguments})"
        end
      end

      # Stores the rule's result in the memo cache and returns it; the
      # outermost frame of every continuation.
      class RuleFrame
        def saved_vars
          ['start_index']
        end

        def emit_after(machine, builder, outer)
          machine.rule.generate_cache_storage(builder, machine.result_var)
          builder << "[:__es_value, #{machine.result_var}]"
        end
      end

      # Accumulates the result of a sequence's last element and constructs
      # the sequence's node (or resets the index on failure).
      class SequenceFrame
        attr_reader :sequence, :address, :last_element_address, :saved_vars

        def initialize(sequence, last_element_address)
          @sequence = sequence
          @address = sequence.address
          @last_element_address = last_element_address
          @saved_vars = [sequence.start_index_var, sequence.accumulator_var]
        end

        def emit_after(machine, builder, outer)
          sequence.with_compile_address(address) do
            builder.accumulate sequence.accumulator_var, "r#{last_element_address}"
            sequence.compile_result_assignment
          end
          machine.emit_frames(outer, builder)
        end
      end

      # Decides the outcome of a choice once the result of one of its
      # alternatives is known, compiling the remaining alternatives (which
      # may themselves contain tail calls) for the failure case.
      class ChoiceFrame
        attr_reader :choice, :address, :alternative_address, :remaining_alternatives, :saved_vars

        def initialize(choice, alternative_address, remaining_alternatives)
          @choice = choice
          @address = choice.address
          @alternative_address = alternative_address
          @remaining_alternatives = remaining_alternatives
          @saved_vars = [choice.start_index_var]
        end

        def emit_after(machine, builder, outer)
          choice.with_compile_address(address) do
            result_var = "r#{alternative_address}"
            builder.if__ result_var do
              choice.compile_success_assignment(result_var)
            end
            builder.else_ do
              if remaining_alternatives.empty?
                choice.reset_index
                choice.assign_failure choice.start_index_var
              else
                choice.compile_alternatives_step(remaining_alternatives, outer, machine)
              end
            end
          end
          machine.emit_frames(outer, builder)
        end
      end

      # Applies the node class and inline module extensions that the
      # recursive call site carries, before the enclosing constructs resume.
      class CallSiteFrame
        attr_reader :nonterminal, :address

        def initialize(nonterminal)
          @nonterminal = nonterminal
          @address = nonterminal.address
        end

        def saved_vars
          []
        end

        def emit_after(machine, builder, outer)
          nonterminal.with_compile_address(address) do
            nonterminal.extend_result_with_declared_module
            nonterminal.extend_result_with_inline_module nonterminal.parent_expression
          end
          machine.emit_frames(outer, builder)
        end
      end
    end
  end
end
