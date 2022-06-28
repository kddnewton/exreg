# frozen_string_literal: true

require "test_helper"

module Exreg
  class PatternTest < Minitest::Test
    def test_alternation
      assert_matches("a|b", "xxx a xxx")
      assert_matches("a|b", "xxx b xxx")
    end

    def test_concatenation
      assert_matches("ab", "xxx ab xxx")
    end

    def test_group
      assert_matches("a(b|c)", "ab")
      assert_matches("a(b|c)", "ac")
    end

    def test_match_any
      assert_matches(".", "a")
      assert_matches(".", "b")
      assert_matches(".", "c")
    end

    def test_match_class
      assert_matches("\\d", "1")
      assert_matches("\\d", "9")
      refute_matches("\\d", "a")

      assert_matches("\\h", "1")
      assert_matches("\\h", "a")
      refute_matches("\\h", "x")

      assert_matches("\\s", " ")
      assert_matches("\\s", "\t")
      refute_matches("\\s", "a")

      assert_matches("\\w", "1")
      assert_matches("\\w", "a")
      refute_matches("\\w", "-")
    end

    def test_match_property
      assert_matches("\\p{Math}", "+")
    end

    def test_optional_quantifier
      assert_matches("a?", "")
      assert_matches("a?", "a")
    end

    def test_range_quantifier_single
      assert_matches("a{3}", "xxx aaa xxx")
    end

    def test_range_quantifier_endless
      assert_matches("a{3,}", "xxx aaa xxx")
      assert_matches("a{3,}", "xxx aaaa xxx")
      assert_matches("a{3,}", "xxx aaaaa xxx")
    end

    def test_range_quantifier_beginless
      assert_matches("a{,3}", "xxx  xxx")
      assert_matches("a{,3}", "xxx a xxx")
      assert_matches("a{,3}", "xxx aa xxx")
      assert_matches("a{,3}", "xxx aaa xxx")
    end

    def test_range_quantifier_range
      assert_matches("a{3,5}", "xxx aaa xxx")
      assert_matches("a{3,5}", "xxx aaaa xxx")
      assert_matches("a{3,5}", "xxx aaaaa xxx")
    end

    def test_range_quantifier_invalid
      assert_matches("a{ 3}", "xxx a{ 3} xxx")
    end

    def test_star_quantifier
      assert_matches("a*", "xxx  xxx")
      assert_matches("a*", "xxx a xxx")
      assert_matches("a*", "xxx aa xxx")
      assert_matches("a*", "xxx aaa xxx")
    end

    def test_plus_quantifier
      assert_matches("a+", "xxx a xxx")
      assert_matches("a+", "xxx aa xxx")
      assert_matches("a+", "xxx aaa xxx")
    end

    private

    def assert_matches(source, string)
      check_matches(:assert, source, string)
    end

    def refute_matches(source, string)
      check_matches(:refute, source, string)
    end

    def check_matches(predicate, source, string)
      pattern = Pattern.new(source)

      # Exercise the pretty-print here just to get some extra coverage. Really
      # this should be its own test.
      PP.pp(pattern.ast, +"")

      public_send(predicate, /#{source}/.match?(string))
      public_send(predicate, pattern.nfa.match?(string))
      public_send(predicate, pattern.dfa.match?(string))
      public_send(predicate, pattern.bytecode.match?(string))
      public_send(predicate, pattern.match?(string))
    end
  end
end
