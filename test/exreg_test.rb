# frozen_string_literal: true

require "exreg"
require "minitest/autorun"

module Exreg
  class ExregTest < Minitest::Test
    private

    def assert_match(pattern, string, options = Option::NONE)
      assert_operator(Pattern.new(pattern, options), :match, string) { "Expected '#{string}' to match pattern '#{pattern}'" }
      assert_operator(Regexp.new("(?u)#{pattern}", options), :match, string) { "Expected '#{string}' to match pattern '#{pattern}'" }
    end

    def refute_match(pattern, string, options = Option::NONE)
      refute_operator(Pattern.new(pattern, options), :match, string, "Expected '#{string}' not to match pattern '#{pattern}'")
      refute_operator(Regexp.new("(?u)#{pattern}", options), :match, string, "Expected '#{string}' not to match pattern '#{pattern}'")
    end
  end

  class PatternTest < ExregTest
    def test_basic
      match = Pattern.new("[a-c]{3}").match("abc")

      refute_nil(match)
      assert_equal("abc", match[0])
    end
  end

  class ByteSetTest < ExregTest
    def test_invert
      set = ByteSet[65..200]

      inverted = set.invert
      refute(inverted.has?(65))
      refute(inverted.has?(200))
      assert(inverted.has?(64))
      assert(inverted.has?(201))
    end

    def test_add_byte_range
      set = ByteSet[40..205]

      (40..205).each do |byte|
        assert(set.has?(byte))
      end

      refute(set.has?(39))
      refute(set.has?(206))
    end

    def test_equality
      set1 = ByteSet[65..200]
      set2 = ByteSet[65..200]
      set3 = ByteSet[65..201]

      assert_equal(set1, set2)
      refute_equal(set1, set3)
    end

    def test_hash_consistency
      set1 = ByteSet[65..200]
      set2 = ByteSet[65..200]
      set3 = ByteSet[65..201]

      assert_equal(set1.hash, set2.hash)
      refute_equal(set1.hash, set3.hash)
    end

    def test_deduplication_in_set
      set1 = ByteSet[65..200]
      set2 = ByteSet[65..200]
      set3 = ByteSet[65..201]

      result_set = Set.new([set1, set2, set3])
      assert_equal(2, result_set.size)
    end

    def test_as_hash_key
      set1 = ByteSet[65..200]
      set2 = ByteSet[65..200]

      hash = { set1 => "first" }
      hash[set2] = "second"

      assert_equal(1, hash.size)
      assert_equal("second", hash[set1])
    end
  end

  class USetTest < ExregTest
    def test_basic
      set = USet["A".ord.."Z".ord, "a".ord.."z".ord, "0".ord.."9".ord]

      assert_operator(set, :has?, "A".ord)
      assert_operator(set, :has?, "M".ord)
      assert_operator(set, :has?, "Z".ord)
      assert_operator(set, :has?, "a".ord)
      assert_operator(set, :has?, "m".ord)
      assert_operator(set, :has?, "z".ord)
      assert_operator(set, :has?, "0".ord)
      assert_operator(set, :has?, "5".ord)
      assert_operator(set, :has?, "9".ord)
      refute_operator(set, :has?, "@".ord)
    end

    def test_invert
      set = USet["A".ord.."Z".ord].invert

      assert_operator(set, :has?, "@".ord)
      refute_operator(set, :has?, "A".ord)
      refute_operator(set, :has?, "M".ord)
    end

    def test_union
      set1 = USet["A".ord.."Z".ord]
      set2 = USet["a".ord.."z".ord]
      set3 = set1 | set2

      assert_operator(set3, :has?, "A".ord)
      assert_operator(set3, :has?, "M".ord)
      assert_operator(set3, :has?, "Z".ord)
      assert_operator(set3, :has?, "a".ord)
      assert_operator(set3, :has?, "m".ord)
      assert_operator(set3, :has?, "z".ord)
      refute_operator(set3, :has?, "0".ord)
    end

    def test_intersection
      set1 = USet["A".ord.."X".ord]
      set2 = USet["M".ord.."Z".ord]
      set3 = set1 & set2

      assert_operator(set3, :has?, "M".ord)
      assert_operator(set3, :has?, "X".ord)
      refute_operator(set3, :has?, "L".ord)
      refute_operator(set3, :has?, "Y".ord)
    end

    def test_difference
      set1 = USet["A".ord.."X".ord]
      set2 = USet["M".ord.."Z".ord]
      set3 = set1 - set2

      assert_operator(set3, :has?, "A".ord)
      assert_operator(set3, :has?, "L".ord)
      refute_operator(set3, :has?, "M".ord)
      refute_operator(set3, :has?, "Z".ord)
    end
  end

  class PatternTest < ExregTest
    def test_character
      assert_match("a", "a")
      assert_match("a", "xa")
      assert_match("a", "ax")
      refute_match("a", "b")
      refute_match("a", "")
    end

    def test_escapes
      assert_match("\\t", "\t")
      assert_match("\\v", "\v")
      assert_match("\\n", "\n")
      assert_match("\\r", "\r")
      assert_match("\\f", "\f")
      assert_match("\\a", "\a")
      assert_match("\\e", "\e")
      assert_match("\\123", "\123")
      assert_match("\\x7F", "\x7F")
    end

    def test_string
      assert_match("abc", "xabcx")
      assert_match("abc", "123abc")
      refute_match("abc", "ab")
      refute_match("abc", "a")
      refute_match("abc", "bc")
      refute_match("abc", "abdc")
    end

    def test_any
      assert_match(".", "a")
      assert_match(".", "1")
      assert_match(".", "#")
      refute_match(".", "")
    end

    def test_combined_any
      assert_match("a.c", "abc")
      assert_match("a.c", "a1c")
      assert_match("a.c", "a c")
      refute_match("a.c", "ac")
      refute_match("a.c", "ab")
      refute_match("a.c", "a")
    end

    def test_optional
      assert_match("a?b", "ab")
      assert_match("a?b", "aab")
      assert_match("a?b", "b")
      assert_match("a?b", "aaab")
      assert_match("a?b", "ba")
      assert_match("a?b", "bb")
      refute_match("a?b", "a")
    end

    def test_star
      assert_match("ab*", "a")
      assert_match("ab*", "ab")
      assert_match("ab*", "abbb")
      assert_match("ab*", "xabx")
      refute_match("ab*", "c")
      refute_match("ab*", "bbb")
    end

    def test_plus
      assert_match("ab+", "ab")
      assert_match("ab+", "abb")
      assert_match("ab+", "zabzz")
      refute_match("ab+", "a")
      refute_match("ab+", "b")
      refute_match("ab+", "zaz")
    end

    def test_plus_with_class
      pattern = Pattern.new("\\w+")
      match = pattern.match("  hello123  ")
      assert_equal("hello123", match[0])
    end

    def test_star_with_class
      # Test * quantifier (0 or more) with character classes
      # Note: [a-z]* matches empty string at start, need actual pattern
      pattern = Pattern.new("\\s*\\w+")
      match = pattern.match("  hello123  ")
      assert_equal("  hello123", match[0])
      
      # Star should match empty string
      match = Pattern.new("[a-z]*").match("123")
      assert_equal("", match[0])
      
      # Star matches zero at the start position - use + for actual digits
      match = Pattern.new("\\d+").match("123xyz")
      assert_equal("123", match[0])
    end

    def test_optional_with_class
      # Test ? quantifier (0 or 1) with character classes
      assert_match("[a-z]?b", "ab")
      assert_match("[a-z]?b", "b")
      assert_match("[a-z]?b", "xb")
      
      # Optional with lookahead for specific position
      match = Pattern.new("x\\d?").match("x5y")
      assert_equal("x5", match[0])
    end

    def test_range_quantifier_exact
      # Test {n} exact repetition
      pattern = Pattern.new("[a-z]{5}")
      match = pattern.match("  hello  ")
      assert_equal("hello", match[0])
      
      match = Pattern.new("\\d{3}").match("abc12345xyz")
      assert_equal("123", match[0])
      
      refute_match("[a-z]{5}", "hi")
    end

    def test_range_quantifier_min
      # Test {n,} minimum repetition (greedy)
      pattern = Pattern.new("[a-z]{3,}")
      match = pattern.match("  hello  ")
      assert_equal("hello", match[0])
      
      match = Pattern.new("\\d{2,}").match("abc12345xyz")
      assert_equal("12345", match[0])
      
      refute_match("[a-z]{3,}", "hi")
    end

    def test_range_quantifier_min_max
      # Test {n,m} bounded repetition (greedy)
      pattern = Pattern.new("[a-z]{2,4}")
      match = pattern.match("  hello  ")
      assert_equal("hell", match[0]) # Should match max 4
      
      match = Pattern.new("\\d{1,3}").match("abc12345xyz")
      assert_equal("123", match[0]) # Should match max 3
      
      match = Pattern.new("[a-z]{2,4}").match("  hi  ")
      assert_equal("hi", match[0]) # Should match min 2
    end

    def test_star_greedy
      # Test that * is greedy (matches as much as possible)
      pattern = Pattern.new("a[a-z]*")
      match = pattern.match("abcdef123")
      assert_equal("abcdef", match[0])
      
      # Should match entire word from start
      match = Pattern.new("w\\w*").match("word_123")
      assert_equal("word_123", match[0])
    end

    def test_plus_greedy
      # Test that + is greedy (matches as much as possible)
      pattern = Pattern.new("[a-z]+")
      match = pattern.match("abcdef123")
      assert_equal("abcdef", match[0])
      
      # Should match entire sequence
      match = Pattern.new("\\d+").match("abc12345xyz")
      assert_equal("12345", match[0])
    end

    def test_quantifiers_in_middle_of_string
      # Test quantifiers match correctly in middle of string
      pattern = Pattern.new("[a-z]+")
      match = pattern.match("123abc456")
      assert_equal("abc", match[0])
      
      pattern = Pattern.new("\\d+")
      match = pattern.match("xyz789end")
      assert_equal("789", match[0])
    end

    def test_nested_quantifiers
      skip "failing"
      # Test quantifiers with grouped patterns
      pattern = Pattern.new("(?:[a-z]{2})+")
      match = pattern.match("  aabbccdd  ")
      assert_equal("aabbccdd", match[0])
      
      pattern = Pattern.new("(?:\\d{3})*")
      match = pattern.match("123456789")
      assert_equal("123456789", match[0])
    end

    def test_quantifiers_with_anchors
      # Test quantifiers work with anchors
      assert_match("\\A[a-z]+\\z", "hello")
      refute_match("\\A[a-z]+\\z", "hello123")
      
      assert_match("\\A\\d+\\z", "12345")
      refute_match("\\A\\d+\\z", "abc123")
    end

    def test_alternation_simple
      assert_match("a|b", "a")
      assert_match("a|b", "b")
      assert_match("a|b", "xa")
      assert_match("a|b", "bx")
      refute_match("a|b", "ccc")
    end

    def test_alternation_empty_lhs
      assert_match("|a", "a")
      assert_match("|a", "")
      assert_match("|a", "zzz")
    end

    def test_alternation_empty_rhs
      assert_match("a|", "a")
      assert_match("a|", "")
      assert_match("a|", "zzz")
    end

    def test_alternation_both_empty
      assert_match("||", "")
      assert_match("||", "hello")
    end

    def test_alternation_concat_precedence
      assert_match("ab|cd", "ab")
      assert_match("ab|cd", "cd")
      assert_match("ab|cd", "zabz")
      assert_match("ab|cd", "xcdx")
      refute_match("ab|cd", "ac")
      refute_match("ab|cd", "ad")
    end

    def test_alternation_with_quantifier
      assert_match("a|b*", "a")
      assert_match("a|b*", "bbb")
      assert_match("a|b*", "ccc")
    end

    def test_atomic_group_prevents_backtracking
      refute_match("(?>a*)a", "aaa")
      assert_match("(?:a*)a", "aaa")
    end

    def test_atomic_group_alternation
      refute_match("(?>ab|a)b", "ab")
      assert_match("(?:ab|a)b", "ab")
    end

    def test_star_empty
      assert_match("b*", "")
    end

    def test_begin_anchor
      assert_match("\\Aabc", "abc")
      refute_match("\\Aabc", "xabc")
      assert_match("\\A", "hello")
      assert_match("\\A", "")
    end

    def test_end_anchor
      assert_match("abc\\z", "abc")
      refute_match("abc\\z", "abcc")
      assert_match("\\z", "")
      assert_match("\\z", "world")
    end

    def test_end_anchor_with_newline
      assert_match("abc\\Z", "abc")
      assert_match("abc\\Z", "abc\n")
      refute_match("abc\\Z", "abcc")
      assert_match("\\Z", "")
      assert_match("\\Z", "hello")
    end

    def test_both_anchors
      assert_match("\\A\\z", "")
      refute_match("\\A\\z", "a")
    end

    def test_multibyte_characters
      assert_match("あい", "あい")
      assert_match("あい", "うあいえ")
      refute_match("あい", "あ")
      refute_match("あい", "い")
      refute_match("あい", "あうい")
    end

    def test_character_set_basic
      assert_match("[abc]", "a")
      assert_match("[abc]", "xb")
      assert_match("[abc]", "zc")
      refute_match("[abc]", "d")
      refute_match("[abc]", "")
    end

    def test_character_set_invert
      assert_match("[^abc]", "d")
      refute_match("[^abc]", "a")
    end

    def test_character_set_with_escape
      assert_match("[\\]]", "]")
      assert_match("[\\[]", "[")
      assert_match("[\\\\]", "\\")
    end

    def test_character_set_escape_sequences
      # Horizontal tab
      assert_match("[\\t]", "\t")
      refute_match("[\\t]", "t")
      refute_match("[\\t]", " ")

      # Vertical tab
      assert_match("[\\v]", "\v")
      refute_match("[\\v]", "v")

      # Newline
      assert_match("[\\n]", "\n")
      refute_match("[\\n]", "n")

      # Carriage return
      assert_match("[\\r]", "\r")
      refute_match("[\\r]", "r")

      # Backspace
      assert_match("[\\b]", "\b")
      refute_match("[\\b]", "b")

      # Form feed
      assert_match("[\\f]", "\f")
      refute_match("[\\f]", "f")

      # Bell
      assert_match("[\\a]", "\a")
      refute_match("[\\a]", "a")

      # Escape
      assert_match("[\\e]", "\e")
      refute_match("[\\e]", "e")

      # Multiple escapes in a set
      assert_match("[\\t\\n\\r]", "\t")
      assert_match("[\\t\\n\\r]", "\n")
      assert_match("[\\t\\n\\r]", "\r")
      refute_match("[\\t\\n\\r]", " ")
    end

    def test_character_set_octal_escapes
      # Octal escape for tab (011 = 0x09)
      assert_match("[\\011]", "\t")
      refute_match("[\\011]", "0")

      # Octal escape for newline (012 = 0x0A)
      assert_match("[\\012]", "\n")
      refute_match("[\\012]", "1")

      # Octal escape for bell (007 = 0x07)
      assert_match("[\\007]", "\a")
      refute_match("[\\007]", "7")

      # Single digit octal
      assert_match("[\\7]", "\a")
      refute_match("[\\7]", "7")

      # Two digit octal
      assert_match("[\\12]", "\n")
      refute_match("[\\12]", "n")

      # Multiple octal escapes in a set
      assert_match("[\\011\\012\\015]", "\t")
      assert_match("[\\011\\012\\015]", "\n")
      assert_match("[\\011\\012\\015]", "\r")
      refute_match("[\\011\\012\\015]", " ")
    end

    def test_character_set_hex_escapes
      # Hexadecimal escape for tab (x09 = 0x09)
      assert_match("[\\x09]", "\t")
      refute_match("[\\x09]", "0")

      # Hexadecimal escape for newline (x0A = 0x0A)
      assert_match("[\\x0A]", "\n")
      refute_match("[\\x0A]", "A")

      # Hexadecimal escape for bell (x07 = 0x07)
      assert_match("[\\x07]", "\a")
      refute_match("[\\x07]", "7")

      # Uppercase hex digits
      assert_match("[\\x0F]", "\x0F")
      refute_match("[\\x0F]", "F")

      # Multiple hex escapes in a set
      assert_match("[\\x09\\x0A\\x0D]", "\t")
      assert_match("[\\x09\\x0A\\x0D]", "\n")
      assert_match("[\\x09\\x0A\\x0D]", "\r")
      refute_match("[\\x09\\x0A\\x0D]", " ")

      # Mix octal and hex
      assert_match("[\\011\\x0A]", "\t")
      assert_match("[\\011\\x0A]", "\n")
      refute_match("[\\011\\x0A]", "\r")
    end

    def test_character_set_unicode_escapes
      # Unicode escape \uHHHH for tab (u0009)
      assert_match("[\\u0009]", "\t")
      refute_match("[\\u0009]", "t")

      # Unicode escape for newline (u000A)
      assert_match("[\\u000A]", "\n")
      refute_match("[\\u000A]", "n")

      # Unicode escape for é (u00E9)
      assert_match("[\\u00E9]", "é")
      refute_match("[\\u00E9]", "e")

      # Unicode escape for emoji (u263A)
      assert_match("[\\u263A]", "☺")
      refute_match("[\\u263A]", "A")

      # Multiple Unicode escapes in a set
      assert_match("[\\u0009\\u000A\\u000D]", "\t")
      assert_match("[\\u0009\\u000A\\u000D]", "\n")
      assert_match("[\\u0009\\u000A\\u000D]", "\r")
      refute_match("[\\u0009\\u000A\\u000D]", " ")

      # Mix Unicode, hex, and octal
      assert_match("[\\u0009\\x0A\\015]", "\t")
      assert_match("[\\u0009\\x0A\\015]", "\n")
      assert_match("[\\u0009\\x0A\\015]", "\r")
      refute_match("[\\u0009\\x0A\\015]", " ")
    end

    def test_character_set_combined
      assert_match("x[ab]y", "xay")
      assert_match("x[ab]y", "xby")
      refute_match("x[ab]y", "xcy")
    end

    def test_character_set_advanced
      assert_match("[a-c]", "b")
      refute_match("[a-c]", "d")

      assert_match("[a[b-d]]", "c")
      refute_match("[a[b-d]]", "e")

      assert_match("[^a-c]", "z")
      refute_match("[^a-c]", "b")

      pattern = "[a-d&&[c-f]]"
      assert_match(pattern, "c")
      refute_match(pattern, "b")

      pattern = "[a-z&&[^aeiou]]"
      assert_match(pattern, "b")
      refute_match(pattern, "a")

      assert_match("[-a]", "-")
      assert_match("[-a]", "a")
      refute_match("[-a]", "b")

      pattern = "[[a-f]&&[d-z]]"
      assert_match(pattern, "e")
      refute_match(pattern, "b")
    end

    def test_character_set_posix_ascii
      pattern = "[[:ascii:]]"
      assert_match(pattern, "A")
      refute_match(pattern, "😀")

      pattern = "[^[:ascii:]]"
      assert_match(pattern, "😀")
      refute_match(pattern, "A")

      pattern = "[[:ascii:]&&[A-Z]]"
      assert_match(pattern, "G")
      refute_match(pattern, "é")

      pattern = "[[:ascii:]&&[^A-Z]]"
      assert_match(pattern, "9")
      refute_match(pattern, "Z")
    end

    def test_character_set_posix_blank
      pattern = "[[:blank:]]"
      assert_match(pattern, "\t")
      assert_match(pattern, " ")
      assert_match(pattern, "\u00A0")
      refute_match(pattern, "\n")
      refute_match(pattern, "A")

      pattern = "[^[:blank:]]"
      assert_match(pattern, "A")
      refute_match(pattern, " ")

      pattern = "[[:blank:]&&[:ascii:]]"
      assert_match(pattern, "\t")
      assert_match(pattern, " ")
      refute_match(pattern, "\u00A0")
    end

    def test_character_set_posix_cntrl
      pattern = "[[:cntrl:]]"
      assert_match(pattern, "\u0000")
      assert_match(pattern, "\u0085")
      refute_match(pattern, "A")
      refute_match(pattern, " ")

      pattern = "[^[:cntrl:]]"
      assert_match(pattern, "A")
      refute_match(pattern, "\u0000")

      pattern = "[[:cntrl:]&&[:ascii:]]"
      assert_match(pattern, "\u0007")
      refute_match(pattern, "\u200E")
    end

    def test_character_set_posix_digit
      pattern = "[[:digit:]]"
      assert_match(pattern, "5")
      assert_match(pattern, "\u0662") # Arabic-Indic ٢
      refute_match(pattern, "A")

      pattern = "[^[:digit:]]"
      assert_match(pattern, "A")
      refute_match(pattern, "3")

      pattern = "[[:digit:]&&[:ascii:]]"
      assert_match(pattern, "7")
      refute_match(pattern, "\u0662")
    end

    def test_character_set_posix_alpha
      pattern = "[[:alpha:]]"
      assert_match(pattern, "A")
      assert_match(pattern, "z")
      assert_match(pattern, "\u00E9") # é
      assert_match(pattern, "\u2160") # Roman numeral one
      refute_match(pattern, "1")
      refute_match(pattern, " ")

      pattern = "[[:alpha:]&&[:ascii:]]"
      assert_match(pattern, "G")
      refute_match(pattern, "\u00E9")
      refute_match(pattern, "\u0301")
    end

    def test_character_set_posix_upper
      pattern = "[[:upper:]]"
      assert_match(pattern, "A")
      assert_match(pattern, "Z")
      assert_match(pattern, "\u00C9") # É
      refute_match(pattern, "a")
      refute_match(pattern, "z")
      refute_match(pattern, "1")

      pattern = "[[:upper:]&&[:ascii:]]"
      assert_match(pattern, "G")
      refute_match(pattern, "\u00C9")
      refute_match(pattern, "a")
    end

    def test_character_set_posix_lower
      pattern = "[[:lower:]]"
      assert_match(pattern, "a")
      assert_match(pattern, "z")
      assert_match(pattern, "\u00E9") # é
      refute_match(pattern, "A")
      refute_match(pattern, "Z")
      refute_match(pattern, "1")

      pattern = "[[:lower:]&&[:ascii:]]"
      assert_match(pattern, "g")
      refute_match(pattern, "\u00E9")
      refute_match(pattern, "A")
    end

    def test_character_set_posix_space
      pattern = "[[:space:]]"
      assert_match(pattern, " ")
      assert_match(pattern, "\t")
      assert_match(pattern, "\n")
      assert_match(pattern, "\u00A0")
      assert_match(pattern, "\u2028") # line separator
      assert_match(pattern, "\u2029") # paragraph separator
      refute_match(pattern, "A")
      refute_match(pattern, "1")

      pattern = "[[:space:]&&[:ascii:]]"
      assert_match(pattern, "\t")
      assert_match(pattern, "\n")
      refute_match(pattern, "\u00A0")
      refute_match(pattern, "\u2028")
    end

    def test_character_set_posix_alnum
      pattern = "[[:alnum:]]"
      assert_match(pattern, "A")
      assert_match(pattern, "z")
      assert_match(pattern, "5")
      assert_match(pattern, "\u00E9") # é
      assert_match(pattern, "\u2160") # Roman numeral one
      refute_match(pattern, "-")
      refute_match(pattern, " ")

      pattern = "[[:alnum:]&&[:ascii:]]"
      assert_match(pattern, "G")
      assert_match(pattern, "7")
      refute_match(pattern, "\u00E9")
      refute_match(pattern, "\u0301")
    end

    def test_character_set_posix_graph
      pattern = "[[:graph:]]"
      assert_match(pattern, "A")
      assert_match(pattern, "9")
      assert_match(pattern, "!")
      assert_match(pattern, "\u00E9")
      assert_match(pattern, "\u0301") # combining mark
      refute_match(pattern, " ")
      refute_match(pattern, "\n")
      refute_match(pattern, "\u0000")
      refute_match(pattern, "\u0378") # unassigned

      pattern = "[[:graph:]&&[:ascii:]]"
      assert_match(pattern, "!")
      assert_match(pattern, "A")
      refute_match(pattern, " ")
      refute_match(pattern, "\n")
    end

    def test_character_set_posix_punct
      pattern = "[[:punct:]]"
      assert_match(pattern, "!")
      assert_match(pattern, "?")
      assert_match(pattern, "-")
      assert_match(pattern, "$")
      assert_match(pattern, "|")
      refute_match(pattern, "A")
      refute_match(pattern, "1")
      refute_match(pattern, " ")

      pattern = "[[:punct:]&&[:ascii:]]"
      assert_match(pattern, "!")
      assert_match(pattern, "$")
      refute_match(pattern, "\u2014") # em dash, non-ASCII
    end

    def test_character_set_posix_xdigit
      pattern = "[[:xdigit:]]"
      # Digits 0-9
      assert_match(pattern, "0")
      assert_match(pattern, "5")
      assert_match(pattern, "9")
      # Uppercase hex A-F
      assert_match(pattern, "A")
      assert_match(pattern, "C")
      assert_match(pattern, "F")
      # Lowercase hex a-f
      assert_match(pattern, "a")
      assert_match(pattern, "c")
      assert_match(pattern, "f")
      # Non-hex characters
      refute_match(pattern, "G")
      refute_match(pattern, "g")
      refute_match(pattern, "Z")
      refute_match(pattern, "z")
      refute_match(pattern, " ")
      refute_match(pattern, "-")

      # Inverted xdigit
      pattern = "[^[:xdigit:]]"
      assert_match(pattern, "G")
      assert_match(pattern, "g")
      assert_match(pattern, " ")
      refute_match(pattern, "0")
      refute_match(pattern, "5")
      refute_match(pattern, "A")
      refute_match(pattern, "f")

      # Intersection with ASCII
      pattern = "[[:xdigit:]&&[:ascii:]]"
      assert_match(pattern, "0")
      assert_match(pattern, "F")
      assert_match(pattern, "f")
      refute_match(pattern, "G")
    end

    def test_character_set_posix_word
      pattern = "[[:word:]]"
      # Letters
      assert_match(pattern, "A")
      assert_match(pattern, "a")
      assert_match(pattern, "Z")
      assert_match(pattern, "z")
      assert_match(pattern, "\u00E9") # é (letter)
      # Digits
      assert_match(pattern, "0")
      assert_match(pattern, "5")
      assert_match(pattern, "9")
      # Marks (including combining marks)
      assert_match(pattern, "\u0301") # combining acute
      # Connector Punctuation (underscore)
      assert_match(pattern, "_")
      # Non-word characters
      refute_match(pattern, " ")
      refute_match(pattern, "-")
      refute_match(pattern, "!")
      refute_match(pattern, ".")
      refute_match(pattern, "\n")

      # Inverted word
      pattern = "[^[:word:]]"
      assert_match(pattern, " ")
      assert_match(pattern, "-")
      assert_match(pattern, "!")
      assert_match(pattern, ".")
      refute_match(pattern, "A")
      refute_match(pattern, "5")
      refute_match(pattern, "_")

      # Intersection with ASCII
      pattern = "[[:word:]&&[:ascii:]]"
      assert_match(pattern, "A")
      assert_match(pattern, "a")
      assert_match(pattern, "0")
      assert_match(pattern, "_")
      refute_match(pattern, "\u00E9")
      refute_match(pattern, " ")
      refute_match(pattern, "-")
    end

    def test_character_set_posix_print
      pattern = "[[:print:]]"
      # Graph characters (letters, punctuation, symbols, digits)
      assert_match(pattern, "A")
      assert_match(pattern, "a")
      assert_match(pattern, "0")
      assert_match(pattern, "!")
      assert_match(pattern, "\u00E9") # é
      # Space Separator characters
      assert_match(pattern, " ")
      assert_match(pattern, "\u00A0") # non-breaking space
      # Combining marks (part of graph)
      assert_match(pattern, "\u0301") # combining acute
      # Non-printable characters
      refute_match(pattern, "\n")
      refute_match(pattern, "\t")
      refute_match(pattern, "\u0000") # null
      refute_match(pattern, "\u0378") # unassigned

      # Inverted print
      pattern = "[^[:print:]]"
      assert_match(pattern, "\n")
      assert_match(pattern, "\t")
      assert_match(pattern, "\u0000")
      refute_match(pattern, "A")
      refute_match(pattern, " ")
      refute_match(pattern, "!")

      # Intersection with ASCII
      pattern = "[[:print:]&&[:ascii:]]"
      assert_match(pattern, "A")
      assert_match(pattern, "a")
      assert_match(pattern, "0")
      assert_match(pattern, "!")
      assert_match(pattern, " ")
      refute_match(pattern, "\u00E9")
      refute_match(pattern, "\u00A0")
      refute_match(pattern, "\n")
      refute_match(pattern, "\t")

      # Print includes graph
      pattern = "[[:print:]]"
      assert_match(pattern, "x") # from graph
      assert_match(pattern, " ") # space (only difference from graph)
    end

    def test_unicode_property_lowercase_letter
      # \p{Lowercase_Letter} matches lowercase letters
      assert_match("\\p{Lowercase_Letter}", "a")
      assert_match("\\p{Lowercase_Letter}", "z")
      assert_match("\\p{Lowercase_Letter}", "\u00E9") # é
      refute_match("\\p{Lowercase_Letter}", "A")
      refute_match("\\p{Lowercase_Letter}", "Z")
      refute_match("\\p{Lowercase_Letter}", "0")
      refute_match("\\p{Lowercase_Letter}", " ")

      # \P{Lowercase_Letter} (inverted) does not match lowercase letters
      assert_match("\\P{Lowercase_Letter}", "A")
      assert_match("\\P{Lowercase_Letter}", "0")
      assert_match("\\P{Lowercase_Letter}", " ")
      refute_match("\\P{Lowercase_Letter}", "a")
      refute_match("\\P{Lowercase_Letter}", "z")

      # \p{^Lowercase_Letter} (with ^) also inverts
      assert_match("\\p{^Lowercase_Letter}", "A")
      assert_match("\\p{^Lowercase_Letter}", "0")
      assert_match("\\p{^Lowercase_Letter}", " ")
      refute_match("\\p{^Lowercase_Letter}", "a")
      refute_match("\\p{^Lowercase_Letter}", "z")

      # Multiple occurrences
      assert_match("\\p{Lowercase_Letter}\\p{Lowercase_Letter}", "ab")
      refute_match("\\p{Lowercase_Letter}\\p{Lowercase_Letter}", "aB")
      refute_match("\\p{Lowercase_Letter}\\p{Lowercase_Letter}", "12")

      # In character classes
      assert_match("[\\p{Lowercase_Letter}]", "a")
      assert_match("[\\p{Lowercase_Letter}]", "z")
      refute_match("[\\p{Lowercase_Letter}]", "A")

      # Negated in character classes
      assert_match("[^\\p{Lowercase_Letter}]", "A")
      assert_match("[^\\p{Lowercase_Letter}]", "0")
      refute_match("[^\\p{Lowercase_Letter}]", "a")
    end

    def test_character_set_quantifiers
      assert_match("[ab]*", "")
      assert_match("[ab]*", "abba")
      assert_match("[ab]*", "abc")

      assert_match("[ab]+", "a")
      assert_match("[ab]+", "b")
      assert_match("[ab]+", "ab")
      assert_match("[ab]+", "ba")
      refute_match("[ab]+", "")
    end

    def test_character_set_alternation
      assert_match("[ab]|c", "a")
      assert_match("[ab]|c", "c")
      refute_match("[ab]|c", "d")
    end

    def test_noncapturing_group_basic
      assert_match("(?:ab)", "ab")
      assert_match("x(?:ab)y", "xaby")
      refute_match("(?:ab)", "a")
    end

    def test_noncapturing_group_with_quantifier
      assert_match("(?:ab)+", "ab")
      assert_match("(?:ab)+", "abab")
      refute_match("(?:ab)+", "a")
    end

    def test_noncapturing_group_with_alternation
      assert_match("(?:ab|cd)", "ab")
      assert_match("(?:ab|cd)", "cd")
      assert_match("z(?:ab|cd)z", "zabz")
      assert_match("z(?:ab|cd)z", "zcdz")
      refute_match("(?:ab|cd)", "ac")
    end

    def test_capturing_groups
      match = Pattern.new("(a)(b)").match("ab")

      refute_nil(match)
      assert_equal("ab", match[0])
      assert_equal("a", match[1])
      assert_equal("b", match[2])
      assert_nil(match[3])
    end

    def test_nested_capturing_groups
      match = Pattern.new("(ab(c))").match("abc")

      refute_nil(match)
      assert_equal("abc", match[0])
      assert_equal("abc", match[1])
      assert_equal("c", match[2])
    end

    def test_optional_empty_capture
      match = Pattern.new("(a*)b").match("b")

      refute_nil(match)
      assert_equal("b", match[0])
      assert_equal("", match[1])
    end

    def test_named_capture_angle_brackets
      match = Pattern.new("(?<first>a)(?<second>b)").match("ab")

      refute_nil(match)
      assert_equal("ab", match[0])
      assert_equal("a", match[1])
      assert_equal("b", match[2])
      assert_equal("a", match["first"])
      assert_equal("b", match["second"])
      assert_nil(match["nonexistent"])
    end

    def test_named_capture_quotes
      match = Pattern.new("(?'name'[a-z]{5})").match("hello")

      refute_nil(match)
      assert_equal("hello", match[0])
      assert_equal("hello", match[1])
      assert_equal("hello", match["name"])
    end

    def test_mixed_named_and_numbered_captures
      match = Pattern.new("(a)(?<named>b)(c)").match("abc")

      refute_nil(match)
      assert_equal("abc", match[0])
      assert_equal("a", match[1])
      assert_equal("b", match[2])
      assert_equal("c", match[3])
      assert_equal("b", match["named"])
    end

    def test_line_start_anchor
      assert_match("^abc", "abc")
      refute_match("^abc", "xabc")
      assert_match("^", "hello")
      assert_match("^", "")
    end

    def test_line_end_anchor
      assert_match("abc$", "abc")
      refute_match("abc$", "abcx")
      assert_match("$", "")
      assert_match("$", "world")
    end

    def test_both_line_anchors
      assert_match("^$", "")
      refute_match("^$", "a")
    end

    def test_digit
      assert_match("\\A\\d\\z", "0")
      assert_match("\\A\\d\\z", "5")
      assert_match("\\A\\d\\z", "9")
      assert_match("\\A\\d\\z", "\u0660") # ٠
      assert_match("\\A\\d\\z", "\u0669") # ٩
      assert_match("\\A\\d\\z", "\u0966") # ०
      assert_match("\\A\\d\\z", "\u096F") # ९
      assert_match("\\A\\d\\d\\z", "42")
      assert_match("\\A\\d\\d\\z", "\u0661\u0662")
      assert_match("^\\d$", "a\n\u0663\nb") # Arabic-Indic digit ٣ on its own line

      refute_match("\\A\\d\\z", "a")
      refute_match("\\A\\d\\z", "")
      refute_match("\\A\\d\\z", "\u2460") # ① (Other_Number)
      refute_match("\\A\\d\\z", "\u2075") # ⁵ (Other_Number)
    end

    def test_ndigit
      assert_match("\\A\\D\\z", "a")
      assert_match("\\A\\D\\z", "Z")
      assert_match("\\A\\D\\z", "_")
      assert_match("\\A\\D\\z", "-")
      assert_match("\\A\\D\\z", " ")
      assert_match("\\A\\D\\z", "\n")
      assert_match("\\A\\D\\z", "\u2460") # ①
      assert_match("\\A\\D\\z", "\u2075") # ⁵

      refute_match("\\A\\D\\z", "0")
      refute_match("\\A\\D\\z", "5")
      refute_match("\\A\\D\\z", "9")
      refute_match("\\A\\D\\z", "\u0660") # ٠
      refute_match("\\A\\D\\z", "\u0966") # ०
    end

    def test_space
      assert_match("\\s", " ")
      assert_match("\\s", "\t")
      assert_match("\\s", "\n")
      assert_match("\\s", "\r")
      refute_match("\\s", "a")
      refute_match("\\s", "1")
    end

    def test_nspace
      assert_match("\\S", "a")
      assert_match("\\S", "1")
      refute_match("\\S", " ")
      refute_match("\\S", "\t")
      refute_match("\\S", "\n")
    end

    def test_word
      assert_match("\\w", "a")
      assert_match("\\w", "Z")
      assert_match("\\w", "0")
      assert_match("\\w", "_")
      refute_match("\\w", "-")
      refute_match("\\w", " ")
    end

    def test_nword
      assert_match("\\W", "-")
      assert_match("\\W", " ")
      refute_match("\\W", "a")
      refute_match("\\W", "Z")
      refute_match("\\W", "0")
      refute_match("\\W", "_")
    end

    def test_hex
      assert_match("\\h", "0")
      assert_match("\\h", "9")
      assert_match("\\h", "a")
      assert_match("\\h", "F")
      assert_match("\\h", "f")
      refute_match("\\h", "g")
      refute_match("\\h", "Z")
    end

    def test_nhex
      assert_match("\\H", "g")
      assert_match("\\H", "Z")
      assert_match("\\H", "😀")
      refute_match("\\H", "0")
      refute_match("\\H", "9")
      refute_match("\\H", "a")
      refute_match("\\H", "F")
      refute_match("\\H", "f")
    end

    def test_linebreak
      assert_match("\\R", "\r\n")
      assert_match("\\R", "\n")
      assert_match("\\R", "\r")
      assert_match("\\R", "\u0085")
      assert_match("\\R", "\u2028")
      assert_match("\\R", "\u2029")
      refute_match("\\R", "a")
      refute_match("\\R", " ")
    end

    def test_repetition
      assert_match("a{3}", "aaa")
      assert_match("a{3,}b", "aaaaaab")
      refute_match("a{3}", "aa")
    end

    def test_lazy_quantifier
      assert_match("a*?a", "aaaa")
      assert_match("a+?a", "aa")
      assert_match("ba*?a", "baaaa")
      refute_match("a+?b", "aaaa")

      assert_match("a*?b", "aaab")
      assert_match("(?:ab)*?c", "ababc")
      assert_match("a??b", "ab")
      assert_match("(?:ab)+?c", "ababc")
    end

    def test_possessive_quantifier
      assert_match("a*+", "aaaa")
      assert_match("a++", "aaaa")
      assert_match("a*+", "")
      refute_match("a*+a", "aaaa")
      refute_match("a++a", "aaaa")
      refute_match("a?+a", "a")
      assert_match("a?+a", "aa")

      refute_match("(?:ab)*+ab", "ababa")
      assert_match("(?:ab)*+c", "ababc")
      refute_match("(?:ab)?+ab", "ab")
      assert_match("(?:ab)?+ab", "abab")
      refute_match("^.*+b", "abc")
    end

    def test_errors
      assert_raises(SyntaxError) { Pattern.new("?") }
      assert_raises(SyntaxError) { Pattern.new("*") }
      assert_raises(SyntaxError) { Pattern.new("+") }
      assert_raises(SyntaxError) { Pattern.new("[") }
      assert_raises(SyntaxError) { Pattern.new("[]") }
      assert_raises(SyntaxError) { Pattern.new("(?:") }
      assert_raises(SyntaxError) { Pattern.new("(?:") }
      assert_raises(SyntaxError) { Pattern.new("(?:(?:)") }
      assert_raises(SyntaxError) { Pattern.new("(?:))") }
    end

    def test_control_escape_c
      # \cA should be 0x9f & 'A'.ord = 0x9f & 0x41 = 0x01
      assert_match("\\cA", "\x01")
      # \cZ should be 0x9f & 'Z'.ord = 0x9f & 0x5A = 0x1A
      assert_match("\\cZ", "\x1A")
      # \c with space (0x20) should be 0x9f & 0x20 = 0x00
      assert_match("\\c ", "\x00")
    end

    def test_control_escape_C_dash
      # \C-A should be same as \cA: 0x9f & 0x41 = 0x01
      assert_match("\\C-A", "\x01")
      # \C-Z should be same as \cZ: 0x9f & 0x5A = 0x1A
      assert_match("\\C-Z", "\x1A")
    end

    def test_control_escape_with_other_escapes
      # \c\x41 should work (0x41 is 'A')
      assert_match("\\c\\x41", "\x01")
      # \c\101 should work (octal 101 is 'A')
      assert_match("\\c\\101", "\x01")
      # \C-\x42 should work (0x42 is 'B', 0x9f & 0x42 = 0x02")
      assert_match("\\C-\\x42", "\x02")
    end

    def test_control_escape_requires_printable
      # Control character (0x01) is not printable
      error = assert_raises(SyntaxError) { Pattern.new("\\c\x01") }
      assert_includes(error.message, "ASCII-printable")

      # DEL character (0x7F) is not printable
      error = assert_raises(SyntaxError) { Pattern.new("\\c\x7F") }
      assert_includes(error.message, "ASCII-printable")
    end

    def test_control_escape_cannot_nest
      # \c\c should fail
      error = assert_raises(SyntaxError) { Pattern.new("\\c\\cA") }
      assert_includes(error.message, "cannot be nested")

      # \C-\C- should fail
      error = assert_raises(SyntaxError) { Pattern.new("\\C-\\C-A") }
      assert_includes(error.message, "cannot be nested")

      # \c\C- should fail
      error = assert_raises(SyntaxError) { Pattern.new("\\c\\C-A") }
      assert_includes(error.message, "cannot be nested")

      # \C-\c should fail
      error = assert_raises(SyntaxError) { Pattern.new("\\C-\\cA") }
      assert_includes(error.message, "cannot be nested")
    end

    def test_meta_escape_requires_printable
      # Control character (0x01) is not printable
      error = assert_raises(SyntaxError) { Pattern.new("\\M-\x01") }
      assert_includes(error.message, "ASCII-printable")

      # DEL character (0x7F) is not printable
      error = assert_raises(SyntaxError) { Pattern.new("\\M-\x7F") }
      assert_includes(error.message, "ASCII-printable")
    end

    def test_meta_escape_cannot_nest
      # \M-\M-A should fail to parse
      error = assert_raises(SyntaxError) { Pattern.new("\\M-\\M-A") }
      assert_includes(error.message, "cannot be nested")
    end

    def test_comment_basic
      # Comments should be ignored
      assert_match("a(?#comment)b", "ab")
      refute_match("a(?#comment)b", "acommentb")
    end

    def test_comment_at_start
      assert_match("(?#start)abc", "abc")
    end

    def test_comment_at_end
      assert_match("abc(?#end)", "abc")
    end

    def test_comment_multiple
      assert_match("a(?#one)b(?#two)c", "abc")
    end

    def test_comment_empty
      assert_match("(?#)", "")
      assert_match("a(?#)b", "ab")
    end

    def test_comment_with_special_chars
      assert_match("a(?#with spaces and special chars!@\#$%^&*)b", "ab")
    end

    def test_comment_with_groups
      assert_match("(?#comment)(?:a|b)", "a")
      assert_match("(?#comment)(?:a|b)", "b")
    end

    def test_comment_with_quantifiers
      assert_match("a+(?#greedy)b", "aaab")
      assert_match("a*(?#zero or more)", "b")
    end

    def test_comment_between_atoms
      # Comment should not affect concatenation
      assert_match("test(?#middle)case", "testcase")
    end

    def test_comment_unterminated
      # Unterminated comment should raise an error
      error = assert_raises(SyntaxError) { Pattern.new("a(?#unterminated") }
      assert_includes(error.message, "Unterminated comment")
    end

    def test_comment_does_not_allow_nested_parens
      # Ruby regex comments stop at the first ), so nested parens cause errors
      # This matches Ruby's actual behavior
      error = assert_raises(SyntaxError) { Pattern.new("(?#nested (parens))test") }
      assert_includes(error.message, "Unmatched ')'")
    end
  end

  class IgnoreCaseTest < ExregTest
    def test_common
      assert_match("A", "a", Option::IGNORECASE)
      assert_match("a", "A", Option::IGNORECASE)
    end
  end

  class MultiLineTest < ExregTest
    def test_default
      assert_match(".", "a")
      refute_match(".", "\n")
    end

    def test_multiline
      assert_match(".", "\n", Option::MULTILINE)
      assert_match("a.b", "a\nb", Option::MULTILINE)
      refute_match("a.b", "ab", Option::MULTILINE)
    end
  end

  class InlineOptionsTest < ExregTest
    def test_enable_ignorecase_for_remainder
      assert_match("(?i)ab", "AB")
    end

    def test_toggle_ignorecase_mid_pattern
      assert_match("a(?i)b", "aB")
      refute_match("a(?i)b", "Ab")
    end

    def test_disable_ignorecase
      refute_match("(?i)ab(?-i)c", "ABC")
      assert_match("(?i)ab(?-i)c", "ABc")
    end

    def test_enable_multiline_mid_pattern
      assert_match("a(?m).b", "a\nb")
      refute_match("a(?m).b", "ab")
    end

    def test_disable_multiline
      refute_match("(?m)a(?-m).b", "a\nb")
      assert_match("(?m)a(?-m).b", "acb")
    end

    def test_scoped_ignorecase_group
      assert_match("a(?i:b)c", "abc")
      assert_match("a(?i:b)c", "aBc")
      refute_match("a(?i:b)c", "Abc")
      refute_match("a(?i:b)c", "abC")
    end

    def test_scoped_multiline_group
      assert_match("a(?m:.+)c", "a\n\nbc")
      assert_match("a(?m:.+)c", "abc")
    end
  end

  class UTF32LETest < ExregTest
    def test_single_ascii_character
      pattern = Pattern.new("a", Option::NONE, Encoding::UTF_32LE)
      assert(pattern.match?("a".encode(Encoding::UTF_32LE)))
      refute(pattern.match?("b".encode(Encoding::UTF_32LE)))
    end

    def test_ascii_character_range
      pattern = Pattern.new("[a-c]", Option::NONE, Encoding::UTF_32LE)
      assert(pattern.match?("a".encode(Encoding::UTF_32LE)))
      assert(pattern.match?("b".encode(Encoding::UTF_32LE)))
      assert(pattern.match?("c".encode(Encoding::UTF_32LE)))
      refute(pattern.match?("d".encode(Encoding::UTF_32LE)))
    end

    def test_ascii_character_set
      pattern = Pattern.new("[abc]", Option::NONE, Encoding::UTF_32LE)
      assert(pattern.match?("a".encode(Encoding::UTF_32LE)))
      assert(pattern.match?("b".encode(Encoding::UTF_32LE)))
      assert(pattern.match?("c".encode(Encoding::UTF_32LE)))
      refute(pattern.match?("d".encode(Encoding::UTF_32LE)))
    end

    def test_multiple_ascii_characters
      pattern = Pattern.new("abc", Option::NONE, Encoding::UTF_32LE)
      assert(pattern.match?("abc".encode(Encoding::UTF_32LE)))
      assert(pattern.match?("xabc".encode(Encoding::UTF_32LE)))
      refute(pattern.match?("ab".encode(Encoding::UTF_32LE)))
      refute(pattern.match?("abd".encode(Encoding::UTF_32LE)))
    end

    def test_unicode_emoji_single
      pattern = Pattern.new("😀", Option::NONE, Encoding::UTF_32LE)
      assert(pattern.match?("😀".encode(Encoding::UTF_32LE)))
      refute(pattern.match?("😁".encode(Encoding::UTF_32LE)))
    end

    def test_unicode_emoji_range
      pattern = Pattern.new("[😀-😂]", Option::NONE, Encoding::UTF_32LE)
      assert(pattern.match?("😀".encode(Encoding::UTF_32LE)))
      assert(pattern.match?("😁".encode(Encoding::UTF_32LE)))
      assert(pattern.match?("😂".encode(Encoding::UTF_32LE)))
      refute(pattern.match?("😃".encode(Encoding::UTF_32LE)))
      refute(pattern.match?("a".encode(Encoding::UTF_32LE)))
    end

    def test_unicode_chinese_characters
      pattern = Pattern.new("[你好]", Option::NONE, Encoding::UTF_32LE)
      assert(pattern.match?("你".encode(Encoding::UTF_32LE)))
      assert(pattern.match?("好".encode(Encoding::UTF_32LE)))
      refute(pattern.match?("世".encode(Encoding::UTF_32LE)))
    end

    def test_unicode_chinese_range
      # Using characters that are actually in sequence
      pattern = Pattern.new("[一-万]", Option::NONE, Encoding::UTF_32LE)
      assert(pattern.match?("一".encode(Encoding::UTF_32LE))) # U+4E00
      assert(pattern.match?("七".encode(Encoding::UTF_32LE))) # U+4E03
      assert(pattern.match?("万".encode(Encoding::UTF_32LE))) # U+4E07
      refute(pattern.match?("丞".encode(Encoding::UTF_32LE))) # U+4E1E (outside range)
    end

    def test_mixed_ascii_and_unicode
      pattern = Pattern.new("[a-z😀-😂]", Option::NONE, Encoding::UTF_32LE)
      assert(pattern.match?("a".encode(Encoding::UTF_32LE)))
      assert(pattern.match?("z".encode(Encoding::UTF_32LE)))
      assert(pattern.match?("😀".encode(Encoding::UTF_32LE)))
      assert(pattern.match?("😂".encode(Encoding::UTF_32LE)))
      refute(pattern.match?("A".encode(Encoding::UTF_32LE)))
      refute(pattern.match?("😃".encode(Encoding::UTF_32LE)))
    end

    def test_dot_metacharacter
      pattern = Pattern.new(".", Option::NONE, Encoding::UTF_32LE)
      assert(pattern.match?("a".encode(Encoding::UTF_32LE)))
      assert(pattern.match?("😀".encode(Encoding::UTF_32LE)))
      assert(pattern.match?("你".encode(Encoding::UTF_32LE)))
    end

    def test_quantifiers_with_unicode
      pattern = Pattern.new("😀+", Option::NONE, Encoding::UTF_32LE)
      assert(pattern.match?("😀".encode(Encoding::UTF_32LE)))
      assert(pattern.match?("😀😀😀".encode(Encoding::UTF_32LE)))
      refute(pattern.match?("😁".encode(Encoding::UTF_32LE)))
    end

    def test_alternation_with_unicode
      pattern = Pattern.new("😀|😁", Option::NONE, Encoding::UTF_32LE)
      assert(pattern.match?("😀".encode(Encoding::UTF_32LE)))
      assert(pattern.match?("😁".encode(Encoding::UTF_32LE)))
      refute(pattern.match?("😂".encode(Encoding::UTF_32LE)))
    end

    def test_character_class_digit
      pattern = Pattern.new("\\d+", Option::NONE, Encoding::UTF_32LE)
      assert(pattern.match?("123".encode(Encoding::UTF_32LE)))
      assert(pattern.match?("0".encode(Encoding::UTF_32LE)))
      refute(pattern.match?("abc".encode(Encoding::UTF_32LE)))
    end

    def test_character_class_word
      pattern = Pattern.new("\\w+", Option::NONE, Encoding::UTF_32LE)
      assert(pattern.match?("hello".encode(Encoding::UTF_32LE)))
      assert(pattern.match?("test123".encode(Encoding::UTF_32LE)))
      refute(pattern.match?("!!!".encode(Encoding::UTF_32LE)))
    end

    def test_anchors_start_and_end
      pattern = Pattern.new("^abc$", Option::NONE, Encoding::UTF_32LE)
      assert(pattern.match?("abc".encode(Encoding::UTF_32LE)))
      refute(pattern.match?("xabc".encode(Encoding::UTF_32LE)))
      refute(pattern.match?("abcx".encode(Encoding::UTF_32LE)))
    end

    def test_byte0_only_varies
      # Test case where only the first byte varies
      pattern = Pattern.new("[\u{100}-\u{1FF}]", Option::NONE, Encoding::UTF_32LE)
      assert(pattern.match?("\u{100}".encode(Encoding::UTF_32LE)))
      assert(pattern.match?("\u{1FF}".encode(Encoding::UTF_32LE)))
      refute(pattern.match?("\u{FF}".encode(Encoding::UTF_32LE)))
      refute(pattern.match?("\u{200}".encode(Encoding::UTF_32LE)))
    end

    def test_byte1_varies
      # Test case where bytes 0-1 vary
      pattern = Pattern.new("[\u{1000}-\u{1FFF}]", Option::NONE, Encoding::UTF_32LE)
      assert(pattern.match?("\u{1000}".encode(Encoding::UTF_32LE)))
      assert(pattern.match?("\u{1500}".encode(Encoding::UTF_32LE)))
      assert(pattern.match?("\u{1FFF}".encode(Encoding::UTF_32LE)))
      refute(pattern.match?("\u{FFF}".encode(Encoding::UTF_32LE)))
      refute(pattern.match?("\u{2000}".encode(Encoding::UTF_32LE)))
    end

    def test_byte2_varies
      # Test case where bytes 0-2 vary
      pattern = Pattern.new("[\u{10000}-\u{1FFFF}]", Option::NONE, Encoding::UTF_32LE)
      assert(pattern.match?("\u{10000}".encode(Encoding::UTF_32LE)))
      assert(pattern.match?("\u{15000}".encode(Encoding::UTF_32LE)))
      assert(pattern.match?("\u{1FFFF}".encode(Encoding::UTF_32LE)))
      refute(pattern.match?("\u{FFFF}".encode(Encoding::UTF_32LE)))
      refute(pattern.match?("\u{20000}".encode(Encoding::UTF_32LE)))
    end

    def test_byte3_varies
      # Test case where all 4 bytes vary
      pattern = Pattern.new("[\u{10000}-\u{10FFFF}]", Option::NONE, Encoding::UTF_32LE)
      assert(pattern.match?("\u{10000}".encode(Encoding::UTF_32LE)))
      assert(pattern.match?("\u{50000}".encode(Encoding::UTF_32LE)))
      assert(pattern.match?("\u{10FFFF}".encode(Encoding::UTF_32LE)))
      refute(pattern.match?("\u{FFFF}".encode(Encoding::UTF_32LE)))
    end

    def test_inverted_character_class
      pattern = Pattern.new("[^a-c]", Option::NONE, Encoding::UTF_32LE)
      refute(pattern.match?("a".encode(Encoding::UTF_32LE)))
      refute(pattern.match?("b".encode(Encoding::UTF_32LE)))
      refute(pattern.match?("c".encode(Encoding::UTF_32LE)))
      assert(pattern.match?("d".encode(Encoding::UTF_32LE)))
      assert(pattern.match?("😀".encode(Encoding::UTF_32LE)))
    end

    def test_complex_pattern
      pattern = Pattern.new("hello.*world", Option::NONE, Encoding::UTF_32LE)
      assert(pattern.match?("hello world".encode(Encoding::UTF_32LE)))
      assert(pattern.match?("hello beautiful world".encode(Encoding::UTF_32LE)))
      refute(pattern.match?("hello".encode(Encoding::UTF_32LE)))
    end

    def test_unicode_property_letter
      pattern = Pattern.new("\\p{Letter}+", Option::NONE, Encoding::UTF_32LE)
      assert(pattern.match?("hello".encode(Encoding::UTF_32LE)))
      assert(pattern.match?("你好".encode(Encoding::UTF_32LE)))
      refute(pattern.match?("123".encode(Encoding::UTF_32LE)))
    end

    def test_large_codepoint_range
      # Test with surrogate pair range (supplementary characters)
      pattern = Pattern.new("[𐀀-𐀿]", Option::NONE, Encoding::UTF_32LE)
      assert(pattern.match?("𐀀".encode(Encoding::UTF_32LE)))
      assert(pattern.match?("𐀿".encode(Encoding::UTF_32LE)))
      refute(pattern.match?("a".encode(Encoding::UTF_32LE)))
    end
  end

  class UTF32BETest < ExregTest
    def test_single_ascii_character
      pattern = Pattern.new("a", Option::NONE, Encoding::UTF_32BE)
      assert(pattern.match?("a".encode(Encoding::UTF_32BE)))
      refute(pattern.match?("b".encode(Encoding::UTF_32BE)))
    end

    def test_ascii_alternation
      pattern = Pattern.new("a|b|c", Option::NONE, Encoding::UTF_32BE)
      assert(pattern.match?("a".encode(Encoding::UTF_32BE)))
      assert(pattern.match?("b".encode(Encoding::UTF_32BE)))
      assert(pattern.match?("c".encode(Encoding::UTF_32BE)))
      refute(pattern.match?("d".encode(Encoding::UTF_32BE)))
    end

    def test_ascii_character_set
      pattern = Pattern.new("[abc]", Option::NONE, Encoding::UTF_32BE)
      assert(pattern.match?("a".encode(Encoding::UTF_32BE)))
      assert(pattern.match?("b".encode(Encoding::UTF_32BE)))
      assert(pattern.match?("c".encode(Encoding::UTF_32BE)))
      refute(pattern.match?("d".encode(Encoding::UTF_32BE)))
    end

    def test_multiple_ascii_characters
      pattern = Pattern.new("abc", Option::NONE, Encoding::UTF_32BE)
      assert(pattern.match?("abc".encode(Encoding::UTF_32BE)))
      assert(pattern.match?("xabc".encode(Encoding::UTF_32BE)))
      refute(pattern.match?("ab".encode(Encoding::UTF_32BE)))
      refute(pattern.match?("abd".encode(Encoding::UTF_32BE)))
    end

    def test_unicode_emoji_single
      pattern = Pattern.new("😀", Option::NONE, Encoding::UTF_32BE)
      assert(pattern.match?("😀".encode(Encoding::UTF_32BE)))
      refute(pattern.match?("😁".encode(Encoding::UTF_32BE)))
    end

    def test_unicode_emoji_range
      pattern = Pattern.new("[😀-😂]", Option::NONE, Encoding::UTF_32BE)
      assert(pattern.match?("😀".encode(Encoding::UTF_32BE)))
      assert(pattern.match?("😁".encode(Encoding::UTF_32BE)))
      assert(pattern.match?("😂".encode(Encoding::UTF_32BE)))
      refute(pattern.match?("😃".encode(Encoding::UTF_32BE)))
      refute(pattern.match?("a".encode(Encoding::UTF_32BE)))
    end

    def test_unicode_chinese_characters
      pattern = Pattern.new("[你好]", Option::NONE, Encoding::UTF_32BE)
      assert(pattern.match?("你".encode(Encoding::UTF_32BE)))
      assert(pattern.match?("好".encode(Encoding::UTF_32BE)))
      refute(pattern.match?("世".encode(Encoding::UTF_32BE)))
    end

    def test_unicode_chinese_range
      # Using characters that are actually in sequence
      pattern = Pattern.new("[一-万]", Option::NONE, Encoding::UTF_32BE)
      assert(pattern.match?("一".encode(Encoding::UTF_32BE))) # U+4E00
      assert(pattern.match?("七".encode(Encoding::UTF_32BE))) # U+4E03
      assert(pattern.match?("万".encode(Encoding::UTF_32BE))) # U+4E07
      refute(pattern.match?("丞".encode(Encoding::UTF_32BE))) # U+4E1E (outside range)
    end

    def test_mixed_ascii_and_unicode
      pattern = Pattern.new("[a-z😀-😂]", Option::NONE, Encoding::UTF_32BE)
      assert(pattern.match?("a".encode(Encoding::UTF_32BE)))
      assert(pattern.match?("z".encode(Encoding::UTF_32BE)))
      assert(pattern.match?("😀".encode(Encoding::UTF_32BE)))
      assert(pattern.match?("😂".encode(Encoding::UTF_32BE)))
      refute(pattern.match?("A".encode(Encoding::UTF_32BE)))
      refute(pattern.match?("😃".encode(Encoding::UTF_32BE)))
    end

    def test_dot_metacharacter
      pattern = Pattern.new(".", Option::NONE, Encoding::UTF_32BE)
      assert(pattern.match?("a".encode(Encoding::UTF_32BE)))
      assert(pattern.match?("😀".encode(Encoding::UTF_32BE)))
      assert(pattern.match?("你".encode(Encoding::UTF_32BE)))
    end

    def test_quantifiers_with_unicode
      pattern = Pattern.new("😀+", Option::NONE, Encoding::UTF_32BE)
      assert(pattern.match?("😀".encode(Encoding::UTF_32BE)))
      assert(pattern.match?("😀😀😀".encode(Encoding::UTF_32BE)))
      refute(pattern.match?("😁".encode(Encoding::UTF_32BE)))
    end

    def test_alternation_with_unicode
      pattern = Pattern.new("😀|😁", Option::NONE, Encoding::UTF_32BE)
      assert(pattern.match?("😀".encode(Encoding::UTF_32BE)))
      assert(pattern.match?("😁".encode(Encoding::UTF_32BE)))
      refute(pattern.match?("😂".encode(Encoding::UTF_32BE)))
    end

    def test_character_class_digit
      pattern = Pattern.new("\\d+", Option::NONE, Encoding::UTF_32BE)
      assert(pattern.match?("123".encode(Encoding::UTF_32BE)))
      assert(pattern.match?("0".encode(Encoding::UTF_32BE)))
      refute(pattern.match?("abc".encode(Encoding::UTF_32BE)))
    end

    def test_character_class_word
      pattern = Pattern.new("\\w+", Option::NONE, Encoding::UTF_32BE)
      assert(pattern.match?("hello".encode(Encoding::UTF_32BE)))
      assert(pattern.match?("test123".encode(Encoding::UTF_32BE)))
      refute(pattern.match?("!!!".encode(Encoding::UTF_32BE)))
    end

    def test_anchors_start_and_end
      pattern = Pattern.new("^abc$", Option::NONE, Encoding::UTF_32BE)
      assert(pattern.match?("abc".encode(Encoding::UTF_32BE)))
      refute(pattern.match?("xabc".encode(Encoding::UTF_32BE)))
      refute(pattern.match?("abcx".encode(Encoding::UTF_32BE)))
    end

    def test_byte0_only_varies
      # Test case where only the first byte varies (MSB in big-endian)
      pattern = Pattern.new("[\u{100}-\u{1FF}]", Option::NONE, Encoding::UTF_32BE)
      assert(pattern.match?("\u{100}".encode(Encoding::UTF_32BE)))
      assert(pattern.match?("\u{1FF}".encode(Encoding::UTF_32BE)))
      refute(pattern.match?("\u{FF}".encode(Encoding::UTF_32BE)))
      refute(pattern.match?("\u{200}".encode(Encoding::UTF_32BE)))
    end

    def test_byte1_varies
      # Test case where bytes 0-1 vary
      pattern = Pattern.new("[\u{1000}-\u{1FFF}]", Option::NONE, Encoding::UTF_32BE)
      assert(pattern.match?("\u{1000}".encode(Encoding::UTF_32BE)))
      assert(pattern.match?("\u{1500}".encode(Encoding::UTF_32BE)))
      assert(pattern.match?("\u{1FFF}".encode(Encoding::UTF_32BE)))
      refute(pattern.match?("\u{FFF}".encode(Encoding::UTF_32BE)))
      refute(pattern.match?("\u{2000}".encode(Encoding::UTF_32BE)))
    end

    def test_byte2_varies
      # Test case where bytes 0-2 vary
      pattern = Pattern.new("[\u{10000}-\u{1FFFF}]", Option::NONE, Encoding::UTF_32BE)
      assert(pattern.match?("\u{10000}".encode(Encoding::UTF_32BE)))
      assert(pattern.match?("\u{15000}".encode(Encoding::UTF_32BE)))
      assert(pattern.match?("\u{1FFFF}".encode(Encoding::UTF_32BE)))
      refute(pattern.match?("\u{FFFF}".encode(Encoding::UTF_32BE)))
      refute(pattern.match?("\u{20000}".encode(Encoding::UTF_32BE)))
    end

    def test_byte3_varies
      # Test case where all 4 bytes vary
      pattern = Pattern.new("[\u{10000}-\u{10FFFF}]", Option::NONE, Encoding::UTF_32BE)
      assert(pattern.match?("\u{10000}".encode(Encoding::UTF_32BE)))
      assert(pattern.match?("\u{50000}".encode(Encoding::UTF_32BE)))
      assert(pattern.match?("\u{10FFFF}".encode(Encoding::UTF_32BE)))
      refute(pattern.match?("\u{FFFF}".encode(Encoding::UTF_32BE)))
    end

    def test_inverted_character_class
      pattern = Pattern.new("[^a-c]", Option::NONE, Encoding::UTF_32BE)
      refute(pattern.match?("a".encode(Encoding::UTF_32BE)))
      refute(pattern.match?("b".encode(Encoding::UTF_32BE)))
      refute(pattern.match?("c".encode(Encoding::UTF_32BE)))
      assert(pattern.match?("d".encode(Encoding::UTF_32BE)))
      assert(pattern.match?("😀".encode(Encoding::UTF_32BE)))
    end

    def test_complex_pattern
      pattern = Pattern.new("hello.*world", Option::NONE, Encoding::UTF_32BE)
      assert(pattern.match?("hello world".encode(Encoding::UTF_32BE)))
      assert(pattern.match?("hello beautiful world".encode(Encoding::UTF_32BE)))
      refute(pattern.match?("hello".encode(Encoding::UTF_32BE)))
    end

    def test_unicode_property_letter
      pattern = Pattern.new("\\p{Letter}+", Option::NONE, Encoding::UTF_32BE)
      assert(pattern.match?("hello".encode(Encoding::UTF_32BE)))
      assert(pattern.match?("你好".encode(Encoding::UTF_32BE)))
      refute(pattern.match?("123".encode(Encoding::UTF_32BE)))
    end

    def test_large_codepoint_range
      # Test with supplementary characters
      pattern = Pattern.new("[𐀀-𐀿]", Option::NONE, Encoding::UTF_32BE)
      assert(pattern.match?("𐀀".encode(Encoding::UTF_32BE)))
      assert(pattern.match?("𐀿".encode(Encoding::UTF_32BE)))
      refute(pattern.match?("a".encode(Encoding::UTF_32BE)))
    end
  end

  class UTF16LETest < ExregTest
    def test_single_ascii_character
      pattern = Pattern.new("a", Option::NONE, Encoding::UTF_16LE)
      assert(pattern.match?("a".encode(Encoding::UTF_16LE)))
      refute(pattern.match?("b".encode(Encoding::UTF_16LE)))
    end

    def test_ascii_alternation
      pattern = Pattern.new("a|b|c", Option::NONE, Encoding::UTF_16LE)
      assert(pattern.match?("a".encode(Encoding::UTF_16LE)))
      assert(pattern.match?("b".encode(Encoding::UTF_16LE)))
      assert(pattern.match?("c".encode(Encoding::UTF_16LE)))
      refute(pattern.match?("d".encode(Encoding::UTF_16LE)))
    end

    def test_ascii_character_set
      pattern = Pattern.new("[abc]", Option::NONE, Encoding::UTF_16LE)
      assert(pattern.match?("a".encode(Encoding::UTF_16LE)))
      assert(pattern.match?("b".encode(Encoding::UTF_16LE)))
      assert(pattern.match?("c".encode(Encoding::UTF_16LE)))
      refute(pattern.match?("d".encode(Encoding::UTF_16LE)))
    end

    def test_multiple_ascii_characters
      pattern = Pattern.new("abc", Option::NONE, Encoding::UTF_16LE)
      assert(pattern.match?("abc".encode(Encoding::UTF_16LE)))
      assert(pattern.match?("xabc".encode(Encoding::UTF_16LE)))
      refute(pattern.match?("ab".encode(Encoding::UTF_16LE)))
      refute(pattern.match?("abd".encode(Encoding::UTF_16LE)))
    end

    def test_unicode_emoji_single
      pattern = Pattern.new("😀", Option::NONE, Encoding::UTF_16LE)
      assert(pattern.match?("😀".encode(Encoding::UTF_16LE)))
      refute(pattern.match?("😁".encode(Encoding::UTF_16LE)))
    end

    def test_unicode_emoji_range
      pattern = Pattern.new("[😀-😂]", Option::NONE, Encoding::UTF_16LE)
      assert(pattern.match?("😀".encode(Encoding::UTF_16LE)))
      assert(pattern.match?("😁".encode(Encoding::UTF_16LE)))
      assert(pattern.match?("😂".encode(Encoding::UTF_16LE)))
      refute(pattern.match?("😃".encode(Encoding::UTF_16LE)))
      refute(pattern.match?("a".encode(Encoding::UTF_16LE)))
    end

    def test_unicode_chinese_characters
      pattern = Pattern.new("[你好]", Option::NONE, Encoding::UTF_16LE)
      assert(pattern.match?("你".encode(Encoding::UTF_16LE)))
      assert(pattern.match?("好".encode(Encoding::UTF_16LE)))
      refute(pattern.match?("世".encode(Encoding::UTF_16LE)))
    end

    def test_unicode_chinese_range
      pattern = Pattern.new("[一-万]", Option::NONE, Encoding::UTF_16LE)
      assert(pattern.match?("一".encode(Encoding::UTF_16LE)))
      assert(pattern.match?("七".encode(Encoding::UTF_16LE)))
      assert(pattern.match?("万".encode(Encoding::UTF_16LE)))
      refute(pattern.match?("丞".encode(Encoding::UTF_16LE)))
    end

    def test_mixed_ascii_and_unicode
      pattern = Pattern.new("[a-z😀-😂]", Option::NONE, Encoding::UTF_16LE)
      assert(pattern.match?("a".encode(Encoding::UTF_16LE)))
      assert(pattern.match?("z".encode(Encoding::UTF_16LE)))
      assert(pattern.match?("😀".encode(Encoding::UTF_16LE)))
      assert(pattern.match?("😂".encode(Encoding::UTF_16LE)))
      refute(pattern.match?("A".encode(Encoding::UTF_16LE)))
      refute(pattern.match?("😃".encode(Encoding::UTF_16LE)))
    end

    def test_dot_metacharacter
      pattern = Pattern.new(".", Option::NONE, Encoding::UTF_16LE)
      assert(pattern.match?("a".encode(Encoding::UTF_16LE)))
      assert(pattern.match?("😀".encode(Encoding::UTF_16LE)))
      assert(pattern.match?("你".encode(Encoding::UTF_16LE)))
    end

    def test_quantifiers_with_unicode
      pattern = Pattern.new("😀+", Option::NONE, Encoding::UTF_16LE)
      assert(pattern.match?("😀".encode(Encoding::UTF_16LE)))
      assert(pattern.match?("😀😀😀".encode(Encoding::UTF_16LE)))
      refute(pattern.match?("😁".encode(Encoding::UTF_16LE)))
    end

    def test_alternation_with_unicode
      pattern = Pattern.new("😀|😁", Option::NONE, Encoding::UTF_16LE)
      assert(pattern.match?("😀".encode(Encoding::UTF_16LE)))
      assert(pattern.match?("😁".encode(Encoding::UTF_16LE)))
      refute(pattern.match?("😂".encode(Encoding::UTF_16LE)))
    end

    def test_character_class_digit
      pattern = Pattern.new("\\d+", Option::NONE, Encoding::UTF_16LE)
      assert(pattern.match?("123".encode(Encoding::UTF_16LE)))
      assert(pattern.match?("0".encode(Encoding::UTF_16LE)))
      refute(pattern.match?("abc".encode(Encoding::UTF_16LE)))
    end

    def test_character_class_word
      pattern = Pattern.new("\\w+", Option::NONE, Encoding::UTF_16LE)
      assert(pattern.match?("hello".encode(Encoding::UTF_16LE)))
      assert(pattern.match?("test123".encode(Encoding::UTF_16LE)))
      refute(pattern.match?("!!!".encode(Encoding::UTF_16LE)))
    end

    def test_anchors_start_and_end
      pattern = Pattern.new("^abc$", Option::NONE, Encoding::UTF_16LE)
      assert(pattern.match?("abc".encode(Encoding::UTF_16LE)))
      refute(pattern.match?("xabc".encode(Encoding::UTF_16LE)))
      refute(pattern.match?("abcx".encode(Encoding::UTF_16LE)))
    end

    def test_bmp_range_byte0_varies
      # Test BMP range where only byte0 varies
      pattern = Pattern.new("[\u{100}-\u{1FF}]", Option::NONE, Encoding::UTF_16LE)
      assert(pattern.match?("\u{100}".encode(Encoding::UTF_16LE)))
      assert(pattern.match?("\u{1FF}".encode(Encoding::UTF_16LE)))
      refute(pattern.match?("\u{FF}".encode(Encoding::UTF_16LE)))
      refute(pattern.match?("\u{200}".encode(Encoding::UTF_16LE)))
    end

    def test_bmp_range_both_bytes_vary
      # Test BMP range where both bytes vary
      pattern = Pattern.new("[\u{1000}-\u{1FFF}]", Option::NONE, Encoding::UTF_16LE)
      assert(pattern.match?("\u{1000}".encode(Encoding::UTF_16LE)))
      assert(pattern.match?("\u{1500}".encode(Encoding::UTF_16LE)))
      assert(pattern.match?("\u{1FFF}".encode(Encoding::UTF_16LE)))
      refute(pattern.match?("\u{FFF}".encode(Encoding::UTF_16LE)))
      refute(pattern.match?("\u{2000}".encode(Encoding::UTF_16LE)))
    end

    def test_supplementary_plane_single
      # Test single supplementary character (requires surrogate pair)
      pattern = Pattern.new("𐀀", Option::NONE, Encoding::UTF_16LE)
      assert(pattern.match?("𐀀".encode(Encoding::UTF_16LE)))
      refute(pattern.match?("𐀁".encode(Encoding::UTF_16LE)))
    end

    def test_supplementary_plane_range
      # Test supplementary character range
      pattern = Pattern.new("[𐀀-𐀿]", Option::NONE, Encoding::UTF_16LE)
      assert(pattern.match?("𐀀".encode(Encoding::UTF_16LE)))
      assert(pattern.match?("𐀿".encode(Encoding::UTF_16LE)))
      refute(pattern.match?("a".encode(Encoding::UTF_16LE)))
      refute(pattern.match?("𐁀".encode(Encoding::UTF_16LE)))
    end

    def test_inverted_character_class
      pattern = Pattern.new("[^a-c]", Option::NONE, Encoding::UTF_16LE)
      refute(pattern.match?("a".encode(Encoding::UTF_16LE)))
      refute(pattern.match?("b".encode(Encoding::UTF_16LE)))
      refute(pattern.match?("c".encode(Encoding::UTF_16LE)))
      assert(pattern.match?("d".encode(Encoding::UTF_16LE)))
      assert(pattern.match?("😀".encode(Encoding::UTF_16LE)))
    end

    def test_complex_pattern
      pattern = Pattern.new("hello.*world", Option::NONE, Encoding::UTF_16LE)
      assert(pattern.match?("hello world".encode(Encoding::UTF_16LE)))
      assert(pattern.match?("hello beautiful world".encode(Encoding::UTF_16LE)))
      refute(pattern.match?("hello".encode(Encoding::UTF_16LE)))
    end

    def test_unicode_property_letter
      pattern = Pattern.new("\\p{Letter}+", Option::NONE, Encoding::UTF_16LE)
      assert(pattern.match?("hello".encode(Encoding::UTF_16LE)))
      assert(pattern.match?("你好".encode(Encoding::UTF_16LE)))
      refute(pattern.match?("123".encode(Encoding::UTF_16LE)))
    end

    def test_mixed_bmp_and_supplementary
      # Test range that spans BMP and supplementary planes
      pattern = Pattern.new("[\u{FFFD}-\u{10001}]", Option::NONE, Encoding::UTF_16LE)
      assert(pattern.match?("\u{FFFD}".encode(Encoding::UTF_16LE)))
      assert(pattern.match?("\u{FFFE}".encode(Encoding::UTF_16LE)))
      assert(pattern.match?("\u{FFFF}".encode(Encoding::UTF_16LE)))
      assert(pattern.match?("\u{10000}".encode(Encoding::UTF_16LE)))
      assert(pattern.match?("\u{10001}".encode(Encoding::UTF_16LE)))
      refute(pattern.match?("\u{FFFC}".encode(Encoding::UTF_16LE)))
      refute(pattern.match?("\u{10002}".encode(Encoding::UTF_16LE)))
    end
  end

  class UTF16BETest < ExregTest
    def test_single_ascii_character
      pattern = Pattern.new("a", Option::NONE, Encoding::UTF_16BE)
      assert(pattern.match?("a".encode(Encoding::UTF_16BE)))
      refute(pattern.match?("b".encode(Encoding::UTF_16BE)))
    end

    def test_ascii_alternation
      pattern = Pattern.new("a|b|c", Option::NONE, Encoding::UTF_16BE)
      assert(pattern.match?("a".encode(Encoding::UTF_16BE)))
      assert(pattern.match?("b".encode(Encoding::UTF_16BE)))
      assert(pattern.match?("c".encode(Encoding::UTF_16BE)))
      refute(pattern.match?("d".encode(Encoding::UTF_16BE)))
    end

    def test_ascii_character_set
      pattern = Pattern.new("[abc]", Option::NONE, Encoding::UTF_16BE)
      assert(pattern.match?("a".encode(Encoding::UTF_16BE)))
      assert(pattern.match?("b".encode(Encoding::UTF_16BE)))
      assert(pattern.match?("c".encode(Encoding::UTF_16BE)))
      refute(pattern.match?("d".encode(Encoding::UTF_16BE)))
    end

    def test_multiple_ascii_characters
      pattern = Pattern.new("abc", Option::NONE, Encoding::UTF_16BE)
      assert(pattern.match?("abc".encode(Encoding::UTF_16BE)))
      assert(pattern.match?("xabc".encode(Encoding::UTF_16BE)))
      refute(pattern.match?("ab".encode(Encoding::UTF_16BE)))
      refute(pattern.match?("abd".encode(Encoding::UTF_16BE)))
    end

    def test_unicode_emoji_single
      pattern = Pattern.new("😀", Option::NONE, Encoding::UTF_16BE)
      assert(pattern.match?("😀".encode(Encoding::UTF_16BE)))
      refute(pattern.match?("😁".encode(Encoding::UTF_16BE)))
    end

    def test_unicode_emoji_range
      pattern = Pattern.new("[😀-😂]", Option::NONE, Encoding::UTF_16BE)
      assert(pattern.match?("😀".encode(Encoding::UTF_16BE)))
      assert(pattern.match?("😁".encode(Encoding::UTF_16BE)))
      assert(pattern.match?("😂".encode(Encoding::UTF_16BE)))
      refute(pattern.match?("😃".encode(Encoding::UTF_16BE)))
      refute(pattern.match?("a".encode(Encoding::UTF_16BE)))
    end

    def test_unicode_chinese_characters
      pattern = Pattern.new("[你好]", Option::NONE, Encoding::UTF_16BE)
      assert(pattern.match?("你".encode(Encoding::UTF_16BE)))
      assert(pattern.match?("好".encode(Encoding::UTF_16BE)))
      refute(pattern.match?("世".encode(Encoding::UTF_16BE)))
    end

    def test_unicode_chinese_range
      pattern = Pattern.new("[一-万]", Option::NONE, Encoding::UTF_16BE)
      assert(pattern.match?("一".encode(Encoding::UTF_16BE)))
      assert(pattern.match?("七".encode(Encoding::UTF_16BE)))
      assert(pattern.match?("万".encode(Encoding::UTF_16BE)))
      refute(pattern.match?("丞".encode(Encoding::UTF_16BE)))
    end

    def test_mixed_ascii_and_unicode
      pattern = Pattern.new("[a-z😀-😂]", Option::NONE, Encoding::UTF_16BE)
      assert(pattern.match?("a".encode(Encoding::UTF_16BE)))
      assert(pattern.match?("z".encode(Encoding::UTF_16BE)))
      assert(pattern.match?("😀".encode(Encoding::UTF_16BE)))
      assert(pattern.match?("😂".encode(Encoding::UTF_16BE)))
      refute(pattern.match?("A".encode(Encoding::UTF_16BE)))
      refute(pattern.match?("😃".encode(Encoding::UTF_16BE)))
    end

    def test_dot_metacharacter
      pattern = Pattern.new(".", Option::NONE, Encoding::UTF_16BE)
      assert(pattern.match?("a".encode(Encoding::UTF_16BE)))
      assert(pattern.match?("😀".encode(Encoding::UTF_16BE)))
      assert(pattern.match?("你".encode(Encoding::UTF_16BE)))
    end

    def test_quantifiers_with_unicode
      pattern = Pattern.new("😀+", Option::NONE, Encoding::UTF_16BE)
      assert(pattern.match?("😀".encode(Encoding::UTF_16BE)))
      assert(pattern.match?("😀😀😀".encode(Encoding::UTF_16BE)))
      refute(pattern.match?("😁".encode(Encoding::UTF_16BE)))
    end

    def test_alternation_with_unicode
      pattern = Pattern.new("😀|😁", Option::NONE, Encoding::UTF_16BE)
      assert(pattern.match?("😀".encode(Encoding::UTF_16BE)))
      assert(pattern.match?("😁".encode(Encoding::UTF_16BE)))
      refute(pattern.match?("😂".encode(Encoding::UTF_16BE)))
    end

    def test_character_class_digit
      pattern = Pattern.new("\\d+", Option::NONE, Encoding::UTF_16BE)
      assert(pattern.match?("123".encode(Encoding::UTF_16BE)))
      assert(pattern.match?("0".encode(Encoding::UTF_16BE)))
      refute(pattern.match?("abc".encode(Encoding::UTF_16BE)))
    end

    def test_character_class_word
      pattern = Pattern.new("\\w+", Option::NONE, Encoding::UTF_16BE)
      assert(pattern.match?("hello".encode(Encoding::UTF_16BE)))
      assert(pattern.match?("test123".encode(Encoding::UTF_16BE)))
      refute(pattern.match?("!!!".encode(Encoding::UTF_16BE)))
    end

    def test_anchors_start_and_end
      pattern = Pattern.new("^abc$", Option::NONE, Encoding::UTF_16BE)
      assert(pattern.match?("abc".encode(Encoding::UTF_16BE)))
      refute(pattern.match?("xabc".encode(Encoding::UTF_16BE)))
      refute(pattern.match?("abcx".encode(Encoding::UTF_16BE)))
    end

    def test_bmp_range_byte0_varies
      pattern = Pattern.new("[\u{100}-\u{1FF}]", Option::NONE, Encoding::UTF_16BE)
      assert(pattern.match?("\u{100}".encode(Encoding::UTF_16BE)))
      assert(pattern.match?("\u{1FF}".encode(Encoding::UTF_16BE)))
      refute(pattern.match?("\u{FF}".encode(Encoding::UTF_16BE)))
      refute(pattern.match?("\u{200}".encode(Encoding::UTF_16BE)))
    end

    def test_bmp_range_both_bytes_vary
      pattern = Pattern.new("[\u{1000}-\u{1FFF}]", Option::NONE, Encoding::UTF_16BE)
      assert(pattern.match?("\u{1000}".encode(Encoding::UTF_16BE)))
      assert(pattern.match?("\u{1500}".encode(Encoding::UTF_16BE)))
      assert(pattern.match?("\u{1FFF}".encode(Encoding::UTF_16BE)))
      refute(pattern.match?("\u{FFF}".encode(Encoding::UTF_16BE)))
      refute(pattern.match?("\u{2000}".encode(Encoding::UTF_16BE)))
    end

    def test_supplementary_plane_single
      pattern = Pattern.new("𐀀", Option::NONE, Encoding::UTF_16BE)
      assert(pattern.match?("𐀀".encode(Encoding::UTF_16BE)))
      refute(pattern.match?("𐀁".encode(Encoding::UTF_16BE)))
    end

    def test_supplementary_plane_range
      pattern = Pattern.new("[𐀀-𐀿]", Option::NONE, Encoding::UTF_16BE)
      assert(pattern.match?("𐀀".encode(Encoding::UTF_16BE)))
      assert(pattern.match?("𐀿".encode(Encoding::UTF_16BE)))
      refute(pattern.match?("a".encode(Encoding::UTF_16BE)))
      refute(pattern.match?("𐁀".encode(Encoding::UTF_16BE)))
    end

    def test_inverted_character_class
      pattern = Pattern.new("[^a-c]", Option::NONE, Encoding::UTF_16BE)
      refute(pattern.match?("a".encode(Encoding::UTF_16BE)))
      refute(pattern.match?("b".encode(Encoding::UTF_16BE)))
      refute(pattern.match?("c".encode(Encoding::UTF_16BE)))
      assert(pattern.match?("d".encode(Encoding::UTF_16BE)))
      assert(pattern.match?("😀".encode(Encoding::UTF_16BE)))
    end

    def test_complex_pattern
      pattern = Pattern.new("hello.*world", Option::NONE, Encoding::UTF_16BE)
      assert(pattern.match?("hello world".encode(Encoding::UTF_16BE)))
      assert(pattern.match?("hello beautiful world".encode(Encoding::UTF_16BE)))
      refute(pattern.match?("hello".encode(Encoding::UTF_16BE)))
    end

    def test_unicode_property_letter
      pattern = Pattern.new("\\p{Letter}+", Option::NONE, Encoding::UTF_16BE)
      assert(pattern.match?("hello".encode(Encoding::UTF_16BE)))
      assert(pattern.match?("你好".encode(Encoding::UTF_16BE)))
      refute(pattern.match?("123".encode(Encoding::UTF_16BE)))
    end

    def test_mixed_bmp_and_supplementary
      pattern = Pattern.new("[\u{FFFD}-\u{10001}]", Option::NONE, Encoding::UTF_16BE)
      assert(pattern.match?("\u{FFFD}".encode(Encoding::UTF_16BE)))
      assert(pattern.match?("\u{FFFE}".encode(Encoding::UTF_16BE)))
      assert(pattern.match?("\u{FFFF}".encode(Encoding::UTF_16BE)))
      assert(pattern.match?("\u{10000}".encode(Encoding::UTF_16BE)))
      assert(pattern.match?("\u{10001}".encode(Encoding::UTF_16BE)))
      refute(pattern.match?("\u{FFFC}".encode(Encoding::UTF_16BE)))
      refute(pattern.match?("\u{10002}".encode(Encoding::UTF_16BE)))
    end
  end
end
