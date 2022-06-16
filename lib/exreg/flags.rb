# frozen_string_literal: true

module Exreg
  # These represent flags that can be passed to the regexp constructor. They
  # mirror the ones found in Ruby (and indeed use the same constants).
  class Flags
    VALUES = {
      "i" => Regexp::IGNORECASE,
      "m" => Regexp::MULTILINE,
      "x" => Regexp::EXTENDED
    }

    attr_reader :value

    def initialize(value = 0)
      @value = value
    end

    def ignore_case?
      flag?(Regexp::IGNORECASE)
    end

    def multiline?
      flag?(Regexp::MULTILINE)
    end

    def extended?
      flag?(Regexp::EXTENDED)
    end

    def self.[](string)
      new(string.chars.map { |flag| VALUES.fetch(flag) }.reduce(:|))
    end

    private

    def flag?(flag)
      (value & flag) != 0
    end
  end
end
