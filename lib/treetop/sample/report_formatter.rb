module Treetop
  module Sample
    # Renders a Generator Report as human-readable text or structured data.
    module ReportFormatter
      STATUS_LABEL = {
        covered: 'COVERED',
        proven_unreachable: 'PROVEN UNREACHABLE',
        unknown: 'UNKNOWN (embedded Ruby / unanalysable guard)',
        not_found: 'NOT FOUND WITHIN SEARCH BUDGET'
      }.freeze

      def self.to_text(report)
        lines = []
        lines << 'Treetop sample generation report'
        lines << '=' * 60
        lines << "samples accepted : #{report.accepted_samples.size}"
        lines << "candidates tried : #{report.candidates_tried}"
        lines << "budget exhausted  : #{report.budget_exhausted ? 'yes' : 'no'}"
        lines << ''
        lines << 'Samples (verified by running the parser)'
        lines << '-' * 60
        report.accepted_samples.first(20).each do |sample|
          branches = sample.branches.map { |id, index| "#{id}##{index}" }.sort
          lines << "  #{sample.input.inspect.ljust(16)} -> #{branches.join(', ')}"
        end
        lines << ''
        lines << 'Ordered-choice branches'
        lines << '-' * 60
        grouped = report.branches.group_by(&:branch_id)
        grouped.each do |branch_id, branches|
          lines << "choice #{branch_id}"
          branches.each do |branch|
            label = STATUS_LABEL.fetch(branch.status, branch.status.to_s)
            witness = branch.witness ? "  witness=#{branch.witness.inspect}" : ''
            lines << "  alt ##{branch.alternative_index}  #{label}#{witness}"
          end
        end
        lines << ''
        summary(report, lines)
        lines.join("\n")
      end

      def self.summary(report, lines)
        lines << 'Summary'
        lines << '-' * 60
        lines << "  covered            : #{report.covered.size}"
        lines << "  proven unreachable : #{report.proven_unreachable.size}"
        lines << "  unknown            : #{report.unknown.size}"
        lines << "  not found (budget) : #{report.not_found.size}"
      end

      def self.to_h(report)
        {
          samples: report.accepted_samples.map do |sample|
            {
              input: sample.input,
              branches: sample.branches.map { |id, index| "#{id}##{index}" }.sort
            }
          end,
          candidates_tried: report.candidates_tried,
          budget_exhausted: report.budget_exhausted,
          branches: report.branches.map do |branch|
            {
              choice: branch.branch_id,
              alternative: branch.alternative_index,
              status: branch.status,
              witness: branch.witness
            }
          end
        }
      end
    end
  end
end
