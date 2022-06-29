# frozen_string_literal: true

module Exreg
  module Strategy
    # This class wraps a set of states and transitions with the ability to
    # execute them against a given input.
    class Deterministic
      attr_reader :automaton

      def initialize(automaton)
        @automaton = automaton
      end

      # Executes the machine against the given string.
      def match?(string)
        state = automaton.initial_state

        index = 0
        bytes = string.bytes

        loop do
          return automaton.final?(state) if index == bytes.length

          next_state = step(state, bytes[index])

          if !next_state
            return automaton.final?(state)
          elsif automaton.final?(next_state)
            return true
          else
            state = next_state
            index += 1
          end
        end
      end

      private

      def step(state, byte)
        automaton.transitions[state].detect do |(to, transition)|
          case transition
          in Automaton::AnyTransition
            return to
          in Automaton::CharacterTransition[value:]
            return to if byte == value
          in Automaton::MaskTransition[value:]
            return to if (byte & value) == value
          in Automaton::RangeTransition[from: min, to: max]
            return to if (min..max).cover?(byte)
          end
        end
      end
    end
  end
end
