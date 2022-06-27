# frozen_string_literal: true

module Exreg
  # This module contains classes that make up the deterministic state machine
  # representation of the regular expression.
  module DFA
    # This class is responsible for compiling an NFA into a DFA. It does this
    # through a process called powerset construction or subset construction.
    #
    # The general idea is to eagerly walk through the state machine and simulate
    # each possible input at the epsilon-closure of each state. (The
    # epsilon-closure of a state is the set of states that can be reached from
    # that state by following epsilon transitions.) Then, each set of states
    # reached by each transition is a new state in the DFA.
    #
    # Note that doing this eagerly has its drawbacks. For an NFA of n states,
    # the worst-case corresponding DFA could have as many as 2^n states. This
    # can be impractical for large NFAs.
    class Compiler
      attr_reader :current

      def initialize(current)
        @current = current
      end

      def call
        # This is a mapping from a set of states in the current automaton to the
        # name of the state in the new automaton.
        initial_state_set = current.epsilon_closure([current.initial_state])
        state_sets = { initial_state_set => :start }

        # This automaton is going to be used to hold all of the transitions and
        # states until we can do some final processing at the end.
        automaton =
          Automaton.new(
            states: %i[start],
            initial_state: state_sets[initial_state_set]
          )

        visited_state_sets = Set.new([initial_state_set])
        queue = [initial_state_set]

        while (state_set = queue.shift)
          # First, we're going to build up a mapping of states to the alphabet
          # pieces that lead to those states.
          alphabet_states =
            Hash.new { |hash, key| hash[key] = Alphabet::None.new }

          alphabet_for(state_set).to_a.each do |alphabet|
            next_state_set = Set.new

            state_set.each do |state|
              current.transitions[state].each do |(next_state, transition)|
                next if transition in Automaton::EpsilonTransition
                next_state_set << next_state if matches?(alphabet, transition)
              end
            end

            # Now that we've tested each of the transitions for the current
            # state set, we can follow all of the epsilon transitions to make
            # sure we have the full picture.
            next_state_set = current.epsilon_closure(next_state_set.to_a)

            # This should never happen. Because of the way we split up the
            # alphabets, we should always be able to find a state that matches
            # the current alphabet we're looking at. If we can't, then we've
            # got a problem.
            raise if next_state_set.empty?

            state_sets[next_state_set] ||= automaton.state
            alphabet_states[next_state_set] =
              Alphabet.combine(alphabet_states[next_state_set], alphabet)
          end

          # Next, we're going to add the new states and all of the associated
          # transitions.
          alphabet_states.each do |next_state_set, next_alphabet|
            next_alphabet.to_a.each do |alphabet|
              connect(automaton, state_sets[state_set], state_sets[next_state_set], alphabet)
            end

            unless visited_state_sets.include?(next_state_set)
              visited_state_sets << next_state_set
              queue << next_state_set
            end
          end
        end

        Automaton.new(
          states: automaton.states,
          transitions: automaton.transitions,
          initial_state: automaton.initial_state,
          accepting_states:
            state_sets.filter_map do |state_set, state_label|
              state_label if state_set.any? { |state| current.final?(state) }
            end
        )
      end

      private

      # Determine the alphabet to use for leading out of the given set of
      # states.
      def alphabet_for(state_set)
        alphabet = Alphabet::None.new

        state_set.each do |state|
          current.transitions[state].each do |(_, transition)|
            alphabet =
              Alphabet.overlay(
                alphabet,
                case transition
                in Automaton::AnyTransition
                  Alphabet::Any.new
                in Automaton::CharacterTransition[value:]
                  Alphabet::Value.new(value: value)
                in Automaton::EpsilonTransition
                  Alphabet::None.new
                in Automaton::RangeTransition[from:, to:]
                  Alphabet::Range.new(from: from, to: to)
                end
              )
          end
        end

        alphabet
      end

      # Creates transitions between two states for the given alphabet.
      def connect(automaton, from, to, alphabet)
        case alphabet
        in Alphabet::Any
          automaton.connect(from, to, Automaton::AnyTransition.new)
        in Alphabet::Multiple[alphabets:]
          alphabets.each { |alphabet| connect(automaton, from, to, alphabet) }
        in Alphabet::None
          # do nothing
        in Alphabet::Range[from: min, to: max]
          if ((min - 1) | min) == max
            # This is a special case where we can check for a range of bytes by
            # just masking the value against a bitmask. For example, if we have
            # the minimum as 0b11110100 and the maximum as 0b11110111, then the
            # predicate above passes and at runtime we can check if
            # number & 0b11110100 == 0b11110100 (because the last 2 bits are
            # included in the range).
            automaton.connect(from, to, Automaton::MaskTransition.new(value: min))
          else
            automaton.connect(from, to, Automaton::RangeTransition.new(from: min, to: max))
          end
        in Alphabet::Value[value:]
          automaton.connect(from, to, Automaton::CharacterTransition.new(value: value))
        end
      end

      # Check if a given transition accepts the given alphabet.
      def matches?(alphabet, transition)
        case [alphabet, transition]
        in [Alphabet::Any, _] | [_, Automaton::AnyTransition]
          true
        in [Alphabet::Range[from:, to:], Automaton::CharacterTransition[value:]]
          (from..to).cover?(value)
        in [Alphabet::Range[from: alpha_from, to: alpha_to], Automaton::RangeTransition[from:, to:]]
          from <= alpha_from && to >= alpha_to
        in [Alphabet::Value[value: ord], Automaton::CharacterTransition[value:]]
          value == ord
        in [Alphabet::Value[value: ord], Automaton::RangeTransition[from:, to:]]
          (from..to).cover?(ord)
        end
      end
    end

    # This class wraps a set of states and transitions with the ability to
    # execute them against a given input.
    class Machine
      attr_reader :automaton

      def initialize(automaton:)
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

    # This converts an NFA into a DFA.
    def self.compile(nfa)
      Machine.new(automaton: Compiler.new(nfa.automaton).call)
    end
  end
end
