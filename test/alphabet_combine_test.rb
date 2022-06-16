# frozen_string_literal: true

require "test_helper"

module Exreg
  class AlphabetCombineTest < Minitest::Test
    def test_any_x_any
      left = Alphabet::Any.new
      right = Alphabet::Any.new

      assert_equal(Alphabet::Any.new, Alphabet.combine(left, right))
    end

    def test_any_x_multiple
      left = Alphabet::Any.new
      right = Alphabet::Multiple[
        Alphabet::Range[Alphabet::MINIMUM, 5],
        Alphabet::Value[7],
        Alphabet::Value[8]
      ]

      assert_equal(Alphabet::Any.new, Alphabet.combine(left, right))
    end

    def test_any_x_none
      left = Alphabet::Any.new
      right = Alphabet::None.new

      assert_equal(Alphabet::Any.new, Alphabet.combine(left, right))
    end

    def test_any_x_range
      left = Alphabet::Any.new
      right = Alphabet::Range[Alphabet::MINIMUM, 5]

      assert_equal(Alphabet::Any.new, Alphabet.combine(left, right))
    end

    def test_any_x_value
      left = Alphabet::Any.new
      right = Alphabet::Value[7]

      assert_equal(Alphabet::Any.new, Alphabet.combine(left, right))
    end

    def test_multiple_x_multiple
      skip
    end

    def test_multiple_x_none
      left = Alphabet::Multiple[
        Alphabet::Range[Alphabet::MINIMUM, 5],
        Alphabet::Value[7],
        Alphabet::Value[8]
      ]

      right = Alphabet::None.new

      assert_equal(left, Alphabet.combine(left, right))
    end

    def test_multiple_x_range_before
      left = Alphabet::Multiple[
        Alphabet::Range[7, 10],
        Alphabet::Value[15],
        Alphabet::Value[20]
      ]

      right = Alphabet::Range[3, 6]

      expected = Alphabet::Multiple[
        Alphabet::Range[3, 10],
        Alphabet::Value[15],
        Alphabet::Value[20]
      ]

      assert_equal(expected, Alphabet.combine(left, right))
    end

    def test_multiple_x_range_after
      left = Alphabet::Multiple[
        Alphabet::Range[7, 10],
        Alphabet::Value[15],
        Alphabet::Value[20]
      ]

      right = Alphabet::Range[21, 30]

      expected = Alphabet::Multiple[
        Alphabet::Range[7, 10],
        Alphabet::Value[15],
        Alphabet::Range[20, 30]
      ]

      assert_equal(expected, Alphabet.combine(left, right))
    end

    def test_multiple_x_range_overlap
      left = Alphabet::Multiple[
        Alphabet::Range[7, 10],
        Alphabet::Value[15],
        Alphabet::Value[20]
      ]

      right = Alphabet::Range[8, 18]

      expected = Alphabet::Multiple[
        Alphabet::Range[7, 18],
        Alphabet::Value[20]
      ]

      assert_equal(expected, Alphabet.combine(left, right))
    end

    def test_multiple_x_value_before
      left = Alphabet::Multiple[
        Alphabet::Range[5, 10],
        Alphabet::Value[15],
        Alphabet::Value[20]
      ]

      right = Alphabet::Value[3]

      expected = Alphabet::Multiple[
        Alphabet::Value[3],
        Alphabet::Range[5, 10],
        Alphabet::Value[15],
        Alphabet::Value[20]
      ]

      assert_equal(expected, Alphabet.combine(left, right))
    end

    def test_multiple_x_value_after
      left = Alphabet::Multiple[
        Alphabet::Value[3],
        Alphabet::Range[5, 10],
        Alphabet::Value[15]
      ]

      right = Alphabet::Value[20]

      expected = Alphabet::Multiple[
        Alphabet::Value[3],
        Alphabet::Range[5, 10],
        Alphabet::Value[15],
        Alphabet::Value[20]
      ]

      assert_equal(expected, Alphabet.combine(left, right))
    end

    def test_multiple_x_value_middle_no_overlap
      left = Alphabet::Multiple[
        Alphabet::Value[3],
        Alphabet::Value[15]
      ]

      right = Alphabet::Value[10]

      expected = Alphabet::Multiple[
        Alphabet::Value[3],
        Alphabet::Value[10],
        Alphabet::Value[15]
      ]

      assert_equal(expected, Alphabet.combine(left, right))
    end

    def test_multiple_x_value_middle_overlap
      left = Alphabet::Multiple[
        Alphabet::Value[3],
        Alphabet::Range[8, 12],
        Alphabet::Value[15]
      ]

      right = Alphabet::Value[11]

      expected = Alphabet::Multiple[
        Alphabet::Value[3],
        Alphabet::Range[8, 12],
        Alphabet::Value[15]
      ]

      assert_equal(expected, Alphabet.combine(left, right))
    end

    def test_none_x_none
      left = Alphabet::None.new
      right = Alphabet::None.new

      assert_equal(Alphabet::None.new, Alphabet.combine(left, right))
    end

    def test_none_x_range
      left = Alphabet::None.new
      right = Alphabet::Range[Alphabet::MINIMUM, 5]

      assert_equal(right, Alphabet.combine(left, right))
    end

    def test_none_x_value
      left = Alphabet::None.new
      right = Alphabet::Value[7]

      assert_equal(right, Alphabet.combine(left, right))
    end

    def test_range_x_range_no_overlap
      left = Alphabet::Range[5, 10]
      right = Alphabet::Range[12, 15]

      expected = Alphabet::Multiple[left, right]

      assert_equal(expected, Alphabet.combine(left, right))
    end

    def test_range_x_range_some_overlap
      left = Alphabet::Range[5, 10]
      right = Alphabet::Range[7, 15]

      expected = Alphabet::Range[5, 15]

      assert_equal(expected, Alphabet.combine(left, right))
    end

    def test_range_x_range_all_overlap
      left = Alphabet::Range[5, 10]
      right = Alphabet::Range[6, 8]

      expected = Alphabet::Range[5, 10]

      assert_equal(expected, Alphabet.combine(left, right))
    end

    def test_range_x_value_from
      left = Alphabet::Range[5, 10]
      right = Alphabet::Value[5]

      assert_equal(left, Alphabet.combine(left, right))
    end

    def test_range_x_value_to
      left = Alphabet::Range[5, 10]
      right = Alphabet::Value[10]

      assert_equal(left, Alphabet.combine(left, right))
    end

    def test_range_x_value_to_succ
      left = Alphabet::Range[5, 10]
      right = Alphabet::Value[11]

      expected = Alphabet::Range[5, 11]

      assert_equal(expected, Alphabet.combine(left, right))
    end

    def test_range_x_value_cover
      left = Alphabet::Range[5, 10]
      right = Alphabet::Value[7]

      assert_equal(left, Alphabet.combine(left, right))
    end

    def test_range_x_value_before
      left = Alphabet::Range[5, 10]
      right = Alphabet::Value[3]

      expected = Alphabet::Multiple[
        Alphabet::Value[3],
        Alphabet::Range[5, 10]
      ]

      assert_equal(expected, Alphabet.combine(left, right))
    end

    def test_range_x_value_after
      left = Alphabet::Range[5, 10]
      right = Alphabet::Value[13]

      expected = Alphabet::Multiple[
        Alphabet::Range[5, 10],
        Alphabet::Value[13]
      ]

      assert_equal(expected, Alphabet.combine(left, right))
    end

    def test_value_x_value_equal
      left = Alphabet::Value[7]
      right = Alphabet::Value[7]

      assert_equal(left, Alphabet.combine(left, right))
    end

    def test_value_x_value_not_equal
      left = Alphabet::Value[7]
      right = Alphabet::Value[8]

      expected = Alphabet::Range[7, 8]

      assert_equal(expected, Alphabet.combine(left, right))
    end
  end
end
