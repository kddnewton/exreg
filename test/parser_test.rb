# frozen_string_literal: true

require "test_helper"

module Exreg
  class ParserTest < Minitest::Test
    def test_alternation
      parse("a|b|c") => AST::Pattern[
        AST::Expression[AST::MatchCharacter[value: "a"]],
        AST::Expression[AST::MatchCharacter[value: "b"]],
        AST::Expression[AST::MatchCharacter[value: "c"]]
      ]
    end

    def test_concatenation
      parse("abc") => AST::Pattern[AST::Expression[
        AST::MatchCharacter[value: "a"],
        AST::MatchCharacter[value: "b"],
        AST::MatchCharacter[value: "c"]
      ]]
    end

    def test_group
      parse("(a|b)") => AST::Pattern[AST::Expression[
        AST::Group[
          AST::Expression[
            AST::MatchCharacter[value: "a"]
          ],
          AST::Expression[
            AST::MatchCharacter[value: "b"]
          ]
        ]
      ]]
    end

    def test_match_character
      parse("a") => AST::Pattern[AST::Expression[
        AST::MatchCharacter[value: "a"]
      ]]
    end

    def test_match_any
      parse(".") => AST::Pattern[AST::Expression[
        AST::MatchAny
      ]]
    end

    def test_range_quantifier_single
      parse("a{3}") => AST::Pattern[AST::Expression[
        AST::Quantified[
          AST::MatchCharacter[value: "a"],
          AST::RangeQuantifier[minimum: 3, maximum: 3]
        ]
      ]]
    end

    def test_range_quantifier_endless
      parse("a{3,}") => AST::Pattern[AST::Expression[
        AST::Quantified[
          AST::MatchCharacter[value: "a"],
          AST::RangeQuantifier[minimum: 3, maximum: nil]
        ]
      ]]
    end

    def test_range_quantifier_beginless
      parse("a{,3}") => AST::Pattern[AST::Expression[
        AST::Quantified[
          AST::MatchCharacter[value: "a"],
          AST::RangeQuantifier[minimum: 0, maximum: 3]
        ]
      ]]
    end

    def test_range_quantifier_range
      parse("a{3,5}") => AST::Pattern[AST::Expression[
        AST::Quantified[
          AST::MatchCharacter[value: "a"],
          AST::RangeQuantifier[minimum: 3, maximum: 5]
        ]
      ]]
    end

    def test_star_quantifier
      parse("a*") => AST::Pattern[AST::Expression[
        AST::Quantified[
          AST::MatchCharacter[value: "a"],
          AST::StarQuantifier
        ]
      ]]
    end

    private

    def parse(source)
      Parser.new(source).parse.tap { |node| PP.pp(node, +"") }
    end
  end
end
