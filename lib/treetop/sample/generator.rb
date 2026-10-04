require 'set'

module Treetop
  module Sample
    # Search status reported for every ordered-choice branch.
    #   :covered           a generated sample really selected the branch
    #   :proven_unreachable static PEG analysis proves no input can select it
    #   :unknown           embedded Ruby / unanalysable guard is involved
    #   :not_found         search budget exhausted without a witness
    Branch = Struct.new(:rule_name, :branch_id, :alternative_index, :expression,
                        :status, :witness, keyword_init: true)

    Sample = Struct.new(:input, :accepted, :branches, keyword_init: true)

    class Generator
      attr_reader :grammar, :domain, :analyzer, :parser_class, :options

      def self.run(grammar_ir:, parser_class:, domain:, **options)
        new(grammar_ir, parser_class, domain, options).run
      end

      def initialize(grammar, parser_class, domain, options)
        @grammar = grammar
        @parser_class = parser_class
        @domain = domain
        @max_depth = options.fetch(:max_depth, 5)
        @max_repeat = options.fetch(:max_repeat, 3)
        @max_length = options.fetch(:max_length, 6)
        @sample_budget = options.fetch(:sample_budget, 500)
        @analyzer = Analyzer.new(grammar, domain,
                                 max_depth: @max_depth, max_repeat: @max_repeat)
        @nullability = Nullability.new(grammar)
        @options = options
      end

      def run
        @budget_exhausted = false
        candidates = candidate_strings
        samples = evaluate(candidates)
        branches = classify_branches(samples)
        verify_consistency!(samples, branches)
        Report.new(grammar: @grammar, samples: samples, branches: branches,
                   parser_class: @parser_class,
                   candidates_tried: @candidates_tried,
                   budget_exhausted: @budget_exhausted)
      end

      private

      # Enumerate short candidate strings from the root rule trie, ordered by
      # length. The trie only proposes candidates; every candidate is verified
      # by the real parser, so nothing is claimed from the approximation alone.
      def candidate_strings
        root_expr = @grammar[@grammar.root_name].expr
        trie = @analyzer.language_of(root_expr)
        strings = []
        (0..@max_length).each do |length|
          trie.strings(max_length: length).each do |string|
            next if strings.include?(string)
            strings << string
            if strings.size >= @sample_budget
              @budget_exhausted = true
              return strings
            end
          end
        end
        # If the root trie is unknown, also sprinkle in a few systematic
        # bounded strings over the domain to explore paths the abstraction
        # could not concretise (e.g. those behind negative lookahead).
        if root_expr.contains?(:semantic) || trie.unknown
          systematic_strings.each do |string|
            break if strings.size >= @sample_budget
            strings << string unless strings.include?(string)
          end
        end
        strings
      end

      def systematic_strings
        result = []
        alphabet = @domain.characters.first([@domain.size, 4].min)
        (1..@max_length).each do |length|
          alphabet.repeated_permutation(length).each do |combo|
            result << combo.join
            return result if result.size + @sample_budget.to_i / 2 >= @sample_budget
          end
        end
        result
      end

      def evaluate(candidates)
        @candidates_tried = 0
        samples = []
        candidates.each do |input|
          @candidates_tried += 1
          parser = @parser_class.new
          result, recorder = Treetop::Runtime.recording_branches { parser.parse(input) }
          samples << Sample.new(input: input,
                               accepted: !result.nil?,
                               branches: recorder.hits.keys.to_set)
        end
        samples
      end

      def classify_branches(samples)
        result = []
        @grammar.each_choice do |rule, choice|
          choice.children.each_with_index do |alternative, index|
            status, witness, proven = initial_status(rule, choice, alternative, index, samples)
            result << Branch.new(rule_name: rule.name,
                                 branch_id: choice.value[:branch_id],
                                 alternative_index: index,
                                 expression: alternative,
                                 status: status,
                                 witness: witness)
          end
        end
        result
      end

      def initial_status(rule, choice, alternative, index, samples)
        witness = samples.find do |sample|
          sample.accepted && sample.branches.include?([choice.value[:branch_id], index])
        end
        return [:covered, witness.input, nil] if witness

        proof = ShadowProof.new(@grammar, @analyzer, @nullability,
                                max_depth: @max_depth, max_repeat: @max_repeat)
        if proof.unreachable?(choice, index)
          [:proven_unreachable, nil, true]
        elsif proof.unknown?(choice, index)
          [:unknown, nil, nil]
        else
          [:not_found, nil, nil]
        end
      end

      # Defensive cross-check: a branch is ever reported :covered with a
      # witness that the instrumented parser did not really route through that
      # branch, raise. This makes the report trustworthy by construction and
      # guards against accidental drift between static claims and execution.
      def verify_consistency!(samples, branches)
        accepted = samples.select(&:accepted)
        branches.each do |branch|
          next unless branch.status == :covered
          sample = accepted.find { |s| s.input == branch.witness }
          unless sample && sample.branches.include?([branch.branch_id, branch.alternative_index])
            raise "coverage inconsistency: #{branch.branch_id}##{branch.alternative_index} " \
                  "claimed covered by #{branch.witness.inspect} but the parser did not select it"
          end
        end
      end
    end

    class Report
      attr_reader :samples, :branches, :candidates_tried, :budget_exhausted, :grammar, :parser_class

      def initialize(grammar:, samples:, branches:, parser_class:, candidates_tried:, budget_exhausted:)
        @grammar = grammar
        @samples = samples
        @branches = branches
        @parser_class = parser_class
        @candidates_tried = candidates_tried
        @budget_exhausted = budget_exhausted
      end

      def accepted_samples
        @samples.select(&:accepted)
      end

      def by_status(status)
        @branches.select { |branch| branch.status == status }
      end

      def covered
        by_status(:covered)
      end

      def proven_unreachable
        by_status(:proven_unreachable)
      end

      def unknown
        by_status(:unknown)
      end

      def not_found
        by_status(:not_found)
      end
    end
  end
end
