# frozen_string_literal: true

require "fileutils"
require "graphviz"

module Exreg
  # A small module used for converting state machines into digraphs to be used
  # by graphviz. This is just to make it easier to debug.
  module DiGraph
    def self.call(automaton, path)
      # First, write out the beginning of the graph which will be every state
      # in the state machine.
      graph = Graphviz::Graph.new(rankdir: "LR")
      nodes = {}

      automaton.states.each do |state|
        nodes[state] =
          graph.add_node(state.object_id, label: state.to_s, shape: automaton.final?(state) ? "box" : "oval")
      end

      # Next, write out all of the transitions.
      automaton.transitions.each do |from, transitions|
        transitions.each do |(to, transition)|
          label =
            case transition
            in Automaton::AnyTransition
              "."
            in Automaton::CharacterTransition[value:]
              "0x#{value.to_s(16)}"
            in Automaton::EpsilonTransition
              "ε"
            in Automaton::MaskTransition[value:]
              "0b#{value.to_s(2).gsub(/(0+)$/) { "x" * $1.length }}"
            in Automaton::RangeTransition[from: min, to: max]
              "0x#{min.to_s(16)}-0x#{max.to_s(16)}"
            end

          nodes[from].connect(nodes[to], label: label)
        end
      end

      puts graph.to_dot

      FileUtils.mkdir_p("build")
      Graphviz.output(graph, path: path, format: "svg")
      graph.to_dot
    end
  end
end
