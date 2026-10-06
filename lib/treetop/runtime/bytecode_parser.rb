module Treetop
  module Runtime
    # Interpreter for compiled Treetop bytecode artifacts
    # (Treetop::Compiler::BytecodeProgram). It mirrors the semantics of the
    # Ruby-code-generating backend (CompiledParser) but executes a validated
    # instruction sequence instead of evaluated Ruby source, so it can run in
    # environments where dynamic eval is not permitted.
    class BytecodeParser < CompiledParser
      class << self
        attr_accessor :bytecode_program, :constant_scopes

        def constant_cache
          @constant_cache ||= {}
        end
      end

      # Executes one grammar rule, with the same memoization scheme as the
      # compiled backend: results are cached per rule and start index.
      def execute_rule(rule_index)
        rule = self.class.bytecode_program.rules[rule_index]
        cache = node_cache[rule['name'].to_sym]
        start_index = index
        if cache.has_key?(index)
          cached = cache[index]
          if cached
            cached = cache[index] = SyntaxNode.new(input, index...(index + 1)) if cached == true
            @index = cached.interval.end
          end
          return cached
        end
        result = run_code(rule['code'])
        cache[start_index] = result
        result
      end

      def execute_rule_by_name(name)
        rule_index = self.class.bytecode_program.rule_index(name)
        if rule_index
          execute_rule(rule_index)
        else
          # Rules provided by included grammar modules (compiled by another
          # backend) are invoked through their generated methods.
          send("_nt_#{name}")
        end
      end

      def resolve_constant(constant_name)
        cache = self.class.constant_cache
        cached = cache[constant_name]
        return cached if cached
        cache[constant_name] = self.class.bytecode_program.resolve_constant(constant_name, self.class.constant_scopes)
      end

      protected

      def run_code(code)
        program = self.class.bytecode_program
        constants = program.constants
        values = []
        marks = []
        accumulators = []
        pc = 0
        size = code.size
        while pc < size
          instr = code[pc]
          case instr[0]
          when :mark
            marks.push(@index)
          when :unmark
            marks.pop
          when :reset
            @index = marks.pop
          when :acc_push
            accumulators.push([])
          when :acc_pop
            accumulators.pop
          when :acc_append
            accumulators.last.push(values.pop)
          when :jmp_unless_acc_last
            unless accumulators.last.last
              pc = instr[1]
              next
            end
          when :acc_size_jmp_lt
            if accumulators.last.size < instr[1]
              pc = instr[2]
              next
            end
          when :acc_size_jmp_eq
            if accumulators.last.size == instr[1]
              pc = instr[2]
              next
            end
          when :acc_size_jmp_ge
            if accumulators.last.size >= instr[1]
              pc = instr[2]
              next
            end
          when :build_seq_node
            start = marks.pop
            values.push(build_node(instr[1], instr[2], start, @index, accumulators.pop))
          when :pop_terminal_failure
            @terminal_failures.pop
          when :dup
            values.push(values.last)
          when :pop
            values.pop
          when :push_nil
            values.push(nil)
          when :epsilon
            values.push(instantiate_node(SyntaxNode, input, @index...@index))
          when :jmp
            pc = instr[1]
            next
          when :jmp_if_false
            unless values.pop
              pc = instr[1]
              next
            end
          when :match_str
            str = constants[instr[1]]
            if (match_len = has_terminal?(str, false, @index))
              values.push(build_node(instr[3], instr[4], @index, @index + match_len))
              @index += match_len
            else
              terminal_parse_failure(constants[instr[2]])
              values.push(nil)
            end
          when :match_insens
            str = constants[instr[1]]
            if (match_len = has_terminal?(str, :insens, @index))
              values.push(build_node(instr[3], instr[4], @index, @index + match_len))
              @index += match_len
            else
              terminal_parse_failure(constants[instr[2]])
              values.push(nil)
            end
          when :match_regexp
            regexp = @regexps[instr[1]] ||= Regexp.new(constants[instr[1]], instr[2])
            if (match_len = has_terminal?(regexp, :regexp, @index))
              values.push(build_node(instr[4], instr[5], @index, @index + match_len))
              @index += match_len
            else
              terminal_parse_failure(constants[instr[3]])
              values.push(nil)
            end
          when :match_char_class
            regexp = @regexps[instr[1]] ||= Regexp.new(constants[instr[1]])
            if has_terminal?(regexp, :regexp, @index)
              values.push(build_node(instr[3], instr[4], @index, @index + 1))
              @index += 1
            else
              terminal_parse_failure(constants[instr[2]])
              values.push(nil)
            end
          when :match_any
            if @index < input_length
              values.push(build_node(instr[2], instr[3], @index, @index + 1))
              @index += 1
            else
              terminal_parse_failure(constants[instr[1]])
              values.push(nil)
            end
          when :call
            result = execute_rule_by_name(constants[instr[1]])
            result = result.extend(resolve_constant(constants[instr[2]])) if result && instr[2]
            values.push(result)
          when :extend_result
            values[-1] = values.last.extend(resolve_constant(constants[instr[1]]))
          when :record_unexpected_failure
            terminal_parse_failure(constants[instr[1]], true)
          else
            raise "unknown Treetop bytecode opcode #{instr[0].inspect}"
          end
          pc += 1
        end
        values.pop
      end

      def build_node(class_const_index, module_indices, start_index, end_index, elements = nil)
        program = self.class.bytecode_program
        node_type = class_const_index ? resolve_constant(program.constants[class_const_index]) : SyntaxNode
        node =
          if elements
            instantiate_node(node_type, input, start_index...end_index, elements)
          else
            instantiate_node(node_type, input, start_index...end_index)
          end
        module_indices.each { |mod_index| node.extend(program.module_object(mod_index)) }
        node
      end
    end
  end
end
