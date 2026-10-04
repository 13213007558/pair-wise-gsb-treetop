require 'spec_helper'

describe Treetop::SampleGenerator do
  def generate(grammar_source, alphabet = 'ab', options = {})
    described_class.generate(
      grammar_source,
      alphabet,
      **{ max_length: 3, search_budget: 100 }.merge(options)
    )
  end

  def grammar(source_name, body)
    <<~GRAMMAR
      grammar #{source_name}
        rule root
          #{body}
        end
      end
    GRAMMAR
  end

  def branch(result, index)
    result.branches.find { |branch| branch.index == index }
  end

  it 'marks the shadowed later alternative unreachable for a / ab' do
    result = generate(grammar('PrefixFirst', "'a' / 'ab'"), 'ab')

    result.samples.map(&:input).should eq(['a'])
    branch(result, 0).status.should eq(:covered)
    branch(result, 1).status.should eq(:unreachable)
    result.samples.flat_map(&:branch_ids).should eq([branch(result, 0).id])
  end

  it 'covers both ordered alternatives when the longer alternative comes first' do
    result = generate(grammar('PrefixSecond', "'ab' / 'a'"), 'ab')

    result.samples.map(&:input).sort.should eq(%w[a ab])
    result.branches.map(&:status).uniq.should eq([:covered])
    branch(result, 0).sample_input.should eq('ab')
    branch(result, 1).sample_input.should eq('a')
  end

  it 'supports lookahead by choosing a later branch when the lookahead fails' do
    grammar_source = <<~GRAMMAR
      grammar LookaheadNullable
        rule root
          nullable_prefix 'x' / 'x'
        end
        rule nullable_prefix
          &'a' 'a'?
        end
      end
    GRAMMAR

    result = generate(grammar_source, 'ax')

    branch(result, 0).status.should eq(:covered)
    branch(result, 0).sample_input.should eq('ax')
    branch(result, 1).status.should eq(:covered)
    branch(result, 1).sample_input.should eq('x')
  end

  it 'records choices executed inside a successful syntactic lookahead' do
    grammar_source = <<~GRAMMAR
      grammar LookaheadCoverage
        rule root
          &inside_lookahead [ab]
        end
        rule inside_lookahead
          'a' / 'b'
        end
      end
    GRAMMAR

    result = generate(grammar_source, 'ab')
    nested = result.branches.find { |branch| branch.rule == :inside_lookahead && branch.index.zero? }

    nested.status.should eq(:covered)
    nested.sample_input.should eq('a')
    result.samples.flat_map(&:branch_ids).should include(nested.id)
  end

  it 'does not record choices from a failed negative-lookahead attempt' do
    grammar_source = <<~GRAMMAR
      grammar NegativeLookaheadCoverage
        rule root
          !forbidden 'a'
        end
        rule forbidden
          'a' / 'b'
        end
      end
    GRAMMAR

    result = generate(grammar_source, 'ab')
    forbidden = result.branches.find { |branch| branch.rule == :forbidden && branch.index.zero? }

    forbidden.status.should eq(:not_found)
    result.samples.flat_map(&:branch_ids).should_not include(forbidden.id)
  end

  it 'uses nullable prefixes to prove later ordered alternatives unreachable' do
    grammar_source = <<~GRAMMAR
      grammar NullableOrdering
        rule root
          optional_prefix 'x' / 'x'
        end
        rule optional_prefix
          'a'?
        end
      end
    GRAMMAR

    result = generate(grammar_source, 'ax')

    branch(result, 0).status.should eq(:covered)
    branch(result, 0).sample_input.should eq('x')
    branch(result, 1).status.should eq(:unreachable)
  end

  it 'keeps embedded Ruby semantic branches unknown when no runtime witness is found' do
    grammar_source = <<~GRAMMAR
      grammar SemanticUnknown
        rule root
          semantic_branch / 'a'
        end
        rule semantic_branch
          'b' & { |nodes| false }
        end
      end
    GRAMMAR

    result = generate(grammar_source, 'ab')

    branch(result, 0).status.should eq(:unknown)
    branch(result, 0).semantic.should eq(true)
    branch(result, 1).status.should eq(:covered)
    branch(result, 1).sample_input.should eq('a')
  end

  it 'marks a syntactically shadowed semantic branch unreachable instead of unknown' do
    result = generate(grammar('SemanticButShadowed', "'a' / ('ab' & { |nodes| true })"), 'ab')

    branch(result, 0).status.should eq(:covered)
    branch(result, 1).status.should eq(:unreachable)
    branch(result, 1).semantic.should eq(true)
  end

  it 'reports a bounded search miss rather than proving a long branch unreachable' do
    result = generate(grammar('LongBranch', "'aaaa' / 'b'"), 'ab', max_length: 2)

    branch(result, 0).status.should eq(:not_found)
    branch(result, 1).status.should eq(:covered)
    result.search_space_exhausted.should eq(true)
  end

  it 'marks the search as non-exhaustive when the candidate budget is exhausted' do
    result = generate(grammar('BudgetCutoff', "'aaaa' / 'b'"), 'ab', max_length: 4, search_budget: 1)

    branch(result, 0).status.should eq(:not_found)
    result.search_space_exhausted.should eq(false)
  end

  it 'renders a JSON report using statuses verified by parser execution' do
    result = generate(grammar('JsonReport', "'a' / 'ab'"), 'ab')
    payload = JSON.parse(Treetop::SampleReport.json(result))

    payload['samples'].first['input'].should eq('a')
    payload['summary'].slice('covered', 'unreachable', 'unknown', 'not_found').should eq(
      'covered' => 1,
      'unreachable' => 1,
      'unknown' => 0,
      'not_found' => 0
    )
  end
end
