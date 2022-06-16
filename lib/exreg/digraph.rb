# frozen_string_literal: true

require "fileutils"
require "graphviz"

module Exreg
  # A small module used for converting state machines into digraphs to be used
  # by graphviz. This is just to make it easier to debug.
  module DiGraph
    def self.call(start_state, path)
      states = Set.new
      queue = [start_state]

      # First, gather up a list of all of the states in the state machine.
      while (state = queue.shift)
        next if states.include?(state)

        states << state
        state.transitions.each do |transition, state|
          queue << state
        end
      end

      # Next, write out the beginning of the graph which will be every state
      # in the state machine.
      graph = Graphviz::Graph.new(rankdir: "LR")
      nodes = {}

      states.each do |state|
        nodes[state] =
          graph.add_node(
            state.object_id,
            label: state.label,
            shape: state.final? ? "box" : "oval"
          )
      end

      # Next, write out all of the transitions.
      states.each do |from|
        from.transitions.each do |transition, to|
          label =
            case transition
            in DFA::AnyTransition | NFA::AnyTransition
              "."
            in DFA::CharacterTransition[value:]
              "0x#{value.to_s(16)}"
            in NFA::CharacterTransition[value:]
              "0x#{value.to_s(16)}"
            in DFA::RangeTransition[from: min, to: max]
              "0x#{min.to_s(16)}-0x#{max.to_s(16)}"
            in NFA::RangeTransition[from: min, to: max]
              "0x#{min.to_s(16)}-0x#{max.to_s(16)}"
            in NFA::EpsilonTransition
              "ε"
            end

          nodes[from].connect(nodes[to], label: label)
        end
      end

      FileUtils.mkdir_p("build")
      Graphviz.output(graph, path: path, format: "svg")
      graph.to_dot
    end
  end
end
