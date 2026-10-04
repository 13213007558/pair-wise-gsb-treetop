module Treetop
  module Runtime
    # Recorder for ordered-choice branches actually taken by a running
    # parser. Grammars compiled with Treetop::Compiler.branch_coverage? == true
    # emit calls to branch_covered! whenever an alternative succeeds.
    class BranchRecorder
      attr_reader :hits

      def initialize
        @hits = Hash.new(0)
        @staged = Hash.new(0)
      end

      def record!(choice_id, alternative_index)
        @staged[[choice_id, alternative_index]] += 1
      end

      # Ordered-choice scope. compile_alternatives brackets each alternative
      # with begin_choice!/rollback or commit, so hits recorded inside an
      # alternative that later fails are discarded even when an outer parse
      # ultimately succeeds via a later alternative.
      def begin_choice!
        @staged ||= Hash.new(0)
        @choice_stack ||= []
        @choice_stack.push(@staged)
        @staged = Hash.new(0)
        nil
      end

      def commit_choice!
        frame = @choice_stack.pop
        @staged.each { |key, count| frame[key] += count }
        @staged = frame
        nil
      end

      def rollback_choice!
        @staged = @choice_stack.pop
        nil
      end

      def reset_parse!
        @staged = Hash.new(0)
        @choice_stack = []
      end

      def commit_parse!
        @staged.each { |key, count| @hits[key] += count }
        @staged = Hash.new(0)
      end

      def covered?(choice_id, alternative_index)
        @hits.key?([choice_id, alternative_index])
      end

      def merge!(other)
        other.hits.each do |key, count|
          @hits[key] += count
        end
        self
      end
    end

    def self.branch_covered!(choice_id, alternative_index)
      recorder = Thread.current[:treetop_branch_recorder]
      recorder.record!(choice_id, alternative_index) if recorder
      true
    end

    def self.branch_begin_choice!
      recorder = Thread.current[:treetop_branch_recorder]
      recorder.begin_choice! if recorder
      nil
    end

    def self.branch_commit_choice!
      recorder = Thread.current[:treetop_branch_recorder]
      recorder.commit_choice! if recorder
      nil
    end

    def self.branch_rollback_choice!
      recorder = Thread.current[:treetop_branch_recorder]
      recorder.rollback_choice! if recorder
      nil
    end

    # Runs the block with a fresh recorder and returns [block_result, recorder].
    def self.recording_branches
      previous = Thread.current[:treetop_branch_recorder]
      recorder = BranchRecorder.new
      Thread.current[:treetop_branch_recorder] = recorder
      begin
        result = yield
      ensure
        Thread.current[:treetop_branch_recorder] = previous
      end
      [result, recorder]
    end
  end
end
