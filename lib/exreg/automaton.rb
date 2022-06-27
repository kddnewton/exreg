# frozen_string_literal: true

module Exreg
  # An automaton is a collection of states and transitions. It can be either
  # deterministic or non-deterministic, depending on whether or not there are
  # two transitions for any given state for the same input ∈ Σ.
  class Automaton
    # This represents a transition between two states that accepts any
    # character.
    class AnyTransition
      def pretty_print(q)
        q.text("(any)")
      end
    end

    # This represents a transition between two states that matches against a
    # specific character.
    class CharacterTransition
      attr_reader :value

      def initialize(value:)
        @value = value
      end

      def deconstruct_keys(keys)
        { value: value }
      end

      def pretty_print(q)
        q.group do
          q.text("(character")
          q.nest(2) do
            q.breakable
            q.text("0x#{value.to_s(16)}")
          end
          q.breakable("")
          q.text(")")
        end
      end
    end

    # This represents a transition between two states that is allowed to
    # transition without matching any characters.
    class EpsilonTransition
      def pretty_print(q)
        q.text("(epsilon)")
      end
    end

    # This is a specialization of the range transition that will check for a
    # match by using bitwise masking.
    class MaskTransition
      attr_reader :value

      def initialize(value:)
        @value = value
      end

      def deconstruct_keys(keys)
        { value: value }
      end

      def pretty_print(q)
        q.group do
          q.text("(mask")
          q.nest(2) do
            q.breakable
            q.text("0b#{value.to_s(2)}".gsub(/(0+)$/) { "x" * $1.length })
          end
          q.breakable("")
          q.text(")")
        end
      end
    end

    # This represents a transition between two states that matches against a
    # range of characters.
    class RangeTransition
      attr_reader :from, :to

      def initialize(from:, to:)
        @from = from
        @to = to
      end

      def deconstruct_keys(keys)
        { from: from, to: to }
      end

      def pretty_print(q)
        q.group do
          q.text("(range")
          q.nest(2) do
            q.breakable
            q.text("0x#{from.to_s(16)}")
            q.breakable
            q.text("0x#{to.to_s(16)}")
          end
          q.breakable("")
          q.text(")")
        end
      end
    end

    # Array[Symbol] - The set of states in the automaton. Formally described
    # as Q.
    attr_reader :states

    # Hash[Symbol, Array[[Symbol, Transition]]] - The transition table. The
    # keys are states, and the values are pairs of transitions and other
    # states. Formally described as ∆ = Q × Σ → 2^Q, where Σ is the alphabet
    # of the automaton.
    attr_reader :transitions

    # Symbol - The initial state, formally described as q0 ∈ Q.
    attr_reader :initial_state

    # Array[Symbol] - The set of accepting states, formally described as
    # F ⊆ Q.
    attr_reader :accepting_states

    # Enumerator[Symbol] - An enumerator that yields out labels for new states
    # as necessary.
    attr_reader :labels

    def initialize(
      states: [],
      transitions: Hash.new { |hash, key| hash[key] = [] },
      initial_state: nil,
      accepting_states: []
    )
      @states = states
      @transitions = transitions
      @initial_state = initial_state
      @accepting_states = accepting_states

      # This enumerator is used to build out new states as they are necessary.
      @labels = (:"1"..).each
    end

    # Connect two states in the automaton by a transition.
    def connect(start, finish, transition)
      transitions[start].unshift([finish, transition])
    end

    # Connect two states in the automaton by an epsilon transition. Note that
    # these transitions go onto the back of the list since our NFAs are eager by
    # default.
    def connect_epsilon(start, finish)
      transitions[start] << [finish, EpsilonTransition.new]
    end

    # The epsilon closure of a set of states is defined as the set of states
    # that are reachable from the given set of states by epsilon transitions.
    # This is necessary to calculate when determinizing an automaton.
    #
    # For example if we have the following NFA which represents the a?a?b
    # language:
    #
    # ─> (1) ─a─> (2) ─a─> (3) ─b─> [4]
    #     └───ε-──^└───ε-───^
    #
    # Then if you passed [1] into here we would return [1, 2, 3].
    def epsilon_closure(initial)
      states = [*initial]
      index = 0

      while index < states.length
        transitions[states[index]].each do |(to, transition)|
          if (transition in EpsilonTransition) && !states.include?(to)
            states << to
          end
        end
        index += 1
      end

      states.sort
    end

    # True if the given state is in the list of accepting states.
    def final?(state)
      accepting_states.include?(state)
    end

    # Create a new state and return its label.
    def state
      label = labels.next
      states << label
      label
    end
  end
end
