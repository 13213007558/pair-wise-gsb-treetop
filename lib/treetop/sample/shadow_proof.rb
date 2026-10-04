module Treetop
  module Sample
    # Decides, for each alternative of an ordered choice, whether some earlier
    # alternative provably steals every input that could select it.
    #
    # PEG ordered choice semantics: e1 / e2 / ... / en attempts e1 first; later
    # alternatives are only reached when every earlier one *fails at the same
    # position*. An earlier alternative shadows a later one when, for every
    # string the later one accepts, the earlier one also accepts some prefix
    # at that position (matching even one character is enough: PEG commits and
    # never backtracks into later alternatives). Accepting the empty string is
    # the strongest case: it shadows every following branch unconditionally.
    #
    # The proof abstains (returns unknown rather than a claim) whenever the
    # relevant languages depend on embedded Ruby predicates, which keeps the
    # "proven unreachable" verdict sound.
    class ShadowProof
      def initialize(grammar, analyzer, nullability, max_depth:, max_repeat:)
        @grammar = grammar
        @analyzer = analyzer
        @nullability = nullability
        @max_depth = max_depth
        @max_repeat = max_repeat
      end

      # Returns true iff branch +index+ of +choice+ is proven unreachable.
      def unreachable?(choice, index)
        status(choice, index) == :unreachable
      end

      def unknown?(choice, index)
        status(choice, index) == :unknown
      end

      def status(choice, index)
        @status ||= {}
        key = [choice.value[:branch_id], index]
        @status[key] ||= compute_status(choice, index)
      end

      private

      def compute_status(choice, index)
        earlier = choice.children[0...index]
        target = choice.children[index]
        target_trie = @analyzer.language_of(target)
        target_null = @nullability.nullable?(target)

        earlier.each do |alternative|
          verdict = shadow_verdict(alternative, target, target_trie, target_null)
          return :unreachable if verdict == :shadows
          return :unknown if verdict == :unknown
        end
        :reachable
      end

      # :shadows  => earlier provably commits on every string target accepts
      # :unknown  => cannot tell (Ruby predicate / truncation involved)
      # :none     => earlier does not provably shadow target
      def shadow_verdict(earlier, target, target_trie, target_null)
        earlier_null = @nullability.nullable?(earlier)
        return :shadows if earlier_null == Nullability::TRUE
        return :unknown if earlier_null == Nullability::UNKNOWN || target_null == Nullability::UNKNOWN

        earlier_trie = @analyzer.language_of(earlier)
        # An empty target has no inputs that can select the branch.
        return :shadows if target_trie.known_empty?
        # The target language must be fully known: if it may contain strings
        # beyond the approximation we cannot test all of them for shadowing.
        return :unknown if target_trie.unknown
        # No known way for the earlier branch to commit, and it is known not to
        # be nullable: it cannot shadow.
        return :none if earlier_trie.known_empty? && !earlier_trie.unknown

        # Prefix-aware shadow test: walk every string target accepts; at each
        # node check whether the earlier trie accepts there (nullable) or along
        # the path. If the walk leaves the known earlier trie while still inside
        # target strings, the earlier language *might* still cover the missing
        # continuation (its trie may be truncated) -> abstain.
        PrefixShadow.walk(target_trie, earlier_trie)
      end

      # Traverses a target trie alongside the shadowing trie.
      #
      # At any target node, target accepts the string consumed so far; earlier
      # shadows it exactly when earlier is nullable at that point. When target
      # continues via char c but earlier has no c edge:
      #   * if earlier is nullable here, it already shadows (stop descending)
      #   * otherwise the continuation is not covered by anything known, but
      #     earlier.unknown means longer strings might be covered -> unknown
      module PrefixShadow
        def self.walk(target, earlier)
          check(target, earlier)
        end

        def self.check(target, earlier)
          return :shadows if earlier.nullable
          target.edges.each do |char, target_child|
            if earlier.edges.key?(char)
              result = check(target_child, earlier.edges[char])
              return result unless result == :none
            else
              # Target accepts a continuation earlier's known trie cannot
              # reach from here. If earlier is truncated, it might still.
              return :unknown if earlier.unknown
            end
          end
          # Every target continuation was checked without a guaranteed commit
          # and none is nullable along the way: not a proof.
          :none
        end
      end
    end
  end
end
