require 'json'
require 'set'
require 'treetop/compiler'

module Treetop
  class SampleGenerator
    Sample = Struct.new(:input, :branch_ids, keyword_init: true)
    Branch = Struct.new(
      :id, :rule, :index, :source, :semantic, :status, :sample_input, keyword_init: true
    )
    Result = Struct.new(:samples, :branches, :search_count, :search_space_exhausted, keyword_init: true)

    def self.load_grammar(path)
      File.read(path)
    end

    def self.generate(grammar_source, alphabet, root: nil, max_length: 4,
                      search_budget: 1_000)
      new(
        grammar_source,
        alphabet,
        root: root,
        max_length: max_length,
        search_budget: search_budget
      ).generate
    end

    def initialize(grammar_source, alphabet, root:, max_length:, search_budget:)
      @grammar_source = grammar_source
      @alphabet = alphabet.chars.uniq
      @root_override = root
      @max_length = max_length
      @search_budget = search_budget
      @rules = {}
      @choices_by_id = {}
      @search_count = 0
      @candidate_count = 0
      @search_space_exhausted = true
    end

    def generate
      grammar_node = parse_grammar
      parser_class = compile_parser(grammar_node)
      collect_rules(grammar_node)
      branches = collect_branches(grammar_node)

      covered = {}
      samples = []
      each_candidate do |candidate|
        if branches.any? && covered.size == branches.size
          @search_space_exhausted = false
          break
        end

        branch_ids = parse_coverage(parser_class, candidate)
        next if branch_ids.empty?
        next unless branch_ids.any? { |branch_id| !covered.key?(branch_id) }

        branch_ids.each { |branch_id| covered[branch_id] ||= candidate }
        samples << Sample.new(input: candidate, branch_ids: branch_ids)
      end

      classify(branches, covered)
      Result.new(
        samples: samples,
        branches: branches,
        search_count: @search_count,
        search_space_exhausted: @search_space_exhausted
      )
    end

    private

    def parse_grammar
      parser = Treetop::Compiler::MetagrammarParser.new
      node = parser.parse(@grammar_source)
      raise parser.failure_reason || 'Invalid Treetop grammar' unless node

      grammar = node.respond_to?(:module_or_grammar) ? node.module_or_grammar : node
      grammar = grammar.elements.find { |element| element.is_a?(Treetop::Compiler::Grammar) } unless
        grammar.is_a?(Treetop::Compiler::Grammar)
      grammar
    end

    def compile_parser(grammar_node)
      namespace = Module.new
      namespace.module_eval(grammar_node.compile)
      grammar_node.parser_name.split('::').reduce(namespace) do |namespace_part, name|
        namespace_part.const_get(name)
      end
    end

    def collect_rules(grammar_node)
      grammar_node.declaration_sequence.rules.each do |rule|
        @rules[rule.name.to_sym] = rule.parsing_expression
      end
      @root = @root_override || grammar_node.declaration_sequence.rules.first.name.to_sym
      raise ArgumentError, "Unknown root rule: #{@root}" unless @rules.key?(@root)
    end

    def collect_branches(grammar_node)
      branches = []
      grammar_node.declaration_sequence.rules.each do |rule|
        each_choice(rule.parsing_expression) do |choice|
          choice.alternatives.each_index do |index|
            @choices_by_id[branch_id(choice.interval.begin, index)] = choice
          end
          choice.alternatives.each_with_index do |alternative, index|
            branches << Branch.new(
              id: branch_id(choice.interval.begin, index),
              rule: rule.name.to_sym,
              index: index,
              source: compact(alternative.text_value),
              semantic: contains_semantic?(alternative),
              status: :not_found,
              sample_input: nil
            )
          end
        end
      end
      branches
    end

    def each_candidate
      seen = Set.new
      derived = derive(@rules.fetch(@root), 0)
      derived = derived.select { |value| value.length <= @max_length }
      derived = sort_candidates(derived)
      derived.concat(domain_candidates.reject { |value| derived.include?(value) })

      derived.each do |candidate|
        next unless seen.add?(candidate)
        if @candidate_count >= @search_budget
          @search_space_exhausted = false
          break
        end
        @candidate_count += 1

        yield candidate
      end
    end

    def domain_candidates
      strings = []
      (0..@max_length).each do |length|
        @alphabet.repeated_permutation(length).each do |chars|
          strings << chars.join
        end
      end
      strings
    end

    def derive(node, depth, seen_nonterminals = Set.new)
      return [] if depth > @max_length

      case node
      when Treetop::Compiler::Terminal
        terminal = terminal_value(node)
        terminal && terminal.length + depth <= @max_length ? [terminal] : []
      when Treetop::Compiler::CharacterClass
        pattern = Regexp.new("\\A#{node.characters}\\z")
        @alphabet.select { |char| pattern.match?(char) }
      when Treetop::Compiler::AnythingSymbol
        @alphabet.dup
      when Treetop::Compiler::Nonterminal
        derive_nonterminal(node, depth, seen_nonterminals)
      when Treetop::Compiler::Choice
        node.alternatives.flat_map { |alternative| derive(alternative, depth, seen_nonterminals.dup) }.uniq
      when Treetop::Compiler::Sequence
        derive_sequence(node.sequence_elements, 0, depth, seen_nonterminals)
      when Treetop::Compiler::Optional
        [''] + derive(parent_atomic(node), depth, seen_nonterminals)
      when Treetop::Compiler::ZeroOrMore
        derive_repetition(node, 0, depth, seen_nonterminals)
      when Treetop::Compiler::OneOrMore
        derive_repetition(node, 1, depth, seen_nonterminals)
      when Treetop::Compiler::OccurrenceRange
        derive_repetition(node, minimum(node), depth, seen_nonterminals)
      when Treetop::Compiler::Predicate, Treetop::Compiler::PredicateBlock
        ['']
      else
        if predicate_wrapper?(node)
          ['']
        else
          suffix = suffix_node(node)
          suffix ? derive(suffix, depth, seen_nonterminals) : derive_children(node, depth, seen_nonterminals)
        end
      end.uniq
    end

    def derive_nonterminal(node, depth, seen_nonterminals)
      name = node.text_value.to_sym
      return [] if seen_nonterminals.include?(name)
      return [] unless @rules.key?(name)

      derive(@rules.fetch(name), depth, seen_nonterminals + [name])
    end

    def derive_sequence(elements, index, depth, seen_nonterminals)
      return [''] if index >= elements.size

      derive(elements[index], depth, seen_nonterminals.dup).flat_map do |prefix|
        derive_sequence(elements, index + 1, depth + prefix.length, seen_nonterminals.dup).map do |suffix|
          prefix + suffix
        end
      end
    end

    def derive_repetition(node, minimum, depth, seen_nonterminals)
      maximum = node.is_a?(Treetop::Compiler::OccurrenceRange) ? maximum(node) : @max_length - depth
      maximum = [maximum, @max_length - depth].min
      atomic = parent_atomic(node)
      variants = minimum.zero? ? [''] : []
      current = ['']

      1.upto(maximum) do |count|
        current = current.flat_map do |prefix|
          derive(atomic, depth + prefix.length, seen_nonterminals.dup).map { |part| prefix + part }
        end.uniq
        variants.concat(current) if count >= minimum
      end
      variants
    end

    def derive_children(node, depth, seen_nonterminals)
      structural_children(node).flat_map do |child|
        derive(child, depth, seen_nonterminals.dup)
      end
    end

    def parse_coverage(parser_class, input)
      @search_count += 1
      parser = parser_class.new
      result = parser.parse(input, root: @root)
      return [] unless result

      branch_ids = []
      collect_branch_markers(result, branch_ids)
      branch_ids
    end

    def collect_branch_markers(node, branch_ids)
      markers = node.instance_variable_get(:@treetop_choice_branches)
      branch_ids.concat(markers) if markers
      return unless node.respond_to?(:elements) && node.elements

      node.elements.each { |child| collect_branch_markers(child, branch_ids) }
    end

    def classify(branches, covered)
      choices = branches.group_by { |branch| choice_key(branch.id) }
      branches.each do |branch|
        if covered.key?(branch.id)
          branch.status = :covered
          branch.sample_input = covered.fetch(branch.id)
        elsif choices.fetch(choice_key(branch.id)).first(branch.index).any? do |earlier|
                proves_unreachable?(branch, earlier)
              end
          branch.status = :unreachable
        elsif branch.semantic
          branch.status = :unknown
        else
          branch.status = :not_found
        end
      end
    end

    def proves_unreachable?(later, earlier_branch)
      later_choice = @choices_by_id.fetch(later.id)
      earlier_expression = later_choice.alternatives[earlier_branch.index]
      later_expression = later_choice.alternatives[later.index]
      return false if contains_predicate?(earlier_expression)

      earlier_min = minimum_length(earlier_expression)
      later_min = minimum_length(later_expression)
      return false if earlier_min.nil? || later_min.nil?
      return true if earlier_min.zero?
      return false if later_min < earlier_min

      prefixes = finite_prefixes(later_expression, earlier_min)
      prefixes && !prefixes.empty? && prefixes.all? { |prefix| finite_exact?(earlier_expression, prefix) }
    end

    def finite_prefixes(node, length)
      return [''] if length.zero?

      values = derive(node, 0)
      values.select { |value| value.length >= length }.map { |value| value[0, length] }.uniq
    rescue SystemStackError
      nil
    end

    def finite_exact?(node, value)
      derive(node, 0).include?(value)
    end

    def minimum_length(node, seen = Set.new)
      case node
      when Treetop::Compiler::Predicate, Treetop::Compiler::PredicateBlock
        0
      when Treetop::Compiler::Terminal
        terminal_value(node)&.length
      when Treetop::Compiler::CharacterClass, Treetop::Compiler::AnythingSymbol
        1
      when Treetop::Compiler::Nonterminal
        name = node.text_value.to_sym
        return nil if seen.include?(name) || !@rules.key?(name)

        minimum_length(@rules.fetch(name), seen + [name])
      when Treetop::Compiler::Choice
        node.alternatives.map { |alternative| minimum_length(alternative, seen.dup) }.compact.min
      when Treetop::Compiler::Sequence
        lengths = node.sequence_elements.map { |element| minimum_length(element, seen.dup) }
        lengths.all? ? lengths.sum : nil
      when Treetop::Compiler::Optional, Treetop::Compiler::ZeroOrMore
        0
      when Treetop::Compiler::OneOrMore
        minimum_length(parent_atomic(node), seen)
      when Treetop::Compiler::OccurrenceRange
        count = minimum(node)
        atomic_length = minimum_length(parent_atomic(node), seen)
        return 0 if count.zero?
        atomic_length ? count * atomic_length : nil
      else
        if predicate_wrapper?(node) || node.is_a?(Treetop::Compiler::Predicate) ||
             node.is_a?(Treetop::Compiler::PredicateBlock)
          0
        elsif suffix = suffix_node(node)
          minimum_length(suffix, seen)
        else
          structural_children(node).map { |child| minimum_length(child, seen.dup) }.compact.min
        end
      end
    end

    def terminal_value(node)
      modifiers = node.respond_to?(:modifiers) ? node.modifiers.text_value : ''
      return nil if modifiers.include?('r') || modifiers.include?('i')

      value = Kernel.eval(node.string)
      value if value.chars.all? { |char| @alphabet.include?(char) }
    rescue StandardError, ScriptError
      nil
    end

    def parent_atomic(node)
      node.parent.atomic
    end

    def minimum(node)
      node.min.text_value.empty? ? 0 : node.min.text_value.to_i
    end

    def maximum(node)
      node.max.text_value.empty? ? @max_length : node.max.text_value.to_i
    end

    def contains_predicate?(node, seen_nonterminals = Set.new)
      return true if node.is_a?(Treetop::Compiler::Predicate) ||
                      node.is_a?(Treetop::Compiler::PredicateBlock)

      semantic_children(node, seen_nonterminals).any? do |child|
        contains_predicate?(child, next_semantic_seen(node, seen_nonterminals))
      end
    end

    def contains_semantic?(node, seen_nonterminals = Set.new)
      return true if node.is_a?(Treetop::Compiler::PredicateBlock)

      semantic_children(node, seen_nonterminals).any? do |child|
        contains_semantic?(child, next_semantic_seen(node, seen_nonterminals))
      end
    end

    def next_semantic_seen(node, seen_nonterminals)
      if node.is_a?(Treetop::Compiler::Nonterminal)
        seen_nonterminals + [node.text_value.to_sym]
      else
        seen_nonterminals
      end
    end

    def semantic_children(node, seen_nonterminals = Set.new)
      children = (node.elements || []).reject(&:terminal?)
      if node.is_a?(Treetop::Compiler::Nonterminal)
        name = node.text_value.to_sym
        return children if seen_nonterminals.include?(name) || !@rules.key?(name)

        children + [@rules.fetch(name)]
      else
        children
      end
    end

    def each_choice(node, &block)
      each_node(node) do |child|
        block.call(child) if child.is_a?(Treetop::Compiler::Choice)
      end
    end

    def each_node(node)
      return unless node.respond_to?(:elements) && node.elements

      yield node
      node.elements.each { |child| each_node(child) { |descendant| yield descendant } }
    end

    def structural_children(node)
      return node.alternatives if node.is_a?(Treetop::Compiler::Choice)
      return node.sequence_elements if node.is_a?(Treetop::Compiler::Sequence)
      return [node.elements[2]] if node.is_a?(Treetop::Compiler::ParenthesizedExpression)
      return [parent_atomic(node)] if node.is_a?(Treetop::Compiler::Optional) || node.is_a?(Treetop::Compiler::Repetition)
      return [node.prefixed_expression] if node.respond_to?(:prefixed_expression)

      (node.elements || []).reject(&:terminal?)
    end

    def suffix_node(node)
      return nil unless node.respond_to?(:elements) && node.elements

      node.elements.find do |child|
        child.is_a?(Treetop::Compiler::Optional) || child.is_a?(Treetop::Compiler::Repetition)
      end
    end

    def predicate_wrapper?(node)
      return false unless node.respond_to?(:elements) && node.elements

      node.elements.any? do |child|
        child.is_a?(Treetop::Compiler::Predicate) || child.is_a?(Treetop::Compiler::PredicateBlock)
      end
    end

    def branch_id(offset, index)
      "choice:#{offset}:#{index}"
    end

    def choice_key(branch_id)
      branch_id.rpartition(':').first
    end

    def compact(source)
      source.gsub(/\s+/, ' ').strip
    end

    def sort_candidates(candidates)
      candidates.sort_by { |candidate| [candidate.length, candidate] }
    end
  end
end
