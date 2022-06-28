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
        current = automaton.initial_state

        index = 0
        bytes = string.bytes

        loop do
          return automaton.final?(current) if index == bytes.length

          selected =
            automaton.transitions[current].detect do |(to, transition)|
              case transition
              in Automaton::AnyTransition
                break to
              in Automaton::CharacterTransition[value:]
                break to if bytes[index] == value
              in Automaton::MaskTransition[value:]
                break to if (bytes[index] & value) == value
              in Automaton::RangeTransition[from: min, to: max]
                break to if (min..max).cover?(bytes[index])
              end
            end

          if !selected
            return automaton.final?(current)
          elsif automaton.final?(selected)
            return true
          else
            current = selected
            index += 1
          end
        end
      end
    end
  end
end
