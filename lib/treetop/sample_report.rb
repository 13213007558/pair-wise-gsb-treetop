require 'json'

module Treetop
  class SampleReport
    def self.text(result)
      new(result).text
    end

    def self.json(result)
      new(result).json
    end

    def initialize(result)
      @result = result
    end

    def text
      lines = []
      lines << 'Samples:'
      if @result.samples.empty?
        lines << '  (none)'
      else
        @result.samples.each do |sample|
          descriptions = sample.branch_ids.map { |id| describe_branch(id) }
          lines << "  #{sample.input.inspect} -> #{descriptions.join(', ')}"
        end
      end

      lines << ''
      lines << 'Choice branches:'
      grouped_branches.each do |rule, branches|
        lines << "  #{rule}"
        branches.each do |branch|
          lines << "    [#{branch.index}] #{status_label(branch.status)} #{branch.source}"
          lines << "        sample: #{branch.sample_input.inspect}" if branch.sample_input
        end
      end

      lines << ''
      lines << summary
      lines.join("\n")
    end

    def json
      JSON.pretty_generate(
        samples: @result.samples.map do |sample|
          { input: sample.input, branches: sample.branch_ids }
        end,
        branches: @result.branches.map do |branch|
          {
            id: branch.id,
            rule: branch.rule.to_s,
            index: branch.index,
            source: branch.source,
            status: branch.status.to_s,
            sample_input: branch.sample_input
          }
        end,
        summary: summary_counts.merge(
          search_count: @result.search_count,
          search_space_exhausted: @result.search_space_exhausted
        )
      )
    end

    private

    def grouped_branches
      @result.branches.group_by(&:rule)
    end

    def status_label(status)
      case status
      when :covered then 'covered'
      when :unreachable then 'proven unreachable'
      when :unknown then 'unknown semantic branch'
      else 'not found within search budget'
      end
    end

    def describe_branch(branch_id)
      branch = @result.branches.find { |candidate| candidate.id == branch_id }
      branch ? "#{branch.rule}[#{branch.index}]" : branch_id
    end

    def summary_counts
      counts = @result.branches.group_by(&:status).transform_values(&:size)
      {
        covered: counts.fetch(:covered, 0),
        unreachable: counts.fetch(:unreachable, 0),
        unknown: counts.fetch(:unknown, 0),
        not_found: counts.fetch(:not_found, 0)
      }
    end

    def summary
      "Summary: #{summary_counts.map { |key, value| "#{key}=#{value}" }.join(', ')}, " \
        "parses=#{@result.search_count}, exhaustive_bounded_search=#{@result.search_space_exhausted}"
    end
  end
end
