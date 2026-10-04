require 'treetop'
require 'treetop/sample/domain'
require 'treetop/sample/ir'
require 'treetop/sample/language'
require 'treetop/sample/analyzer'
require 'treetop/sample/shadow_proof'
require 'treetop/sample/generator'

module Treetop
  module Sample
    class << self
      # Compiles a Treetop grammar source with branch instrumentation,
      # generates short samples over +domain+ and verifies every claim by
      # running the real parser.
      #
      # Options:
      #   :domain       Domain instance or domain spec String/Array
      #   :max_depth    nonterminal unfolding budget (default 5)
      #   :max_repeat   static repetition unroll budget (default 3)
      #   :max_length   maximum generated sample length (default 6)
      #   :sample_budget cap on number of generated samples (default 500)
      def for_grammar(source, domain: nil, **options)
        domain_spec = domain
        compiler = Treetop::Compiler::GrammarCompiler.new

        previous = Treetop::Compiler.branch_coverage
        Treetop::Compiler.branch_coverage = true
        root, ruby_source = compiler.compile_to_ast_and_ruby(source)
        grammar_ir = Normaliser.from_treetop_file(root)

        parser_class = eval_parser(ruby_source, grammar_ir)
        domain_object =
          if domain_spec.is_a?(Domain)
            domain_spec
          else
            Domain.parse(domain_spec, terminal_characters(source))
          end

        Generator.run(grammar_ir: grammar_ir, parser_class: parser_class,
                      domain: domain_object, **options)
      ensure
        Treetop::Compiler.branch_coverage = previous
      end

      def for_path(path, **options)
        for_grammar(File.read(path), **options)
      end

      private

      def eval_parser(ruby_source, grammar_ir)
        # Evaluate in a fresh anonymous namespace so repeated runs do not
        # collide on top-level constant names.
        namespace = Module.new
        cleaned = ruby_source.sub(/\n?\(remove_const\(.*?\) if const_defined\?.*?\) rescue nil;.*\z/m, '')
        namespace.module_eval(cleaned)
        grammar_name = grammar_ir.module_name || top_level_grammar_name(ruby_source)
        full_name = grammar_name + '::Parser'
        full_name.split('::').reduce(namespace) do |scope, const|
          scope.const_get(const)
        end
      end

      def top_level_grammar_name(ruby_source)
        ruby_source[/\Amodule (\S+)/, 1] || raise('could not locate grammar module')
      end

      # Characters from quoted terminals are always legal grammar inputs even
      # if they are outside the configured alphabet.
      def terminal_characters(source)
        chars = []
        source.scan(/"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'/).each do |literal|
          quote = literal[0]
          raw = literal[1...-1]
          unescaped = quote == '"' ? eval(literal) : raw.gsub(/\\(?:\\|')/m) { |m| m == "\\'" ? "'" : '\\' }
          chars.concat(unescaped.each_char.to_a)
        end
        chars.uniq
      end
    end
  end
end
