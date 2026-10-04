module Treetop
  module Sample
    # A finite prefix trie describing a bounded approximation of a PEG
    # expression's *accepted* language over the given domain.
    #
    # nullable?      -> epsilon is accepted
    # unknown?       -> the approximation is incomplete: an embedded Ruby
    #                   semantic predicate or the expansion bound was reached,
    #                   so strings beyond the trie might also be accepted
    # edges[char]   -> trie for strings starting with char
    #
    # Tries are used for two complementary jobs:
    #   * candidate extraction: concrete strings that surely succeed
    #   * shadow tests:          whether an earlier ordered alternative can
    #                            steal every string a later one accepts
    class Trie
      attr_accessor :nullable, :unknown, :edges

      def initialize(nullable: false, unknown: false, edges: nil)
        @nullable = nullable
        @unknown = unknown
        @edges = edges || {}
      end

      def self.empty
        new
      end

      def self.epsilon
        new(nullable: true)
      end

      def self.epsilon_with_unknown
        new(nullable: true, unknown: true)
      end

      def self.unknown
        new(unknown: true)
      end

      def empty?
        !@nullable && !@unknown && @edges.empty?
      end

      def clone
        self.class.new(nullable: @nullable, unknown: @unknown,
                        edges: @edges.transform_values(&:clone))
      end

      # Adds an accepted concrete string.
      def add!(string)
        node = self
        string.each_char do |char|
          node = (node.edges[char] ||= self.class.new)
        end
        node.nullable = true
        self
      end

      # Enumerate accepted strings up to max_length (with a cap).
      def strings(max_length:, limit: nil)
        result = []
        gather([], max_length, result, limit)
        result
      end

      def gather(prefix, remaining, result, limit)
        return if limit && result.size >= limit
        result << prefix.join if @nullable
        return if remaining.zero?
        @edges.sort.each do |char, child|
          break if limit && result.size >= limit
          child.gather(prefix + [char], remaining - 1, result, limit)
        end
      end

      # Every concrete accepted string this trie knows about, flattened.
      def each_string(prefix = [], &block)
        block.call(prefix.join) if @nullable
        @edges.sort.each do |char, child|
          child.each_string(prefix + [char], &block)
        end
      end

      # Union (in place).
      def union!(other)
        @nullable = true if other.nullable
        @unknown = true if other.unknown
        other.edges.each do |char, child|
          if @edges[char]
            @edges[char].union!(child)
          else
            @edges[char] = child.clone
          end
        end
        self
      end

      def union(other)
        clone.union!(other)
      end

      # Concatenation: strings u+v with u accepted by self and v by other.
      def concat(other)
        edges = @edges.transform_values { |child| child.concat(other) }
        if @nullable
          result = other.clone
          edges.each { |char, child| result.edges[char] ? result.edges[char].union!(child) : (result.edges[char] = child) }
          result
        else
          self.class.new(nullable: false, unknown: @unknown, edges: edges)
        end
      end

      # Does this trie (as a *known-complete* language) contain every string
      # accepted by other? The unknown flag on either side makes the answer
      # so the result is nil ("cannot tell").
      def contains_language?(other)
        return nil if @unknown || other.unknown
        return false if other.nullable && !@nullable
        other.edges.all? do |char, child|
          mine = @edges[char]
          mine && mine.contains_language?(child)
        end
      end

      # True if the language is known to contain at least one string.
      def inhabited?
        @nullable || !@edges.empty?
      end

      def known_empty?
        !@unknown && !@nullable && @edges.empty?
      end

      def inspect
        parts = []
        parts << 'epsilon' if @nullable
        parts << 'unknown' if @unknown
        parts.concat(@edges.keys.sort.map { |c| c.inspect })
        "Trie(#{parts.join(',')})"
      end
    end
  end
end
