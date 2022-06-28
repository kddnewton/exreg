# frozen_string_literal: true

require "set"

require_relative "exreg/alphabet"
require_relative "exreg/ast"
require_relative "exreg/automaton"
require_relative "exreg/bytecode"
require_relative "exreg/dfa"
require_relative "exreg/digraph"
require_relative "exreg/flags"
require_relative "exreg/nfa"
require_relative "exreg/parser"
require_relative "exreg/unicode"

require_relative "exreg/encoding/utf8"

require_relative "exreg/strategy/backtracking"
require_relative "exreg/strategy/deterministic"

module Exreg
  # This is the main class that represents a regular expression. It effectively
  # mirrors Regexp from core Ruby.
  class Pattern
    attr_reader :source, :flags, :machine

    def initialize(source, flags = "")
      @source = source
      @flags = Flags[flags]
      @machine = Strategy::Deterministic.new(dfa)
    end

    def ast
      # We inject .* into the source so that when we loop over the input strings
      # to check for matches we don't have to look at every index in the string.
      Parser.new(".*#{source}", flags).parse
    end

    def nfa
      NFA.compile(ast)
    end

    def dfa
      DFA.compile(nfa)
    end

    def bytecode
      Bytecode.compile(dfa)
    end

    def match?(string)
      machine.match?(string)
    end
  end
end
