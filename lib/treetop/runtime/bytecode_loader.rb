module Treetop
  module Runtime
    # Raised when a bytecode artifact is malformed, has an unsupported
    # version, or fails validation (bad jump targets, unknown opcodes,
    # unresolvable constant or rule references).
    class BytecodeLoadError < StandardError; end

    # Loads and validates artifacts produced by
    # Treetop::Compiler::BytecodeCompiler, and builds a parser class
    # (a Treetop::Runtime::InterpretedParser subclass) from them without
    # evaluating any Ruby source.
    module BytecodeLoader
      FORMAT = 'treetop-bytecode'.freeze
      FORMAT_VERSION = 1

      # opcode => instruction size (opcode included)
      INSTRUCTION_SIZES = {
        :save_index       => 2,
        :restore_index    => 2,
        :new_acc          => 2,
        :accumulate       => 2,
        :acc_size         => 2,
        :jump             => 2,
        :jump_if          => 2,
        :jump_unless      => 2,
        :jump_if_test_eq  => 3,
        :jump_if_test_lt  => 3,
        :pop_failure      => 1,
        :record_failure   => 3,
        :match_string     => 6,
        :match_regexp     => 6,
        :match_any        => 3,
        :call             => 2,
        :extend_result    => 2,
        :materialize_lazy => 1,
        :make_node        => 5,
        :make_epsilon     => 1,
        :set_nil          => 1,
        :cache_lookup     => 3,
        :cache_store      => 3,
        :return           => 1
      }.freeze

      # operand index of the jump target, per jump-like opcode
      JUMP_TARGETS = {
        :jump            => 1,
        :jump_if         => 1,
        :jump_unless     => 1,
        :jump_if_test_eq => 2,
        :jump_if_test_lt => 2,
        :cache_lookup    => 2
      }.freeze

      # operand index of frame slots, per opcode
      SLOT_OPERANDS = {
        :save_index    => [1],
        :restore_index => [1],
        :new_acc       => [1],
        :accumulate    => [1],
        :acc_size      => [1],
        :make_node     => [1, 2],
        :cache_store   => [2]
      }.freeze

      # operand index of rule name references, per opcode; these are
      # symbolized at load time so memoization keys match the Ruby backend
      RULE_REFERENCES = {
        :call         => 1,
        :cache_lookup => 1,
        :cache_store  => 1
      }.freeze

      CONSTANT_PATH = /\A[A-Z]\w*(::[A-Z]\w*)*\z/
      RULE_NAME = /\A[a-z_]\w*\z/

      class << self
        def load_file(path)
          load_artifact(Marshal.load(File.open(path, 'rb', &:read)))
        end

        def load_artifact(artifact)
          validate_artifact!(artifact)
          build_parser(artifact)
        end

        private

        def validate_artifact!(artifact)
          unless artifact.is_a?(Hash) && artifact['format'] == FORMAT
            raise BytecodeLoadError, 'not a Treetop bytecode artifact'
          end
          unless artifact['version'] == FORMAT_VERSION
            raise BytecodeLoadError,
              "bytecode format version #{artifact['version'].inspect} is not supported "               "(expected #{FORMAT_VERSION})"
          end
          rules = artifact['rules']
          unless rules.is_a?(Array) && rules.all? { |rule| rule.is_a?(Hash) }
            raise BytecodeLoadError, 'artifact has no valid rule table'
          end
          rule_names = rules.map { |rule| rule['name'] }
          unless artifact['root'].nil? || rule_names.include?(artifact['root'])
            raise BytecodeLoadError, "root rule #{artifact['root'].inspect} is not defined"
          end
          constants = artifact['constants'] || []
          accessors = artifact['accessors'] || []
          rules.each { |rule| validate_rule!(rule, rule_names, constants, accessors) }
        end

        def validate_rule!(rule, rule_names, constants, accessors)
          name = rule['name']
          code = rule['code']
          slots = rule['slots']
          unless name.is_a?(String) && name =~ RULE_NAME
            raise BytecodeLoadError, "invalid rule name #{name.inspect}"
          end
          unless code.is_a?(Array) && slots.is_a?(Integer) && slots > 0
            raise BytecodeLoadError, "rule #{name} has invalid code or slot count"
          end
          code.each_with_index do |instruction, ip|
            validate_instruction!(instruction, name, ip, code.size, slots, rule_names, constants, accessors)
          end
        end

        def validate_instruction!(instruction, rule_name, ip, code_size, slots, rule_names, constants, accessors)
          where = "rule #{rule_name}, instruction #{ip}"
          unless instruction.is_a?(Array) && instruction[0].is_a?(Symbol)
            raise BytecodeLoadError, "malformed instruction at #{where}"
          end
          opcode = instruction[0]
          size = INSTRUCTION_SIZES[opcode]
          unless size
            raise BytecodeLoadError, "unknown opcode #{opcode.inspect} at #{where}"
          end
          unless instruction.size == size
            raise BytecodeLoadError, "wrong operand count for #{opcode} at #{where}"
          end

          if (target_operand = JUMP_TARGETS[opcode])
            target = instruction[target_operand]
            unless target.is_a?(Integer) && target >= 0 && target < code_size
              raise BytecodeLoadError,
                "jump target #{target.inspect} out of range at #{where}"
            end
          end

          (SLOT_OPERANDS[opcode] || []).each do |operand|
            slot = instruction[operand]
            unless slot.is_a?(Integer) && slot >= 0 && slot < slots
              raise BytecodeLoadError,
                "slot #{slot.inspect} out of range at #{where}"
            end
          end

          case opcode
          when :call
            unless rule_names.include?(instruction[1])
              raise BytecodeLoadError,
                "call to undefined rule #{instruction[1].inspect} at #{where}"
            end
          when :extend_result
            validate_constant_ref!(instruction[1], constants, where)
          when :make_node
            validate_constant_ref!(instruction[3], constants, where) if instruction[3]
            accessor = instruction[4]
            if accessor && !(accessor.is_a?(Integer) && accessor >= 0 && accessor < accessors.size)
              raise BytecodeLoadError, "accessor #{accessor.inspect} out of range at #{where}"
            end
          when :match_string
            validate_constant_ref!(instruction[5], constants, where) if instruction[5]
            unless [false, :insens].include?(instruction[2])
              raise BytecodeLoadError, "invalid match mode at #{where}"
            end
          when :match_regexp
            validate_constant_ref!(instruction[5], constants, where) if instruction[5]
          when :match_any
            validate_constant_ref!(instruction[2], constants, where) if instruction[2]
          end
        end

        def validate_constant_ref!(ref, constants, where)
          unless ref.is_a?(Integer) && ref >= 0 && ref < constants.size
            raise BytecodeLoadError, "constant reference #{ref.inspect} out of range at #{where}"
          end
        end

        def build_parser(artifact)
          (artifact['requires'] || []).each { |feature| require feature }

          namespace = Object
          (artifact['module_path'] || []).each do |name, kind|
            namespace = fetch_or_define(namespace, name, kind)
          end
          grammar_module = fetch_or_define(namespace, artifact['grammar_name'], 'module')

          accessors = (artifact['accessors'] || []).map { |labels| build_accessor_module(labels) }
          constants = (artifact['constants'] || []).map do |name|
            resolve_constant(grammar_module, name)
          end

          rules = {}
          artifact['rules'].each do |rule|
            rules[rule['name'].to_sym] = { :code => symbolize_rule_references(rule['code']), :slots => rule['slots'] }
          end

          parser_class = Class.new(InterpretedParser)
          parser_class.bytecode_program = {
            :root      => artifact['root'] && artifact['root'].to_sym,
            :rules     => rules,
            :constants => constants,
            :accessors => accessors
          }
          rules.each_key do |rule_name|
            parser_class.send(:define_method, "_nt_" + rule_name.to_s) { execute_rule(rule_name) }
          end

          install_constant(grammar_module, :Parser, parser_class)
          parser_name = (artifact['grammar_name'] + 'Parser').to_sym
          install_constant(namespace, parser_name, parser_class)
          parser_class
        end

        def fetch_or_define(namespace, name, kind)
          if namespace.const_defined?(name, false)
            namespace.const_get(name, false)
          else
            created = (kind == 'class' ? Class.new : Module.new)
            namespace.const_set(name, created)
          end
        end

        def install_constant(namespace, name, value)
          if namespace.const_defined?(name, false)
            namespace.send(:remove_const, name)
          end
          namespace.const_set(name, value)
        end

        def symbolize_rule_references(code)
          code.map do |instruction|
            if (operand = RULE_REFERENCES[instruction[0]])
              instruction = instruction.dup
              instruction[operand] = instruction[operand].to_sym
            end
            instruction
          end
        end

        # Label accessor modules are built with define_method, so no Ruby
        # source is ever evaluated.
        def build_accessor_module(labels)
          accessor = Module.new
          labels.each do |label, element_index|
            accessor.send(:define_method, label) { elements[element_index] }
          end
          accessor
        end

        def resolve_constant(scope, name)
          unless name.is_a?(String) && name =~ CONSTANT_PATH
            raise BytecodeLoadError, "invalid constant reference #{name.inspect}"
          end
          scope.const_get(name)
        rescue NameError
          raise BytecodeLoadError, "cannot resolve constant #{name.inspect}"
        end
      end
    end
  end
end
