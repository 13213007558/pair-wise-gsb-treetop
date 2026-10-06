module Treetop
  module Compiler
    # A compiled, serializable bytecode artifact produced by BytecodeCompiler.
    #
    # The artifact is a plain data structure (no Ruby source), so it can be
    # loaded in environments where dynamically evaluating Ruby is not allowed.
    # It carries a format version and is validated on load: every jump target
    # must land inside its rule's instruction sequence and every constant or
    # module reference must point inside the corresponding table.
    class BytecodeProgram
      FORMAT = 'treetop-bytecode'.freeze
      VERSION = 1

      class InvalidArtifactError < StandardError; end

      # Operand kinds used for load-time validation, per opcode.
      OPERANDS = {
        :mark                      => [],
        :unmark                    => [],
        :reset                     => [],
        :acc_push                  => [],
        :acc_pop                   => [],
        :acc_append                => [],
        :build_seq_node            => [:const_or_nil, :modlist],
        :pop_terminal_failure      => [],
        :dup                       => [],
        :pop                       => [],
        :push_nil                  => [],
        :epsilon                   => [],
        :jmp                       => [:jump],
        :jmp_if_false              => [:jump],
        :jmp_unless_acc_last       => [:jump],
        :acc_size_jmp_lt           => [:int, :jump],
        :acc_size_jmp_eq           => [:int, :jump],
        :acc_size_jmp_ge           => [:int, :jump],
        :match_str                 => [:const, :const, :const_or_nil, :modlist],
        :match_insens              => [:const, :const, :const_or_nil, :modlist],
        :match_regexp              => [:const, :int, :const, :const_or_nil, :modlist],
        :match_char_class          => [:const, :const, :const_or_nil, :modlist],
        :match_any                 => [:const, :const_or_nil, :modlist],
        :call                      => [:const, :const_or_nil],
        :extend_result             => [:const],
        :record_unexpected_failure => [:const]
      }.freeze

      attr_reader :grammar_name, :root_name, :constants, :modules, :includes, :rules
      attr_reader :namespace

      def initialize(data)
        validate!(data)
        @data = data
        @grammar_name = data['grammar']
        @namespace = data['namespace']
        @root_name = data['root']
        @constants = data['constants']
        @modules = data['modules']
        @includes = data['includes']
        @rules = data['rules']
        @rule_indices = {}
        @rules.each_with_index { |rule, i| @rule_indices[rule['name']] = i }
        @module_objects = nil
      end

      def parser_name
        (namespace.map { |entry| entry['name'] } + ["#{grammar_name}Parser"]).join('::')
      end

      def rule_index(name)
        @rule_indices[name]
      end

      def module_object(index)
        @module_objects[index]
      end

      def to_h
        @data
      end

      def dump
        Marshal.dump(@data)
      end

      def self.load(blob)
        new(Marshal.load(blob))
      rescue InvalidArtifactError
        raise
      rescue StandardError => e
        raise InvalidArtifactError, "invalid Treetop bytecode artifact: #{e.message}"
      end

      # Builds a parser class for this program without evaluating any Ruby
      # source. Label accessor modules are created with define_method and node
      # classes are resolved by constant name only.
      def build_parser
        scope = Object
        scopes = []
        namespace.each do |entry|
          entry['name'].split('::').each do |const_name|
            scope = fetch_or_define(scope, const_name, entry['kind'])
            scopes << scope
          end
        end
        grammar_module = fetch_or_define(scope, grammar_name, 'module')
        grammar_module.send(:include, Treetop::Runtime) unless grammar_module.include?(Treetop::Runtime)

        module_objects = modules.map do |entry|
          mod = Module.new
          entry['accessors'].each do |method_name, element_index|
            mod.send(:define_method, method_name) { elements[element_index] }
          end
          mod
        end
        modules.each_with_index do |entry, i|
          grammar_module.send(:remove_const, entry['name']) if grammar_module.const_defined?(entry['name'], false)
          grammar_module.const_set(entry['name'], module_objects[i])
        end

        parser_class = Class.new(Treetop::Runtime::BytecodeParser)
        parser_class.bytecode_program = self
        parser_class.constant_scopes = [grammar_module] + scopes + [Object]

        includes.each do |include_name|
          parser_class.send(:include, resolve_constant(include_name, parser_class.constant_scopes))
        end

        rules.each_with_index do |rule, i|
          parser_class.send(:define_method, "_nt_#{rule['name']}") { execute_rule(i) }
        end
        if root_name
          parser_class.send(:define_method, :root) { @root ||= self.class.bytecode_program.root_name.to_sym }
        end

        grammar_module.send(:remove_const, :Parser) if grammar_module.const_defined?(:Parser, false)
        grammar_module.const_set(:Parser, parser_class)
        assign_parser_constant(parser_class)

        @module_objects = module_objects
        parser_class
      end

      def resolve_constant(name, scopes)
        scopes.each do |scope|
          begin
            return scope.const_get(name, true)
          rescue NameError
          end
        end
        raise NameError, "Treetop bytecode backend cannot resolve constant #{name.inspect}"
      end

      private

      def fetch_or_define(scope, const_name, kind)
        if scope.const_defined?(const_name, false)
          scope.const_get(const_name, false)
        else
          scope.const_set(const_name, kind == 'class' ? Class.new : Module.new)
        end
      end

      def assign_parser_constant(parser_class)
        parts = parser_name.split('::')
        scope = Object
        parts[0..-2].each { |part| scope = scope.const_get(part) }
        leaf = parts[-1]
        scope.send(:remove_const, leaf) if scope.const_defined?(leaf, false)
        scope.const_set(leaf, parser_class)
      end

      def validate!(data)
        raise InvalidArtifactError, 'bytecode artifact is not a Hash' unless data.is_a?(Hash)
        unless data['format'] == FORMAT
          raise InvalidArtifactError, "unsupported bytecode format #{data['format'].inspect}"
        end
        unless data['version'] == VERSION
          raise InvalidArtifactError, "unsupported bytecode version #{data['version'].inspect} (this loader supports #{VERSION})"
        end
        unless data['grammar'].is_a?(String)
          raise InvalidArtifactError, 'bytecode artifact is missing a grammar name'
        end
        unless data['namespace'].is_a?(Array) && data['namespace'].all? { |n| n.is_a?(Hash) && n['name'].is_a?(String) && %w[module class].include?(n['kind']) }
          raise InvalidArtifactError, 'bytecode artifact has a malformed namespace'
        end
        constants = data['constants']
        unless constants.is_a?(Array) && constants.all? { |c| c.is_a?(String) }
          raise InvalidArtifactError, 'bytecode constant pool must be an Array of Strings'
        end
        modules = data['modules']
        unless modules.is_a?(Array)
          raise InvalidArtifactError, 'bytecode module table must be an Array'
        end
        modules.each do |mod|
          unless mod.is_a?(Hash) && mod['name'].is_a?(String) && mod['accessors'].is_a?(Hash) &&
                 mod['accessors'].all? { |k, v| k.is_a?(String) && v.is_a?(Integer) && v >= 0 }
            raise InvalidArtifactError, "bytecode module entry #{mod.inspect} is malformed"
          end
        end
        unless data['includes'].is_a?(Array) && data['includes'].all? { |i| i.is_a?(String) }
          raise InvalidArtifactError, 'bytecode includes must be an Array of Strings'
        end
        rules = data['rules']
        unless rules.is_a?(Array)
          raise InvalidArtifactError, 'bytecode rule table must be an Array'
        end
        names = []
        rules.each do |rule|
          unless rule.is_a?(Hash) && rule['name'].is_a?(String) && rule['code'].is_a?(Array)
            raise InvalidArtifactError, "bytecode rule #{rule.inspect} is malformed"
          end
          names << rule['name']
          validate_code!(rule, constants.size, modules.size)
        end
        unless names.uniq.size == names.size
          raise InvalidArtifactError, 'bytecode rule table contains duplicate rule names'
        end
        root = data['root']
        if rules.empty?
          unless root.nil?
            raise InvalidArtifactError, 'bytecode root must be nil when no rules are defined'
          end
        elsif !names.include?(root)
          raise InvalidArtifactError, "bytecode root #{root.inspect} is not a defined rule"
        end
      end

      def validate_code!(rule, num_constants, num_modules)
        code = rule['code']
        code.each_with_index do |instr, pc|
          unless instr.is_a?(Array)
            raise InvalidArtifactError, "rule #{rule['name']}: instruction #{pc} is not an Array"
          end
          op = instr[0]
          kinds = OPERANDS[op]
          unless kinds
            raise InvalidArtifactError, "rule #{rule['name']}: unknown opcode #{op.inspect} at instruction #{pc}"
          end
          operands = instr[1..-1]
          unless operands.size == kinds.size
            raise InvalidArtifactError, "rule #{rule['name']}: #{op} at instruction #{pc} has #{operands.size} operands, expected #{kinds.size}"
          end
          kinds.zip(operands).each do |kind, value|
            validate_operand!(rule['name'], pc, op, kind, value, num_constants, num_modules, code.size)
          end
        end
      end

      def validate_operand!(rule_name, pc, op, kind, value, num_constants, num_modules, code_size)
        valid =
          case kind
          when :const
            value.is_a?(Integer) && value >= 0 && value < num_constants
          when :const_or_nil
            value.nil? || (value.is_a?(Integer) && value >= 0 && value < num_constants)
          when :modlist
            value.is_a?(Array) && value.all? { |m| m.is_a?(Integer) && m >= 0 && m < num_modules }
          when :jump
            value.is_a?(Integer) && value >= 0 && value <= code_size
          when :int
            value.is_a?(Integer) && value >= 0
          else
            false
          end
        unless valid
          raise InvalidArtifactError, "rule #{rule_name}: #{op} at instruction #{pc} has invalid #{kind} operand #{value.inspect}"
        end
      end
    end
  end
end
