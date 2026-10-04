require 'spec_helper'
require 'treetop/sample/sample_generator'

module SampleGeneratorSpec
  describe 'Treetop::Sample sample generation' do
    def generate(source, domain = 'a,b,c', options = {})
      Treetop::Sample.for_grammar(source, domain: domain, **options)
    end

    def statuses(report, branch_id = 'start@0')
      report.branches.select { |b| b.branch_id == branch_id }
             .map(&:status)
    end

    def grammar(body)
      <<~G
        grammar SampleUnderTest
        rule start
          #{body}
        end
        end
      G
    end

    describe 'ordered-choice reachability (PEG semantics)' do
      it 'marks a prefix-grabbing earlier branch as covered and proves the later one unreachable for a / ab' do
        source = <<~G
          grammar OrderingA
          rule start
            a / ab
          end
          rule a
            'a'
          end
          rule ab
            'a' 'b'
          end
          end
        G
        report = generate(source, 'a,b')
        statuses(report).should == [:covered, :proven_unreachable]
        report.branches[0].witness.should == 'a'
      end

      it 'covers both branches when the longer alternative is listed first (ab / a)' do
        source = <<~G
          grammar OrderingB
          rule start
            ab / a
          end
          rule a
            'a'
          end
          rule ab
            'a' 'b'
          end
          end
        G
        report = generate(source, 'a,b')
        statuses(report).should == [:covered, :covered]
        witnesses = report.branches.map(&:witness)
        witnesses.should == ['ab', 'a']
      end

      it 'proves every branch after a nullable first branch unreachable' do
        report = generate(grammar("'' / 'a' / 'b'"))
        statuses(report).should == [:covered, :proven_unreachable, :proven_unreachable]
      end

      it 'covers disjoint alternatives independently' do
        report = generate(grammar("'x' / 'y'"), 'x,y')
        statuses(report).should == [:covered, :covered]
      end

      it 'proves a literal alternative unreachable when an earlier character class already matches it' do
        report = generate(grammar("[ab] / 'a'"), 'a,b')
        statuses(report).should == [:covered, :proven_unreachable]
      end

      it 'covers both branches of a nested choice and the outer fallthrough' do
        report = generate(grammar("('a' / 'b') / 'c'"), 'a,b,c')
        outer = statuses(report, 'start@0')
        outer.should == [:covered, :covered]
        inner = report.branches.select { |b| b.branch_id != 'start@0' }
        inner.size.should == 2
        inner.map(&:status).should == [:covered, :covered]
      end

      it 'enumerates a recursive rule up to the length budget' do
        source = <<~G
          grammar RecSample
          rule start
            ('a' start) / 'b'
          end
          end
        G
        report = generate(source, 'a,b', max_length: 3)
        report.accepted_samples.map(&:input).should include('b', 'ab', 'aab')
      end
    end

    describe 'lookahead and bounded constructs' do
      it 'lets a later branch cover input rejected by an &-lookahead guard' do
        report = generate(grammar("(&'a' 'a') / 'b'"))
        statuses(report).should == [:covered, :covered]
      end

      it 'keeps an embedded Ruby semantic predicate as unknown rather than claiming unreachability' do
        source = grammar("('a' &{|c| true}) / 'a'")
        report = generate(source)
        report.branches[0].status.should == :covered
        report.branches[1].status.should == :unknown
      end

      it 'distinguishes a budget miss from a proof of unreachability' do
        report = generate(grammar("'z' / 'abcde'"), 'a,b,c,d,e,z', max_length: 2)
        report.branches[0].status.should == :covered
        report.branches[1].status.should == :not_found
        report.budget_exhausted.should == false
      end
    end

    describe 'runtime verification' do
      it 'only records coverage that the instrumented parser actually exhibits' do
        source = <<~G
          grammar RuntimeCheck
          rule start
            a / ab
          end
          rule a
            'a'
          end
          rule ab
            'a' 'b'
          end
          end
        G
        report = generate(source, 'a,b')
        # Every reported witness really routes through its branch when parsed.
        report.branches.each do |branch|
          next unless branch.status == :covered
          matching = report.samples.find do |sample|
            sample.accepted && sample.input == branch.witness &&
              sample.branches.include?([branch.branch_id, branch.alternative_index])
          end
          matching.should_not be_nil
        end
      end

      it 'does not mark a branch covered when a candidate fails to parse' do
        report = generate(grammar("'a' / 'b'"), 'a,b')
        report.accepted_samples.all?(&:accepted).should == true
        all_inputs = report.samples.map(&:input)
        # Candidate that cannot parse is never accepted and never a witness.
        all_inputs.should_not include('ab')
      end

      it 'does not credit a branch hit only inside a speculative, later-abandoned alternative' do
        source = <<~G
          grammar SpeculativeCheck
          rule start
            (inner 'q') / 'x'
          end
          rule inner
            'x' / 'y'
          end
          end
        G
        report = generate(source, 'x,y,q', max_length: 2)
        # "x" succeeds only through the outer fallthrough; inner's first branch
        # was tried speculatively but its enclosing alternative failed.
        x_sample = report.samples.find { |s| s.input == 'x' }
        x_sample.accepted.should == true
        x_sample.branches.should == Set.new([['start@0', 1]])
        inner_first = report.branches.find do |b|
          b.branch_id == 'inner@0' && b.alternative_index == 0
        end
        inner_first.witness.should == 'xq'
      end
    end

    describe 'branch instrumentation' do
      it 'records which alternative succeeds at runtime, respecting ordered choice' do
        source = <<~G
          grammar InstrumentCheck
          rule start
            a / ab
          end
          rule a
            'a'
          end
          rule ab
            'a' 'b'
          end
          end
        G
        Treetop::Compiler.branch_coverage = true
        begin
          root, ruby_source = Treetop::Compiler::GrammarCompiler.new.compile_to_ast_and_ruby(source)
          ns = Module.new
          ns.module_eval(ruby_source.sub(/\n?\(remove_const\(.*?\) rescue nil;.*\z/m, ''))
          parser = ns::InstrumentCheck::Parser.new
          result, recorder = Treetop::Runtime.recording_branches { parser.parse('a') }
          result.should_not be_nil
          recorder.hits.keys.should == [['start@0', 0]]

          # A parse that fails after a speculative hit does not commit it.
          failing = ns::InstrumentCheck::Parser.new
          failed_result, failed_recorder =
            Treetop::Runtime.recording_branches { failing.parse('ab') }
          failed_result.should be_nil
          failed_recorder.hits.should be_empty
        ensure
          Treetop::Compiler.branch_coverage = false
        end
      end
    end
  end
end
