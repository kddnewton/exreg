# frozen_string_literal: true

module Exreg
  # This object is responsible for turning a source string into an AST::Pattern
  # node.
  class Parser
    # We build a custom enumerator here to make it easier to rollback to a
    # specific point. This is necessary to support arbitrary lookahead.
    class Lexer
      class Rollback < StandardError
      end

      attr_reader :tokens, :cached, :index

      def initialize(source)
        @tokens = make_tokens(source)
        @cached = []
        @index = 0
      end

      def next
        cached << tokens.next if index == cached.length
        result = cached[index]

        @index += 1
        result
      end

      def peek
        index == cached.length ? tokens.peek : cached[index]
      end

      def rollback
        raise Rollback
      end

      def transaction
        saved_index = @index
        yield
      rescue Rollback
        @index = saved_index
        nil
      end

      private

      # This walks through the source of the regular expression and yields each
      # lexical token (AST::Token) it finds in the source back to an enumerator.
      def make_tokens(source)
        Enumerator.new do |enum|
          index = 0

          while index < source.length
            type =
              case source[index..]
              in /\A\./   then :dot
              in /\A\*/   then :star
              in /\A\+/   then :plus
              in /\A\?/   then :qmark
              in /\A\|/   then :pipe
              in /\A\{/   then :lbrace
              in /\A\}/   then :rbrace
              in /\A\(/   then :lparen
              in /\A\)/   then :rparen
              in /\A\[/   then :lbracket
              in /\A\]/   then :rbracket
              in /\A-/    then :dash
              in /\A,/    then :comma
              in %r{\A\\} then :backslash
              in /\A./    then :char
              end

            location = AST::Location[index...(index + $&.length)]
            enum << AST::Token.new(type: type, value: $&, location: location)
            index += $&.length
          end

          location = AST::Location[index...index]
          enum << AST::Token.new(type: :EOF, value: nil, location: location)
        end
      end
    end

    attr_reader :source, :flags

    def initialize(source, flags = Flags.new)
      @source = source
      @flags = flags
    end

    # This parses the regular expression and returns an AST::Pattern node.
    def parse
      parse_pattern(Lexer.new(source))
    end

    private

    # This creates an AST::Pattern object that is the root of the AST. It parses
    # each expression in turn, then gathers them up together.
    def parse_pattern(tokens)
      expressions = [parse_expression(tokens)]

      while tokens.peek in { type: :pipe }
        tokens.next
        expressions << parse_expression(tokens)
      end

      tokens.next => { type: :EOF }
      location = AST::Location[0...source.length]
      AST::Pattern.new(expressions: expressions, location: location)
    end

    # This creates an AST::Expression object that contains a list of items to
    # match in sequence.
    def parse_expression(tokens)
      items = []
      items << parse_item(tokens) until (tokens.peek in { type: :pipe | :EOF | :rparen })

      location =
        if items.any?
          items.first.location.to(items.last.location)
        else
          tokens.peek.location
        end

      AST::Expression.new(items: items, location: location)
    end

    # This creates an AST::MatchCharacter or AST::Quantified object that
    # represents an item within an expression to match.
    def parse_item(tokens)
      item =
        case tokens.peek
        in { type: :lbracket }
          parse_lbracket(tokens)
        in { type: :backslash }
          parse_escaped(tokens)
        in { type: :char | :lbrace | :rbrace, value:, location: }
          tokens.next
          AST::MatchCharacter.new(value: value, location: location)
        in { type: :dot, location: }
          tokens.next
          AST::MatchAny.new(location: location)
        in { type: :lparen }
          parse_group(tokens)
        end

      if (quantifier = maybe_parse_quantifier(tokens))
        item =
          AST::Quantified.new(
            item: item,
            quantifier: quantifier,
            location: item.location.to(quantifier.location)
          )
      end

      item
    end

    # This creates either an AST::POSIXClass or an AST::MatchSet.
    def parse_lbracket(tokens)
      tokens.next => { type: :lbracket, location: slocation }

      if tokens.peek in { type: :lbracket }
        parse_posix_class(tokens, slocation)
      else
        parse_character_set(tokens, slocation)
      end
    end

    # This creates an AST::POSIXClass.
    def parse_posix_class(tokens, slocation)
      tokens.next => { type: :lbracket }
      tokens.next => { type: :char, value: ":" }

      name = +""
      loop do
        case tokens.next
        in { type: :char, value: ":" }
          break
        in { type: :char, value: }
          name << value
        end
      end

      tokens.next => { type: :rbracket }
      tokens.next => { type: :rbracket, location: elocation }

      AST::POSIXClass.new(name: name.downcase.to_sym, location: slocation.to(elocation))
    end

    # This creates an AST::MatchSet which contains a list of AST::MatchCharacter
    # and AST::MatchRange objects.
    def parse_character_set(tokens, slocation)
      items = []

      loop do
        case tokens.next
        in { type: :rbracket, location: elocation }
          return AST::MatchSet.new(items: items, inverted: false, location: slocation.to(elocation))
        in { value: svalue, location: }
          if tokens.peek in { type: :dash }
            tokens.next
            tokens.next => { value: evalue, location: elocation }
            items << AST::MatchRange.new(from: svalue, to: evalue, location: location.to(elocation))
          else
            items << AST::MatchCharacter.new(value: svalue, location: location)
          end
        end
      end
    end

    # This creates either a MatchProperty (if the escaped value is a character
    # property) or a MatchCharacter.
    def parse_escaped(tokens)
      tokens.next => { type: :backslash, location: }

      case tokens.next
      in { type: :char, value: "d", location: escaped }
        AST::MatchClass.new(name: :digit, location: location.to(escaped))
      in { type: :char, value: "h", location: escaped }
        AST::MatchClass.new(name: :hex, location: location.to(escaped))
      in { type: :char, value: "p", location: escaped }
        if tokens.peek in { type: :lbrace }
          tokens.next

          value = +""
          value << tokens.next.value until tokens.peek in { type: :rbrace }

          tokens.next => { type: :rbrace, location: property }
          AST::MatchProperty.new(value: value, location: location.to(property))
        else
          AST::MatchCharacter.new(value: value, location: location.to(escaped))
        end
      in { type: :char, value: "s", location: escaped }
        AST::MatchClass.new(name: :space, location: location.to(escaped))
      in { type: :char, value: "w", location: escaped }
        AST::MatchClass.new(name: :word, location: location.to(escaped))
      in { value:, location: escaped }
        AST::MatchCharacter.new(value: value, location: location.to(escaped))
      end
    end

    # This creates an AST::Group object that contains a list of expressions to
    # match.
    def parse_group(tokens)
      start = tokens.next
      start => { type: :lparen }

      expressions = []

      loop do
        case tokens.peek
        in { type: :rparen }
          break
        in { type: :pipe }
          tokens.next
        else
          expressions << parse_expression(tokens)
        end
      end

      tokens.peek => { type: :rparen }
      location = start.location.to(tokens.next.location)
      AST::Group.new(expressions: expressions, location: location)
    end

    # This creates an AST::StarQuantifier object if the next token is a star,
    # otherwise it will return nil.
    def maybe_parse_quantifier(tokens)
      case tokens.peek
      in { type: :star, location: }
        tokens.next
        AST::StarQuantifier.new(location: location)
      in { type: :plus, location: }
        tokens.next
        AST::PlusQuantifier.new(location: location)
      in { type: :qmark, location: }
        tokens.next
        AST::OptionalQuantifier.new(location: location)
      in { type: :lbrace }
        maybe_parser_range_quantifier(tokens)
      else
        # No quantifier, so return nil.
      end
    end

    # This creates an AST::RangeQuantifier object that contains a minimum and
    # maximum number of times to match if the tokens match the correct pattern.
    # This can match a couple of different combinations:
    #
    #     {n}
    #     {n,}
    #     {,m}
    #     {n,m}
    #
    def maybe_parser_range_quantifier(tokens)
      # There can't be any spaces between the braces and the numbers/comma. In
      # order to properly match this, we need the lexer to be able to rollback
      # to a specific point, so we'll use a transaction here. We'll build a
      # little state machine that can help us navigate the parsing.
      #
      #                  ┌───────┐                 ┌─────────┐ ────────────┐
      # ──── lbrace ───> │ start │ ──── digit ───> │ minimum │             │
      #                  └───────┘                 └─────────┘ <─── digit ─┘
      #                      │                       │    │
      #   ┌───────┐          │                       │  rbrace
      #   │ comma │ <───── comma  ┌──── comma ───────┘    │
      #   └───────┘               V                       V
      #      │             ┌─────────┐               ┌─────────┐
      #      └── digit ──> │ maximum │ ── rbrace ──> │| final |│
      #                    └─────────┘               └─────────┘
      #                    │         ^
      #                    └─ digit ─┘
      #
      minimum_digits = []
      maximum_digits = []

      tokens.transaction do
        tokens.next => { type: :lbrace, location: start_location }
        state = :start

        loop do
          case [state, tokens.next]
          in [:start, { type: :char, value: /\d/ => value }]
            minimum_digits << value
            state = :minimum
          in [:start, { type: :comma }]
            state = :comma
          in [:minimum, { type: :char, value: /\d/ => value }]
            minimum_digits << value
          in [:minimum, { type: :comma }]
            state = :maximum
          in [:minimum, { type: :rbrace, location: end_location }]
            minimum = minimum_digits.join.to_i

            return AST::RangeQuantifier.new(
              minimum: minimum,
              maximum: minimum,
              location: start_location.to(end_location)
            )
          in [:comma, { type: :char, value: /\d/ => value }]
            maximum_digits << value
            state = :maximum
          in [:maximum, { type: :char, value: /\d/ => value }]
            maximum_digits << value
          in [:maximum, { type: :rbrace, location: end_location }]
            return AST::RangeQuantifier.new(
              minimum: minimum_digits.empty? ? 0 : minimum_digits.join.to_i,
              maximum: maximum_digits.empty? ? nil : maximum_digits.join.to_i,
              location: start_location.to(end_location)
            )
          else
            tokens.rollback
          end
        end
      end
    end
  end
end
