# frozen_string_literal: true

# Profile Exreg to identify performance bottlenecks.
#
# Usage: ruby bin/profile.rb

require_relative "../lib/exreg"
require "stackprof"

SHORT_TEXT = "The quick brown fox jumps over the lazy dog. 2024-01-15 user@test.com https://example.com 192.168.0.1"
MIXED_TEXT = begin
  srand(42)
  base = Array.new(1_000) { (("a".."z").to_a + ("A".."Z").to_a + ("0".."9").to_a + [" ", ".", "\n"]).sample }.join
  ["user@example.com", "alice.bob+tag@sub.domain.co.uk", "cat", "dog", "bird"].each do |needle|
    pos = rand(base.length)
    base.insert(pos, " #{needle} ")
  end
  base
end

CASES = [
  ["Literal: fox",              "fox",          SHORT_TEXT, 5_000],
  ["CharClass: [a-zA-Z]+",      "[a-zA-Z]+",    MIXED_TEXT, 2_000],
  ["Alternation: cat|dog|bird", "cat|dog|bird", MIXED_TEXT, 2_000],
  ["Unicode: \\w+",             "\\w+",         SHORT_TEXT, 1_000],
]

CASES.each do |name, pattern, haystack, iterations|
  exreg = Exreg::Pattern.new(pattern)
  10.times { exreg.match?(haystack) }

  profile = StackProf.run(mode: :wall, interval: 100, raw: true) do
    iterations.times { exreg.match?(haystack) }
  end

  puts "=" * 76
  puts "#{name}  (#{iterations} iterations)"
  puts "=" * 76
  StackProf::Report.new(profile).print_text(STDOUT, 20)
  puts
end
