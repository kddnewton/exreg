# frozen_string_literal: true

module Exreg
  # When we're converting between an NFA and a DFA, we need to transition from
  # a set of states to a new set of states. We determine the new set of states
  # as the union of all the states that can be reached from the old set by
  # applying a transition. We _could_ do this by iterating through every
  # possible value, but this would be time consuming. So instead, we use some
  # objects here to represent different sets of values that should be checked.
  #
  # These objects use the numeric representation of characters instead of the
  # characters themselves. This makes it easier to do math on them.
  module Alphabet
    MINIMUM = 0
    MAXIMUM = 0x10FFFF

    # Matches against the entire alphabet.
    class Any
      def ==(other)
        other in Any
      end

      def to_a
        [self]
      end

      def minimum
        MINIMUM
      end

      def maximum
        MAXIMUM
      end

      def pretty_print(q)
        q.text("(any)")
      end
    end

    # Matches against a set of multiple child alphabets.
    class Multiple
      attr_reader :alphabets

      def initialize(alphabets:)
        @alphabets = alphabets
      end

      def ==(other)
        other in Multiple[alphabets: ^(alphabets)]
      end

      def to_a
        alphabets
      end

      def deconstruct_keys(keys)
        { alphabets: alphabets }
      end

      def minimum
        alphabets.first.minimum
      end

      def maximum
        alphabets.last.maximum
      end

      def pretty_print(q)
        q.group do
          q.text("(multiple")
          q.nest(2) do
            q.breakable
            q.seplist(alphabets) { |alphabet| q.pp(alphabet) }
          end
          q.breakable("")
          q.text(")")
        end
      end

      def self.[](*alphabets)
        alphabets.reject { |alphabet| alphabet.is_a?(None) }.then do |compacted|
          compacted.one? ? compacted.first : new(alphabets: compacted)
        end
      end
    end

    # Matches nothing.
    class None
      def ==(other)
        other in None
      end

      def to_a
        []
      end

      def minimum
        MINIMUM
      end

      def maximum
        MAXIMUM
      end

      def pretty_print(q)
        q.text("(none)")
      end
    end

    # Matches against a range of characters.
    class Range
      attr_reader :from, :to

      def initialize(from:, to:)
        @from = from
        @to = to
      end

      def ==(other)
        other in Range[from: ^(from), to: ^(to)]
      end

      def to_a
        [self]
      end

      def deconstruct_keys(keys)
        { from: from, to: to }
      end

      alias minimum from
      alias maximum to

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

      def self.[](from, to)
        if to < from
          None.new
        elsif from < MINIMUM || to > MAXIMUM
          None.new
        elsif from == to
          Value.new(value: from)
        else
          new(from: from, to: to)
        end
      end
    end

    # Matches against a single value.
    class Value
      attr_reader :value

      def initialize(value:)
        @value = value
      end

      def ==(other)
        other in Value[value: ^(value)]
      end

      def to_a
        [self]
      end

      def deconstruct_keys(keys)
        { value: value }
      end

      alias minimum value
      alias maximum value

      def pretty_print(q)
        q.group do
          q.text("(value")
          q.nest(2) do
            q.breakable
            q.pp(value)
          end
          q.breakable("")
          q.text(")")
        end
      end

      def self.[](value)
        new(value: value)
      end
    end

    def self.sorted(left, right)
      [left, right].sort_by { |alphabet| [alphabet.class.name, alphabet.minimum, alphabet.maximum] }
    end

    def self.overlay(left, right)
      case sorted(left, right)
      in [Any, Any]
        # [.  .  .  .  .  .  .  .]
        # [.  .  .  .  .  .  .  .]
        # [.  .  .  .  .  .  .  .]
        Any.new
      in [Any, Multiple[alphabets:] => multiple]
        # [.  .  .  .  .  .  .  .]
        # [.]   [.  .]      [.]
        # [.][.][.  .][.  .][.][.]
        next_alphabets = [
          Range[MINIMUM, multiple.minimum - 1],
          multiple.alphabets.first
        ]

        alphabets.each_cons(2) do |(first, second)|
          next_alphabets << Range[first.maximum + 1, second.minimum - 1]
          next_alphabets << second
        end

        next_alphabets << Range[alphabets.last.maximum + 1, MAXIMUM]
        Multiple[*next_alphabets]
      in [Any, None]
        # [.  .  .  .  .  .  .  .]
        #
        # [.  .  .  .  .  .  .  .]
        Any.new
      in [Any, Range[from:, to:]]
        # [.  .  .  .  .  .  .  .]
        #             [.  .  .]
        # [.  .  .  .][.  .  .][.]
        Multiple[Range[MINIMUM, from - 1], Range[from, to], Range[to + 1, MAXIMUM]]
      in [Any, Value[value:]]
        # [.  .  .  .  .  .  .  .]
        #       [.]
        # [.  .][.][.  .  .  .  .]
        Multiple[Range[MINIMUM, value - 1], Value.new(value: value), Range[value + 1, MAXIMUM]]
      in [Multiple, Multiple]
        # [.]   [.  .]      [.]
        #    [.]   [.  .]      [.]
        # [.][.][.][.][.]   [.][.]
        raise NotImplementedError
      in [Multiple[alphabets:], None]
        # [.  .  .  .][.  .  .][.]
        #
        # [.  .  .  .][.  .  .][.]
        Multiple[*alphabets]
      in [Multiple[alphabets:], Range[from:, to:]]
        #    [.]   [.  .]      [.]
        # [.  .  .  .  .]
        # [.][.][.][.  .]      [.]
        before = []
        overlap = []
        after = []

        alphabets.each do |alphabet|
          if alphabet.maximum < from
            before << alphabet
          elsif alphabet.minimum > to
            after << alphabet
          else
            overlap << alphabet
          end
        end

        Multiple[
          *before,
          *overlap.inject(Range[from, to]) { |alphabet, overlapped| overlay(alphabet, overlapped) }.to_a,
          *after
        ]
      in [Multiple[alphabets:] => multiple, Value[value:]] if value < multiple.minimum
        #             [.  .  .][.]
        #       [.]
        #       [.]   [.  .  .][.]
        Multiple[Value[value], *alphabets]
      in [Multiple[alphabets:] => multiple, Value[value:]] if value > multiple.maximum
        #       [.  .  .][.]
        #                      [.]
        #       [.  .  .][.]   [.]
        Multiple[*alphabets, Value[value]]
      in [Multiple[alphabets:], Value[value:]]
        # [.  .  .  .][.  .  .][.]
        #       [.]
        # [.  .][.][.][.  .  .][.]
        index = -1
        matched =
          alphabets.detect do |alphabet|
            index += 1

            case alphabet
            in Range[from:, to:] if (from..to).cover?(value)
              true
            in Value[value: ^value]
              true
            in Range[from:] if from > value
              break
            in Value[value: other_value] if other_value > value
              break
            else
              false
            end
          end

        if matched
          Multiple[
            *alphabets[0...index],
            *overlay(alphabets[index], Value[value]),
            *alphabets[index + 1..-1]
          ]
        else
          Multiple[*alphabets[0...index], Value[value], *alphabets[index..-1]]
        end
      in [None, None]
        #
        #
        #
        None.new
      in [None, Range[from:, to:]]
        #
        #       [.  .  .]
        #       [.  .  .]
        Range[from, to]
      in [None, Value[value:]]
        #
        #       [.]
        #       [.]
        Value[value]
      in [Range[from: left_from, to: left_to], Range[from: right_from, to: right_to]] if right_from > left_to
        # [.  .  .]
        #          [.  .  .]
        # [.  .  .][.  .  .]
        Multiple[Range[left_from, left_to], Range[right_from, right_to]]
      in [Range[from: left_from, to: left_to], Range[from: right_from, to: right_to]] if right_to > left_to
        # [.  .  .]
        #       [.  .  .]
        # [.  .][.][.  .]
        Multiple[
          Range[left_from, right_from - 1],
          Range[right_from, left_to],
          Range[left_to + 1, right_to]
        ]
      in [Range[from: left_from, to: left_to], Range[from: right_from, to: right_to]]
        # [.  .  .  .  .  .]
        #       [.  .  .]
        # [.  .][.  .  .][.]
        Multiple[
          Range[left_from, right_from - 1],
          Range[right_from, right_to],
          Range[right_to + 1, left_to]
        ]
      in [Range[from:, to:], Value[value: ^from]]
        #       [.  .  .]
        #       [.]
        #       [.][.  .]
        Multiple[Value[from], Range[from + 1, to]]
      in [Range[from:, to:], Value[value: ^to]]
        #       [.  .  .]
        #             [.]
        #       [.  .][.]
        Multiple[Range[from, to - 1], Value[to]]
      in [Range[from:, to:], Value[value:]] if (from..to).cover?(value)
        #    [.  .  .  .]
        #          [.]
        #    [.  .][.][.]
        Multiple[Range[from, value - 1], Value[value], Range[value + 1, to]]
      in [Range[from:, to:], Value[value:]] if value < from
        #    [.  .  .  .]
        # [.]
        # [.][.  .  .  .]
        Multiple[Value[value], Range[from, to]]
      in [Range[from:, to:], Value[value:]] if value > to
        #    [.  .  .  .]
        #                [.]
        #    [.  .  .  .][.]
        Multiple[Range[from, to], Value[value]]
      in [Value[value:], Value[value: ^value]]
        #       [.]
        #       [.]
        #       [.]
        Value[value]
      in [Value[value: left_value], Value[value: right_value]]
        #       [.]
        #             [.]
        #       [.]   [.]
        Multiple[Value[left_value], Value[right_value]]
      end
    end

    def self.combine(left, right)
      case sorted(left, right)
      in [Any, _] | [_, Any]
        Any.new
      in [_, None]
        left
      in [None, _]
        right
      in [Multiple, Multiple]
        raise NotImplementedError
      in [Multiple[alphabets: [first, *rest]], Range[from:, to:]] if to < first.minimum
        Multiple[*combine(Range[from, to], first), *rest]
      in [Multiple[alphabets: [*rest, last]], Range[from:, to:]] if from > last.maximum
        Multiple[*rest, *combine(last, Range[from, to])]
      in [Multiple[alphabets:], Range[from:, to:]]
        (alphabets + [right]).sort_by(&:minimum).inject(None.new) do |result, alphabet|
          combine(result, alphabet)
        end
      in [Multiple[alphabets: [first, *rest]], Value[value:]] if value < first.minimum
        Multiple[*combine(Value[value], first), *rest]
      in [Multiple[alphabets: [*rest, last]], Value[value:]] if value > last.maximum
        Multiple[*rest, *combine(last, Value[value])]
      in [Multiple[alphabets:], Value[value:]]
        index = -1
        matched =
          alphabets.detect do |alphabet|
            index += 1

            case alphabet
            in Range[from:, to:] if (from..to).cover?(value)
              true
            in Value[value: ^value]
              true
            in Range[from:] if from > value
              break
            in Value[value: other_value] if other_value > value
              break
            else
              false
            end
          end

        if matched
          left
        else
          Multiple[*alphabets[0...index], Value[value], *alphabets[index..-1]]
        end
      in [Range[from: left_from, to: left_to], Range[from: ^(left_to + 1), to: right_to]]
        Range[left_from, right_to]
      in [Range[to: left_to], Range[from: right_from]] if left_to < right_from
        Multiple[left, right]
      in [Range[from:, to: left_to], Range[to: right_to]]
        Range[from, [left_to, right_to].max]
      in [Range[from:, to:], Value[value:]] if (from..to).cover?(value)
        left
      in [Range[from:, to:], Value[value: ^(from - 1)]]
        Range[from - 1, to]
      in [Range[from:, to:], Value[value: ^(to + 1)]]
        Range[from, to + 1]
      in [Range[from:, to:], Value[value:]] if value < from
        Multiple[Value[value], Range[from, to]]
      in [Range[from:, to:], Value[value:]] if value > to
        Multiple[Range[from, to], Value[value]]
      in [Value[value:], Value[value: ^value]]
        Value[value]
      in [Value[value:], Value[value: ^(value + 1)]]
        Range[value, value + 1]
      in [Value[value: left_value], Value[value: right_value]]
        Multiple[Value[left_value], Value[right_value]]
      end
    end
  end
end
