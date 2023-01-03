# frozen_string_literal: true

module Exreg
  # This module contains classes that make up the non-deterministic state
  # machine representation of the regular expression.
  module NFA
    # This class compiles an AST into an NFA. It is an implementation of the
    # Thompson's construction algorithm. For more information, see the paper:
    # https://dl.acm.org/doi/10.1145/363347.363387.
    class Compiler
      attr_reader :encoder, :unicode, :automaton

      def initialize
        @encoder = Encoding::UTF8.new(self)
        @unicode = Unicode::Cache.new
        @automaton =
          Automaton.new(
            states: %i[start finish],
            initial_state: :start,
            accepting_states: %i[finish]
          )
      end

      def call(pattern)
        queue = [[pattern, :start, :finish]]

        while (node, start, finish = queue.shift)
          case node
          in AST::Expression[items:]
            inner = Array.new(items.length - 1) { automaton.state }
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
            items.each { |item| queue << [item, start, finish] }
          in AST::Pattern[expressions:]
            expressions.each do |expression|
              queue << [expression, start, finish]
            end
          in AST::POSIXClass[name: :alnum]
            connect_unicode(
              start,
              finish,
              %w[
                general_category=letter
                general_category=mark
                general_category=decimal_number
              ]
            )
          in AST::POSIXClass[name: :alpha]
            connect_unicode(
              start,
              finish,
              %w[general_category=letter general_category=mark]
            )
          in AST::POSIXClass[name: :ascii]
            connect_unicode(start, finish, ["ascii"])
          in AST::POSIXClass[name: :blank]
            connect_unicode(start, finish, ["general_category=space_separator"])
            encoder.connect_value(start, finish, "\t".ord)
          in AST::POSIXClass[name: :cntrl]
            connect_unicode(
              start,
              finish,
              %w[
                general_category=control
                general_category=format
                general_category=unassigned
                general_category=private_use
                general_category=surrogate
              ]
            )
          in AST::POSIXClass[name: :digit]
            connect_unicode(start, finish, ["general_category=decimal_number"])
          in AST::POSIXClass[name: :graph]
            raise UnimplementedError
          in AST::POSIXClass[name: :lower]
            connect_unicode(
              start,
              finish,
              ["general_category=lowercase_letter"]
            )
          in AST::POSIXClass[name: :print]
            raise UnimplementedError
          in AST::POSIXClass[name: :punct]
            connect_unicode(
              start,
              finish,
              %w[
                general_category=connector_punctuation
                general_category=dash_punctuation
                general_category=close_punctuation
                general_category=final_punctuation
                general_category=initial_punctuation
                general_category=other_punctuation
                general_category=open_punctuation
              ]
            )

            encoder.connect_value(start, finish, 0x24)
            encoder.connect_value(start, finish, 0x2b)
            encoder.connect_range(start, finish, 0x3c..0x3e)
            encoder.connect_value(start, finish, 0x5e)
            encoder.connect_value(start, finish, 0x60)
            encoder.connect_value(start, finish, 0x7c)
            encoder.connect_value(start, finish, 0x7e)
          in AST::POSIXClass[name: :space]
            connect_unicode(
              start,
              finish,
              %w[
                general_category=space_separator
                general_category=line_separator
                general_category=paragraph_separator
              ]
            )

            encoder.connect_range(start, finish, "\t".ord.."\r".ord)
            encoder.connect_value(start, finish, 0x85)
          in AST::POSIXClass[name: :upper]
            connect_unicode(
              start,
              finish,
              ["general_category=uppercase_letter"]
            )
          in AST::POSIXClass[name: :xdigit]
            encoder.connect_range(start, finish, "0".ord.."9".ord)
            encoder.connect_range(start, finish, "A".ord.."F".ord)
            encoder.connect_range(start, finish, "a".ord.."f".ord)
          in AST::POSIXClass[name: :word]
            connect_unicode(
              start,
              finish,
              %w[
                general_category=letter
                general_category=mark
                general_category=decimal_number
                general_category=connector_punctuation
              ]
            )
          in AST::Quantified[item:, quantifier: AST::OptionalQuantifier]
            queue << [item, start, finish]
            automaton.connect_epsilon(start, finish)
          in AST::Quantified[item:, quantifier: AST::PlusQuantifier]
            queue << [item, start, finish]
            automaton.connect_epsilon(finish, start)
          in AST::Quantified[
               item:, quantifier: AST::RangeQuantifier[minimum:, maximum: nil]
             ]
            inner =
              minimum == 0 ? [] : Array.new(minimum - 1) { automaton.state }
            states = [start, *inner, finish]

            minimum.times do |index|
              queue << [item, states[index], states[index + 1]]
            end

            automaton.connect_epsilon(states[-1], states[-2])
          in AST::Quantified[
               item:, quantifier: AST::RangeQuantifier[minimum:, maximum:]
             ]
            inner =
              maximum == 0 ? [] : Array.new(maximum - 1) { automaton.state }
            states = [start, *inner, finish]

            maximum.times do |index|
              queue << [item, states[index], states[index + 1]]
            end

            (maximum - minimum).times do |index|
              automaton.connect_epsilon(states[minimum + index], finish)
            end
          in AST::Quantified[item:, quantifier: AST::StarQuantifier]
            queue << [item, start, start]
            automaton.connect_epsilon(start, finish)
          end
        end

        automaton
      end

      # This method is called back to from the encoding class.
      def connect(start, finish, min_bytes, max_bytes)
        states = [
          start,
          *Array.new(min_bytes.length - 1) { automaton.state },
          finish
        ]

        min_bytes.length.times do |index|
          transition =
            if min_bytes[index] == max_bytes[index]
              Automaton::CharacterTransition.new(value: min_bytes[index])
            else
              Automaton::RangeTransition.new(
                from: min_bytes[index],
                to: max_bytes[index]
              )
            end

          automaton.connect(states[index], states[index + 1], transition)
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

    # This takes an AST::Pattern node and converts it into an NFA.
    def self.compile(pattern)
      Compiler.new.call(pattern)
    end
  end
end
