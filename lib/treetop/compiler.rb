require 'treetop/ruby_extensions'

module Treetop
  module Compiler
    class << self
      # When true, generated parsers record successful ordered-choice
      # alternatives through Treetop::Runtime.branch_covered!. Off by default
      # so ordinary generated parsers keep zero instrumentation overhead.
      attr_accessor :branch_coverage
    end
    self.branch_coverage = false

    def self.branch_coverage?
      branch_coverage ? true : false
    end

    # Maps a Choice AST node (object identity) to [rule_name, compile address]
    # during a branch-coverage compilation. The sample generator reads this to
    # build the same "rule@address" branch ids emitted into parser code.
    def self.record_choice_branch(choice_node, rule_name, address)
      choice_branch_registry[choice_node.object_id] = [rule_name, address]
    end

    def self.choice_branch_registry
      @choice_branch_registry ||= {}
    end

    def self.reset_choice_branch_registry!
      @choice_branch_registry = {}
    end
  end
end

require 'treetop/compiler/lexical_address_space'
require 'treetop/compiler/ruby_builder'
require 'treetop/compiler/node_classes'
require 'treetop/compiler/metagrammar' unless defined?($exclude_metagrammar)
require 'treetop/compiler/grammar_compiler'
