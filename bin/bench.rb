# frozen_string_literal: true

# Benchmark comparing Exreg vs Ruby's built-in Regexp.
#
# Inspired by mariomka/regex-benchmark (Email, URI, IPv4 patterns) and
# BurntSushi/rebar (literal search, character classes, quantifiers, anchors,
# alternation, Unicode categories).
#
# Usage: ruby bin/bench.rb

$stdout.sync = true

require_relative "../lib/exreg"
require "benchmark"

# ---------------------------------------------------------------------------
# Input generation
# ---------------------------------------------------------------------------

SEED = 42
srand(SEED)

def random_string(len, alphabet = ("a".."z").to_a + ("A".."Z").to_a + ("0".."9").to_a + [" ", ".", "\n"])
  Array.new(len) { alphabet.sample }.join
end

def make_haystack_with_needles(base_len, needles, count)
  base = random_string(base_len)
  positions = (0...base.length).to_a.sample(count).sort.reverse
  positions.each { |pos| base.insert(pos, needles.sample) }
  base
end

# --- Haystacks ---

MIXED_TEXT = begin
  emails = ["user@example.com", "alice.bob+tag@sub.domain.co.uk", "x@y.z"]
  uris = ["https://example.com/path?q=1#frag", "http://foo.bar/baz", "ftp://files.example.org/pub"]
  ips = ["192.168.1.1", "255.255.255.255", "10.0.0.1", "172.16.254.1"]
  make_haystack_with_needles(1_000, emails + uris + ips, 10)
end

SHORT_TEXT = "The quick brown fox jumps over the lazy dog. 2024-01-15 user@test.com https://example.com 192.168.0.1"
LONG_ALPHA = ("abcdefghij" * 100)
DNA_TEXT = (["ACGT"] * 250).map { |s| s.chars.sample }.join
UNICODE_TEXT = "café résumé naïve über Ñoño 日本語テスト Привет мир " * 10

ITERATIONS = 10

# ---------------------------------------------------------------------------
# Benchmark runners
# ---------------------------------------------------------------------------

def run_match_bool(name, pattern, haystack, options: Exreg::Option::NONE)
  exreg = Exreg::Pattern.new(pattern, options)
  ruby = Regexp.new("(?u)#{pattern}", options)

  # Warm up
  exreg.match?(haystack)
  ruby.match?(haystack)

  exreg_time = Benchmark.realtime { ITERATIONS.times { exreg.match?(haystack) } }
  ruby_time = Benchmark.realtime { ITERATIONS.times { ruby.match?(haystack) } }

  exreg_ms = (exreg_time * 1000).round(2)
  ruby_ms = (ruby_time * 1000).round(2)
  ratio = ruby_ms > 0 ? (exreg_ms / ruby_ms).round(1) : Float::INFINITY

  [name, ruby_ms, exreg_ms, ratio]
end

def run_match_capture(name, pattern, haystack, options: Exreg::Option::NONE)
  exreg = Exreg::Pattern.new(pattern, options)
  ruby = Regexp.new("(?u)#{pattern}", options)

  # Warm up
  exreg.match(haystack)
  ruby.match(haystack)

  exreg_time = Benchmark.realtime { ITERATIONS.times { exreg.match(haystack) } }
  ruby_time = Benchmark.realtime { ITERATIONS.times { ruby.match(haystack) } }

  exreg_ms = (exreg_time * 1000).round(2)
  ruby_ms = (ruby_time * 1000).round(2)
  ratio = ruby_ms > 0 ? (exreg_ms / ruby_ms).round(1) : Float::INFINITY

  [name, ruby_ms, exreg_ms, ratio]
end

def print_table(title, header, rows)
  fmt = "%-42s %10s %10s %8s"
  puts title
  puts "-" * 74
  puts fmt % header
  puts "-" * 74
  rows.each { |r| puts fmt % [r[0], r[1], r[2], "#{r[3]}x"] }
  puts
end

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

puts "Exreg vs Ruby Regexp"
puts "=" * 74
puts "Ruby: #{RUBY_DESCRIPTION}"
puts "Iterations: #{ITERATIONS}"
puts "Haystack sizes: mixed=#{MIXED_TEXT.bytesize}B, short=#{SHORT_TEXT.bytesize}B, " \
     "alpha=#{LONG_ALPHA.bytesize}B, dna=#{DNA_TEXT.bytesize}B, " \
     "unicode=#{UNICODE_TEXT.bytesize}B"
puts

# --- Part 1: match? (boolean) ---
results = []

# mariomka patterns
results << run_match_bool("Email (mariomka)", '[\\w\\.+-]+@[\\w\\.-]+\\.[\\w\\.-]+', MIXED_TEXT)
results << run_match_bool("URI (mariomka)", '[\\w]+://[^/\\s?#]+[^\\s?#]+(?:\\?[^\\s#]*)?(?:#[^\\s]*)?', MIXED_TEXT)
results << run_match_bool("IPv4 (mariomka)", '(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)', MIXED_TEXT)

# Literal
results << run_match_bool("Literal hit (short)", "fox", SHORT_TEXT)
results << run_match_bool("Literal hit (long)", "abcdefghij", LONG_ALPHA)
results << run_match_bool("Literal miss (long)", "ZZZZZ", LONG_ALPHA)

# Character classes
results << run_match_bool("\\d+ (digits)", '\\d+', MIXED_TEXT)
results << run_match_bool("[a-zA-Z]+ (alpha)", '[a-zA-Z]+', MIXED_TEXT)
results << run_match_bool("\\w+ (word, short text)", '\\w+', SHORT_TEXT)
results << run_match_bool("\\w+ (word, Unicode)", '\\w+', UNICODE_TEXT)

# Quantifiers
results << run_match_bool("[ACGT]{4} (DNA 4-mer)", '[ACGT]{4}', DNA_TEXT)
results << run_match_bool("a{3,5} (bounded repeat)", 'a{3,5}', LONG_ALPHA)

# Alternation
results << run_match_bool("cat|dog|bird (3-way)", 'cat|dog|bird', MIXED_TEXT)
results << run_match_bool("Mon|Tue|...|Sun (7-way)", 'Mon|Tue|Wed|Thu|Fri|Sat|Sun', MIXED_TEXT)

# Anchors
results << run_match_bool("^The (BOL, multiline)", '^The', SHORT_TEXT, options: Exreg::Option::MULTILINE)
results << run_match_bool("\\Ahttps (BOS anchor)", '\\Ahttps', MIXED_TEXT)
results << run_match_bool("\\bfox\\b (word boundary)", '\\bfox\\b', SHORT_TEXT)

# Pathological
results << run_match_bool("a?^15 a^15 (classic NFA)", "a?" * 15 + "a" * 15, "a" * 15)
results << run_match_bool("a?^20 a^20 (classic NFA)", "a?" * 20 + "a" * 20, "a" * 20)
results << run_match_bool("a?^25 a^25 (classic NFA)", "a?" * 25 + "a" * 25, "a" * 25)

# Nested
results << run_match_bool("[a-z]+[0-9]+[a-z]+ (nested)", '[a-z]+[0-9]+[a-z]+', MIXED_TEXT)

print_table(
  "Part 1: match? (boolean)",
  ["Benchmark", "Regexp (ms)", "Exreg (ms)", "Ratio"],
  results
)

# --- Part 2: match (with captures) ---
results2 = []
results2 << run_match_capture("Email capture", '[\\w\\.+-]+@[\\w\\.-]+\\.[\\w\\.-]+', MIXED_TEXT)
results2 << run_match_capture("([a-z]+)@([a-z]+)", '([a-z]+)@([a-z]+)', MIXED_TEXT)
results2 << run_match_capture("(a?){15}a{15}", "(a?)" * 15 + "a" * 15, "a" * 15)
results2 << run_match_capture("(a?){20}a{20}", "(a?)" * 20 + "a" * 20, "a" * 20)

print_table(
  "Part 2: match (with captures)",
  ["Benchmark", "Regexp (ms)", "Exreg (ms)", "Ratio"],
  results2
)

# --- Part 3: Repeated matching (same pattern, many strings) ---
srand(SEED)
strings_50 = Array.new(50) { random_string(100) }

results3 = []
[
  ["\\d+ across 50 strings", '\\d+'],
  ["[a-z]+@[a-z]+ across 50 strings", '[a-z]+@[a-z]+'],
  ["[A-Z][a-z]+ across 50 strings", '[A-Z][a-z]+'],
].each do |name, pattern|
  exreg = Exreg::Pattern.new(pattern)
  ruby = Regexp.new("(?u)#{pattern}")

  # Warm up
  strings_50.each { |s| exreg.match?(s); ruby.match?(s) }

  exreg_time = Benchmark.realtime { ITERATIONS.times { strings_50.each { |s| exreg.match?(s) } } }
  ruby_time = Benchmark.realtime { ITERATIONS.times { strings_50.each { |s| ruby.match?(s) } } }

  exreg_ms = (exreg_time * 1000).round(2)
  ruby_ms = (ruby_time * 1000).round(2)
  ratio = ruby_ms > 0 ? (exreg_ms / ruby_ms).round(1) : Float::INFINITY
  results3 << [name, ruby_ms, exreg_ms, ratio]
end

print_table(
  "Part 3: Repeated matching (same pattern, 50 different strings)",
  ["Benchmark", "Regexp (ms)", "Exreg (ms)", "Ratio"],
  results3
)

puts "=" * 74
puts
puts "Legend:"
puts "  Regexp = Ruby's built-in Regexp (Oniguruma, C implementation)"
puts "  Exreg  = Exreg pattern engine (pure Ruby, Thompson NFA + lazy DFA)"
puts "  Ratio  = Exreg / Regexp (lower is better for Exreg, <1x means Exreg wins)"
