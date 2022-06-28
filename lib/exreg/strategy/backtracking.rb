# frozen_string_literal: true

module Exreg
  module Strategy
    class Backtracking
      attr_reader :automaton

      def initialize(automaton)
        @automaton = automaton
      end

      def match?(string)
        match_at?(automaton.initial_state, string.bytes, 0)
      end

      private

      def match_at?(state, bytes, index)
        matched =
          automaton.transitions[state].any? do |(to, transition)|
            case transition
            in Automaton::AnyTransition
              match_at?(to, bytes, index + 1) if index < bytes.length
            in Automaton::CharacterTransition[value:]
              if index < bytes.length && bytes[index] == value
                match_at?(to, bytes, index + 1)
              end
            in Automaton::EpsilonTransition
              match_at?(to, bytes, index)
            in Automaton::RangeTransition[from: range_from, to: range_to]
              if index < bytes.length && (range_from..range_to).cover?(bytes[index])
                match_at?(to, bytes, index + 1)
              end
            end
          end

        matched || automaton.final?(state)
      end
    end
  end
end
