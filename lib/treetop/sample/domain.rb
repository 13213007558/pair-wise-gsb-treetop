module Treetop
  module Sample
    # The input alphabet the generator may draw samples from.
    #
    # A domain is an ordered list of distinct characters. Explicit terminal
    # strings used by the grammar are always usable even when outside the
    # domain (otherwise a branch matching 'END' could never be sampled); pass
    # :include_terminals (the default) to merge them in.
    class Domain
      attr_reader :characters

      def self.parse(spec, extra_characters = [])
        chars =
          case spec
          when nil, '' then ('a'..'z').to_a + ('0'..'9').to_a
          when Array then spec.flat_map { |item| expand(item) }
          when String
            spec.split(',').flat_map { |item| expand(item.strip) }
          else
            raise ArgumentError, "unsupported domain spec: #{spec.inspect}"
          end
        chars = (chars + extra_characters).uniq
        new(chars)
      end

      def self.expand(item)
        case item
        when 'printable' then (32.chr..126.chr).to_a
        when 'lower' then ('a'..'z').to_a
        when 'upper' then ('A'..'Z').to_a
        when 'digit' then ('0'..'9').to_a
        when 'alnum' then ('a'..'z').to_a + ('A'..'Z').to_a + ('0'..'9').to_a
        when 'space' then [' ', "\t", "\n"]
        when Range then item.to_a
        else item.chars
        end
      end

      def initialize(characters)
        @characters = characters
        @set = characters.each_with_object({}) { |c, h| h[c] = true }
      end

      def include?(char)
        @set.key?(char)
      end

      # Characters of the domain matching a raw Treetop character class body.
      def matching(class_body)
        matcher = CharacterClassMatcher.new(class_body)
        @characters.select { |char| matcher.match?(char) }
      end

      # Pick one character that does not match the class body, if any.
      def not_matching(class_body)
        matcher = CharacterClassMatcher.new(class_body)
        @characters.find { |char| !matcher.match?(char) }
      end

      def any
        @characters.first
      end

      def size
        @characters.size
      end
    end

    # Evaluates the inside of a Treetop [..] character class against a single
    # character. Supports ranges, escapes and the POSIX [:class:] expressions
    # that Treetop documents. This mirrors the Ruby regexp semantics closely
    # enough for single ASCII characters from a finite domain.
    class CharacterClassMatcher
      POSIX = {
        'alnum' => ->(c) { c =~ /[[:alnum:]]/ },
        'alpha' => ->(c) { c =~ /[[:alpha:]]/ },
        'blank' => ->(c) { c =~ /[[:blank:]]/ },
        'cntrl' => ->(c) { c =~ /[[:cntrl:]]/ },
        'digit' => ->(c) { c =~ /[[:digit:]]/ },
        'graph' => ->(c) { c =~ /[[:graph:]]/ },
        'lower' => ->(c) { c =~ /[[:lower:]]/ },
        'print' => ->(c) { c =~ /[[:print:]]/ },
        'punct' => ->(c) { c =~ /[[:punct:]]/ },
        'space' => ->(c) { c =~ /[[:space:]]/ },
        'upper' => ->(c) { c =~ /[[:upper:]]/ },
        'xdigit' => ->(c) { c =~ /[[:xdigit:]]/ },
        'word' => ->(c) { c =~ /[[:word:]]/ }
      }.freeze

      def initialize(body)
        @body = body
        @negated = body.start_with?('^')
        @members = compile(@negated ? body[1..] : body)
      end

      def match?(char)
        result = @members.any? { |matcher| matcher.call(char) }
        @negated ? !result : result
      end

      private

      def compile(body)
        members = []
        pos = 0
        while pos < body.length
          if (match = body.match(/\A\[:(\^)?(#{POSIX.keys.join('|')}):\]/, pos))
            neg = !match[1].nil?
            predicate = POSIX.fetch(match[2])
            members << posix_member(predicate, neg)
            pos = match.end(0)
          else
            char, pos = read_char(body, pos)
            if body[pos] == '-' && pos + 1 < body.length && body[pos + 1] != ']'
              range_end, pos = read_char(body, pos + 1)
              members << range_member(char, range_end)
            else
              members << literal_member(char)
            end
          end
        end
        members
      end

      def read_char(body, pos)
        if body[pos] == '\\' && pos + 1 < body.length
          [unescape(body[pos..pos + 1]), pos + 2]
        else
          [body[pos], pos + 1]
        end
      end

      def literal_member(char)
        ->(c) { c == char }
      end

      def range_member(low, high)
        ->(c) { c >= low && c <= high }
      end

      def posix_member(predicate, negated)
        ->(c) { predicate.call(c) ? !negated : negated }
      end

      def unescape(two_chars)
        case two_chars
        when '\\n' then "\n"
        when '\\t' then "\t"
        when '\\r' then "\r"
        when '\\s' then ' '
        else two_chars[1]
        end
      end
    end
  end
end
