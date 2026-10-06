module Treetop
  module Runtime
    # A parser that interprets a bytecode artifact produced by
    # Treetop::Compiler::BytecodeCompiler, instead of running generated
    # Ruby source. Parsing semantics (memoization, terminal failure
    # tracking, lazy node instantiation) mirror CompiledParser output.
    class InterpretedParser < CompiledParser
      class << self
        # { :root => Symbol,
        #   :rules => { Symbol => { :code => Array, :slots => Integer } },
        #   :constants => Array, :accessors => Array }
        attr_accessor :bytecode_program
      end

      def root
        @root ||= self.class.bytecode_program[:root]
      end

      protected

      def execute_rule(rule_name)
        program = self.class.bytecode_program
        code = program[:rules][rule_name][:code]
        constants = program[:constants]
        accessors = program[:accessors]
        slots = []
        current = nil
        test = 0
        ip = 0
        size = code.size
        while ip < size
          instruction = code[ip]
          case instruction[0]
          when :save_index
            slots[instruction[1]] = @index
          when :restore_index
            @index = slots[instruction[1]]
          when :new_acc
            slots[instruction[1]] = []
          when :accumulate
            slots[instruction[1]] << current
          when :acc_size
            test = slots[instruction[1]].size
          when :jump
            ip = instruction[1]
            next
          when :jump_if
            if current
              ip = instruction[1]
              next
            end
          when :jump_unless
            unless current
              ip = instruction[1]
              next
            end
          when :jump_if_test_eq
            if test == instruction[1]
              ip = instruction[2]
              next
            end
          when :jump_if_test_lt
            if test < instruction[1]
              ip = instruction[2]
              next
            end
          when :pop_failure
            @terminal_failures.pop
          when :record_failure
            terminal_parse_failure(instruction[1], instruction[2])
          when :match_string
            current = interpret_match_string(instruction, constants)
          when :match_regexp
            current = interpret_match_regexp(instruction, constants)
          when :match_any
            current = interpret_match_any(instruction, constants)
          when :call
            current = send("_nt_" + instruction[1].to_s)
          when :extend_result
            current = current.extend(constants[instruction[1]])
          when :materialize_lazy
            current = SyntaxNode.new(input, (@index - 1)...@index) if current == true
          when :make_node
            current = instantiate_node(node_class_for(constants, instruction[3]),
                                       input, slots[instruction[1]]...@index, slots[instruction[2]])
            current = current.extend(accessors[instruction[4]]) if instruction[4]
          when :make_epsilon
            current = instantiate_node(SyntaxNode, input, @index...@index)
          when :set_nil
            current = nil
          when :cache_lookup
            cache = node_cache[instruction[1]]
            if cache.has_key?(@index)
              cached = cache[@index]
              if cached
                if cached == true
                  cached = SyntaxNode.new(input, @index...(@index + 1))
                  cache[@index] = cached
                end
                @index = cached.interval.end
              end
              current = cached
              ip = instruction[2]
              next
            end
          when :cache_store
            node_cache[instruction[1]][slots[instruction[2]]] = current
          when :return
            return current
          else
            raise "Unknown bytecode instruction #{instruction[0].inspect}"
          end
          ip += 1
        end
        current
      end

      private

      def node_class_for(constants, class_ref)
        class_ref ? constants[class_ref] : SyntaxNode
      end

      def interpret_match_string(instruction, constants)
        _, string, mode, expected, lazy, class_ref = instruction
        if (match_length = has_terminal?(string, mode, @index))
          @index += match_length
          if lazy
            true
          else
            instantiate_node(node_class_for(constants, class_ref),
                             input, (@index - match_length)...@index)
          end
        else
          terminal_parse_failure(expected)
          nil
        end
      end

      def interpret_match_regexp(instruction, constants)
        _, source, options, expected, lazy, class_ref = instruction
        regexp = (@regexps[[source, options]] ||= Regexp.new(source, options))
        if (match_length = has_terminal?(regexp, :regexp, @index))
          @index += match_length
          if lazy
            true
          else
            instantiate_node(node_class_for(constants, class_ref),
                             input, (@index - match_length)...@index)
          end
        else
          terminal_parse_failure(expected)
          nil
        end
      end

      def interpret_match_any(instruction, constants)
        _, lazy, class_ref = instruction
        if @index < @input_length
          @index += 1
          if lazy
            true
          else
            instantiate_node(node_class_for(constants, class_ref),
                             input, (@index - 1)...@index)
          end
        else
          terminal_parse_failure("any character")
          nil
        end
      end
    end
  end
end
