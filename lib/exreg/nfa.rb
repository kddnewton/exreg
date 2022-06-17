# frozen_string_literal: true

module Exreg
  # This module contains classes that make up the non-deterministic state
  # machine representation of the regular expression.
  module NFA
    # Represents a single state in the state machine. This is a place where the
    # state machine has transitioned to through accepting various characters.
    class State
      attr_reader :label, :transitions

      def initialize(label:, final: false)
        @label = label
        @final = final
        @transitions = []
      end

      def <=>(other)
        case label
        when "START"
          -1
        else
          label <=> other.label
        end
      end

      # Connect this state to another state through a transition.
      def connect_to(transition, state)
        transitions.unshift([transition, state])
      end

      # Connect this state to another state through an epsilon transition.
      def epsilon_to(state)
        transitions.push([EpsilonTransition.new, state])
      end

      def final?
        @final
      end
    end

    # This represents a transition between two states in the NFA that accepts
    # any character.
    class AnyTransition
      def pretty_print(q)
        q.text("(any)")
      end
    end

    # This represents a transition between two states in the NFA that matches
    # against a specific character.
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
            q.pp(value)
          end
          q.breakable("")
          q.text(")")
        end
      end
    end

    # This represents a transition between two states in the NFA that is allowed
    # to transition without matching any characters.
    class EpsilonTransition
      def pretty_print(q)
        q.text("(epsilon)")
      end
    end

    # This represents a transition between two states in the NFA that matches
    # against a range of characters.
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
            q.pp(from)
            q.breakable
            q.pp(to)
          end
          q.breakable("")
          q.text(")")
        end
      end
    end

    # This class compiles an AST into an NFA.
    class Compiler
      # This implements the necessary interface for the encoding classes to
      # connect between two states.
      class Connector
        attr_reader :from, :to, :labels

        def initialize(from:, to:, labels:)
          @from = from
          @to = to
          @labels = labels
        end

        # This method accepts two arrays of bytes of equal length.
        def connect(min_bytes, max_bytes)
          states = [
            from,
            *Array.new(min_bytes.length - 1) { State.new(label: labels.next) },
            to
          ]

          min_bytes.length.times do |index|
            transition =
              if min_bytes[index] == max_bytes[index]
                CharacterTransition.new(value: min_bytes[index])
              else
                RangeTransition.new(from: min_bytes[index], to: max_bytes[index])
              end

            states[index].connect_to(transition, states[index + 1])
          end
        end
      end

      # This represents a unit of work to be performed by the compiler. It is
      # used as a replacement to what would be a recursive method call in order
      # to linearize the compilation process. We do this for performance and so
      # that we aren't limited by the size of the Ruby call stack.
      class Connection
        attr_reader :node, :from, :to

        def initialize(node, from, to)
          @node = node
          @from = from
          @to = to
        end
      end

      attr_reader :labels, :unicode

      def initialize
        @labels = ("1"..).each
        @unicode = Unicode::Cache.new
      end

      def call(pattern)
        start = State.new(label: "START")
        queue = [Connection.new(pattern, start, State.new(label: "FINISH", final: true))]

        while (connection = queue.shift)
          case connection.node
          in AST::Expression[items:]
            inner = Array.new(items.length - 1) { State.new(label: labels.next) }
            states = [connection.from, *inner, connection.to]
  
            items.each_with_index do |item, index|
              queue << Connection.new(item, states[index], states[index + 1])
            end
          in AST::Group[expressions:]
            expressions.each do |expression|
              queue << Connection.new(expression, connection.from, connection.to)
            end
          in AST::MatchAny
            connect_any(connection.from, connection.to)
          in AST::MatchCharacter[value:]
            connect_value(value.ord, connection.from, connection.to)
          in AST::MatchClass[name: :digit]
            connect_range("0".ord, "9".ord, connection.from, connection.to)
          in AST::MatchClass[name: :hex]
            connect_range("0".ord, "9".ord, connection.from, connection.to)
            connect_range("A".ord, "F".ord, connection.from, connection.to)
            connect_range("a".ord, "f".ord, connection.from, connection.to)
          in AST::MatchClass[name: :space]
            connect_range("\t".ord, "\r".ord, connection.from, connection.to)
            connect_value(" ".ord, connection.from, connection.to)
          in AST::MatchClass[name: :word]
            connect_range("0".ord, "9".ord, connection.from, connection.to)
            connect_value("_".ord, connection.from, connection.to)
            connect_range("A".ord, "Z".ord, connection.from, connection.to)
            connect_range("a".ord, "z".ord, connection.from, connection.to)
          in AST::MatchProperty[value:]
            unicode[value].each do |entry|
              case entry
              in Unicode::Range[min:, max:]
                connect_range(min, max, connection.from, connection.to)
              in Unicode::Value[value:]
                connect_value(value, connection.from, connection.to)
              end
            end
          in AST::MatchRange[from:, to:]
            connect_range(from.ord, to.ord, connection.from, connection.to)
          in AST::MatchSet[items:]
            items.each do |item|
              queue << Connection.new(item, connection.from, connection.to)
            end
          in AST::Pattern[expressions:]
            expressions.each do |expression|
              queue << Connection.new(expression, connection.from, connection.to)
            end
          in AST::Quantified[item:, quantifier: AST::OptionalQuantifier]
            queue << Connection.new(item, connection.from, connection.to)
            connection.from.epsilon_to(connection.to)
          in AST::Quantified[item:, quantifier: AST::PlusQuantifier]
            queue << Connection.new(item, connection.from, connection.to)
            connection.to.epsilon_to(connection.from)
          in AST::Quantified[item:, quantifier: AST::RangeQuantifier[minimum:, maximum: nil]]
            inner = minimum == 0 ? [] : Array.new(minimum - 1) { State.new(label: labels.next) }
            states = [connection.from, *inner, connection.to]
  
            minimum.times do |index|
              queue << Connection.new(item, states[index], states[index + 1])
            end
  
            states[-1].epsilon_to(states[-2])
          in AST::Quantified[item:, quantifier: AST::RangeQuantifier[minimum:, maximum:]]
            inner = maximum == 0 ? [] : Array.new(maximum - 1) { State.new(label: labels.next) }
            states = [connection.from, *inner, connection.to]
  
            maximum.times do |index|
              queue << Connection.new(item, states[index], states[index + 1])
            end
  
            (maximum - minimum).times do |index|
              states[minimum + index].epsilon_to(connection.to)
            end
          in AST::Quantified[item:, quantifier: AST::StarQuantifier]
            queue << Connection.new(item, connection.from, connection.from)
            connection.from.epsilon_to(connection.to)
          end
        end

        start
      end

      private

      # Connect an individual value between two states. This breaks it up into
      # its byte representation and creates states for each one. Since this is
      # an NFA it's okay for us to duplicate transitions here.
      def connect_value(value, from, to)
        connector = Connector.new(from: from, to: to, labels: labels)
        UTF8::Encoder.new(connector).connect_value(value)
      end

      # Connect a range of values between two states. Similar to connect_value,
      # this also breaks it up into its component bytes, but it's a little
      # harder because we need to mask a bunch of times to get the correct
      # groupings.
      def connect_range(min, max, from, to)
        connector = Connector.new(from: from, to: to, labels: labels)
        UTF8::Encoder.new(connector).connect_range(min..max)
      end

      # Connect two states by a transition that will accept any input. This
      # needs to factor in the encoding since "any input" could be a variable
      # number of bytes.
      def connect_any(from, to)
        connector = Connector.new(from: from, to: to, labels: labels)
        UTF8::Encoder.new(connector).connect_any
      end
    end

    # This class wraps a set of states and transitions with the ability to
    # execute them against a given input.
    class Machine
      attr_reader :start_state

      def initialize(start_state:)
        @start_state = start_state
      end

      # Executes the machine against the given string.
      def match?(string)
        match_at?(start_state, string.bytes, 0)
      end

      private

      def match_at?(state, bytes, index)
        matched =
          state.transitions.any? do |transition, to|
            case transition
            in AnyTransition
              match_at?(to, bytes, index + 1) if index < bytes.length
            in CharacterTransition[value:]
              if index < bytes.length && bytes[index] == value
                match_at?(to, bytes, index + 1)
              end
            in EpsilonTransition
              match_at?(to, bytes, index)
            in RangeTransition[from: range_from, to: range_to]
              if index < bytes.length && (range_from..range_to).cover?(bytes[index])
                match_at?(to, bytes, index + 1)
              end
            end
          end

        matched || state.final?
      end
    end

    # This takes an AST::Pattern node and converts it into an NFA.
    def self.compile(pattern)
      Machine.new(start_state: Compiler.new.call(pattern))
    end
  end
end
