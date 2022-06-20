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

      # Connect this state to another state through a transition. This adds the
      # transition to the start of the list.
      def connect_to(transition, state)
        transitions.unshift([transition, state])
      end

      # Connect this state to another state through an epsilon transition. This
      # adds the epsilon transition to the end of the list. This means by
      # default patterns will be greedy (since they will attempt to match the
      # epsilon transition after all other transitions have failed).
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

    # This class compiles an AST into an NFA. It is an implementation of the
    # Thompson's construction algorithm. For more information, see the paper:
    # https://dl.acm.org/doi/10.1145/363347.363387.
    class Compiler
      attr_reader :labels, :encoder, :unicode

      def initialize
        @labels = ("1"..).each
        @encoder = Encoding::UTF8.new(self)
        @unicode = Unicode::Cache.new
      end

      def call(pattern)
        start_state = State.new(label: "START")
        queue = [[pattern, start_state, State.new(label: "FINISH", final: true)]]

        while ((node, start, finish) = queue.shift)
          case node
          in AST::Expression[items:]
            inner = Array.new(items.length - 1) { State.new(label: labels.next) }
            states = [start, *inner, finish]
  
            items.each_with_index do |item, index|
              queue << [item, states[index], states[index + 1]]
            end
          in AST::Group[expressions:]
            expressions.each do |expression|
              queue << [expression, start, finish]
            end
          in AST::MatchAny
            encoder.connect_any(start, finish)
          in AST::MatchCharacter[value:]
            encoder.connect_value(start, finish, value.ord)
          in AST::MatchClass[name: :digit]
            encoder.connect_range(start, finish, "0".ord.."9".ord)
          in AST::MatchClass[name: :hex]
            encoder.connect_range(start, finish, "0".ord.."9".ord)
            encoder.connect_range(start, finish, "A".ord.."F".ord)
            encoder.connect_range(start, finish, "a".ord.."f".ord)
          in AST::MatchClass[name: :space]
            encoder.connect_range(start, finish, "\t".ord.."\r".ord)
            encoder.connect_value(start, finish, " ".ord)
          in AST::MatchClass[name: :word]
            encoder.connect_range(start, finish, "0".ord.."9".ord)
            encoder.connect_value(start, finish, "_".ord)
            encoder.connect_range(start, finish, "A".ord.."Z".ord)
            encoder.connect_range(start, finish, "a".ord.."z".ord)
          in AST::MatchProperty[value:]
            connect_unicode(start, finish, [value])
          in AST::MatchRange[from:, to:]
            encoder.connect_range(start, finish, from.ord..to.ord)
          in AST::MatchSet[items:]
            items.each do |item|
              queue << [item, start, finish]
            end
          in AST::Pattern[expressions:]
            expressions.each do |expression|
              queue << [expression, start, finish]
            end
          in AST::POSIXClass[name: :alnum]
            connect_unicode(start, finish, [
              "general_category=letter",
              "general_category=mark",
              "general_category=decimal_number"
            ])
          in AST::POSIXClass[name: :alpha]
            connect_unicode(start, finish, [
              "general_category=letter",
              "general_category=mark"
            ])
          in AST::POSIXClass[name: :ascii]
            connect_unicode(start, finish, ["ascii"])
          in AST::POSIXClass[name: :blank]
            connect_unicode(start, finish, ["general_category=space_separator"])
            encoder.connect_value(start, finish, "\t".ord)
          in AST::POSIXClass[name: :cntrl]
            connect_unicode(start, finish, [
              "general_category=control",
              "general_category=format",
              "general_category=unassigned",
              "general_category=private_use",
              "general_category=surrogate"
            ])
          in AST::POSIXClass[name: :digit]
            connect_unicode(start, finish, ["general_category=decimal_number"])
          in AST::POSIXClass[name: :graph]
            raise UnimplementedError
          in AST::POSIXClass[name: :lower]
            connect_unicode(start, finish, ["general_category=lowercase_letter"])
          in AST::POSIXClass[name: :print]
            raise UnimplementedError
          in AST::POSIXClass[name: :punct]
            connect_unicode(start, finish, [
              "general_category=connector_punctuation",
              "general_category=dash_punctuation",
              "general_category=close_punctuation",
              "general_category=final_punctuation",
              "general_category=initial_punctuation",
              "general_category=other_punctuation",
              "general_category=open_punctuation"
            ])

            encoder.connect_value(start, finish, 0x24)
            encoder.connect_value(start, finish, 0x2b)
            encoder.connect_range(start, finish, 0x3c..0x3e)
            encoder.connect_value(start, finish, 0x5e)
            encoder.connect_value(start, finish, 0x60)
            encoder.connect_value(start, finish, 0x7c)
            encoder.connect_value(start, finish, 0x7e)
          in AST::POSIXClass[name: :space]
            connect_unicode(start, finish, [
              "general_category=space_separator",
              "general_category=line_separator",
              "general_category=paragraph_separator"
            ])

            encoder.connect_range(start, finish, "\t".ord.."\r".ord)
            encoder.connect_value(start, finish, 0x85)
          in AST::POSIXClass[name: :upper]
            connect_unicode(start, finish, ["general_category=uppercase_letter"])
          in AST::POSIXClass[name: :xdigit]
            encoder.connect_range(start, finish, "0".ord.."9".ord)
            encoder.connect_range(start, finish, "A".ord.."F".ord)
            encoder.connect_range(start, finish, "a".ord.."f".ord)
          in AST::POSIXClass[name: :word]
            connect_unicode(start, finish, [
              "general_category=letter",
              "general_category=mark",
              "general_category=decimal_number",
              "general_category=connector_punctuation"
            ])
          in AST::Quantified[item:, quantifier: AST::OptionalQuantifier]
            queue << [item, start, finish]
            start.epsilon_to(finish)
          in AST::Quantified[item:, quantifier: AST::PlusQuantifier]
            queue << [item, start, finish]
            finish.epsilon_to(start)
          in AST::Quantified[item:, quantifier: AST::RangeQuantifier[minimum:, maximum: nil]]
            inner = minimum == 0 ? [] : Array.new(minimum - 1) { State.new(label: labels.next) }
            states = [start, *inner, finish]
  
            minimum.times do |index|
              queue << [item, states[index], states[index + 1]]
            end
  
            states[-1].epsilon_to(states[-2])
          in AST::Quantified[item:, quantifier: AST::RangeQuantifier[minimum:, maximum:]]
            inner = maximum == 0 ? [] : Array.new(maximum - 1) { State.new(label: labels.next) }
            states = [start, *inner, finish]
  
            maximum.times do |index|
              queue << [item, states[index], states[index + 1]]
            end
  
            (maximum - minimum).times do |index|
              states[minimum + index].epsilon_to(finish)
            end
          in AST::Quantified[item:, quantifier: AST::StarQuantifier]
            queue << [item, start, start]
            start.epsilon_to(finish)
          end
        end

        start_state
      end

      # This method is called back to from the encoding class.
      def connect(start, finish, min_bytes, max_bytes)
        states = [
          start,
          *Array.new(min_bytes.length - 1) { State.new(label: labels.next) },
          finish
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

      private

      def connect_unicode(start, finish, queries)
        queries.each do |query|
          unicode[query].each do |entry|
            case entry
            in Unicode::Range[min:, max:]
              encoder.connect_range(start, finish, min..max)
            in Unicode::Value[value:]
              encoder.connect_value(start, finish, value)
            end
          end
        end
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
