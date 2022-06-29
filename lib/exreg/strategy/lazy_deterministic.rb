# frozen_string_literal: true

module Exreg
  module Strategy
    # LazyDeterministic is a strategy that walks a nondeterministic automaton
    # multiple states at a time.
    class LazyDeterministic
      # Automaton
      attr_reader :automaton

      # Hash[Set[State] => Hash[Integer => Set[State]]]
      attr_reader :cache

      def initialize(automaton)
        @automaton = automaton
        @cache = {}
      end

      # Executes the machine against the given string.
      def match?(string)
        states = Set.new(automaton.epsilon_closure([automaton.initial_state]))

        index = 0
        bytes = string.bytes

        loop do
          return final?(states) if index == bytes.length

          next_states = step(states, bytes[index])

          if next_states.empty?
            return final?(states)
          elsif final?(next_states)
            return true
          else
            states = next_states
            index += 1
          end
        end
      end

      private

      def step(states, byte)
        key = states.join("_").to_sym
        cached = cache.dig(key, byte)
        return cached if cached

        next_states = Set.new
        states.each do |state|
          automaton.transitions[state].each do |(to, transition)|
            case transition
            in Automaton::AnyTransition
              next_states.add(to)
            in Automaton::CharacterTransition[value:]
              next_states.add(to) if byte == value
            in Automaton::EpsilonTransition
              # do nothing
            in Automaton::RangeTransition[from: range_from, to: range_to]
              next_states.add(to) if (range_from..range_to).cover?(byte)
            end
          end
        end

        cache[key] ||= {}
        cache[key][byte] = Set.new(automaton.epsilon_closure(next_states))
      end

      def final?(states)
        states.any? { |state| automaton.final?(state) }
      end
    end
  end
end
