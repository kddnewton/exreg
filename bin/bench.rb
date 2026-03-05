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

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def monotonic_now
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def elapsed_ms
  t0 = monotonic_now
  yield
  (monotonic_now - t0) * 1000
end

def print_table(title, header, rows, fmt, &block)
  width = fmt.scan(/%[^%]*[sd]/).sum { |f| f[/\d+/].to_i + 1 }
  puts title
  puts "-" * width
  puts fmt % header
  puts "-" * width
  rows.each(&(block || ->(r) { puts fmt % r }))
  puts
end

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

MATCH_ITERATIONS = 1_000

# ---------------------------------------------------------------------------
# Match benchmark runners
# ---------------------------------------------------------------------------

def run_match(name, pattern, haystack, method: :match?, options: Exreg::Option::NONE)
  exreg = Exreg::Pattern.new(pattern, options)
  ruby = Regexp.new("(?u)#{pattern}", options)

  exreg.public_send(method, haystack)
  ruby.public_send(method, haystack)

  exreg_ms = elapsed_ms { MATCH_ITERATIONS.times { exreg.public_send(method, haystack) } }
  ruby_ms = elapsed_ms { MATCH_ITERATIONS.times { ruby.public_send(method, haystack) } }
  ratio = ruby_ms > 0 ? exreg_ms / ruby_ms : Float::INFINITY

  [name, ruby_ms, exreg_ms, ratio]
end

def print_match_table(title, rows)
  fmt = "%-42s %11s %11s %8s"
  print_table(title, ["Benchmark", "Regexp (ms)", "Exreg (ms)", "Ratio"], rows, fmt) do |r|
    ratio_str = r[3] == Float::INFINITY ? "Inf" : "%.1f" % r[3]
    puts fmt % [r[0], "%.2f" % r[1], "%.2f" % r[2], "#{ratio_str}x"]
  end
end

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------

puts "Exreg Benchmark"
puts "=" * 76
puts "Ruby: #{RUBY_DESCRIPTION}"
puts "Haystack sizes: mixed=#{MIXED_TEXT.bytesize}B, short=#{SHORT_TEXT.bytesize}B, " \
     "alpha=#{LONG_ALPHA.bytesize}B, dna=#{DNA_TEXT.bytesize}B, " \
     "unicode=#{UNICODE_TEXT.bytesize}B"
puts

# ---------------------------------------------------------------------------
# Part 1: Compilation
# ---------------------------------------------------------------------------

COMPILE_WARMUP = 2
COMPILE_ITERATIONS = 10

COMPILE_PATTERNS = {
  "literal (short)" => "foo",
  "literal (medium)" => "abcdefghij",
  "literal (long)" => "the quick brown fox",
  "[a-z]+" => '[a-z]+',
  "[a-zA-Z0-9]+" => '[a-zA-Z0-9]+',
  "\\d+" => '\\d+',
  "\\w+" => '\\w+',
  "\\s+" => '\\s+',
  "[[:alpha:]]+" => '[[:alpha:]]+',
  "[[:digit:]]+" => '[[:digit:]]+',
  "[[:word:]]+" => '[[:word:]]+',
  "[[:space:]]+" => '[[:space:]]+',
  "3-way alt" => 'cat|dog|bird',
  "7-way alt" => 'Mon|Tue|Wed|Thu|Fri|Sat|Sun',
  "a{3,5}" => 'a{3,5}',
  "[ACGT]{4}" => '[ACGT]{4}',
  "^The (multiline)" => ['^The', Exreg::Option::MULTILINE],
  "\\bfox\\b" => '\\bfox\\b',
  "email-like" => '[\\w\\.+-]+@[\\w\\.-]+\\.[\\w\\.-]+',
  "URI-like" => '[\\w]+://[^/\\s?#]+[^\\s?#]+(?:\\?[^\\s#]*)?(?:#[^\\s]*)?',
  "IPv4-like" => '(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)',
  "a?^15 a^15" => "a?" * 15 + "a" * 15,
  "a?^20 a^20" => "a?" * 20 + "a" * 20,
  "a?^25 a^25" => "a?" * 25 + "a" * 25,
  "[a-z]+[0-9]+[a-z]+" => '[a-z]+[0-9]+[a-z]+',
  "([a-z]+)@([a-z]+)" => '([a-z]+)@([a-z]+)',
}

compile_fmt = "%-42s %11s %11s"
compile_rows = []

COMPILE_PATTERNS.each do |name, entry|
  source, options = entry.is_a?(Array) ? entry : [entry, Exreg::Option::NONE]
  COMPILE_WARMUP.times { Exreg::Pattern.new(source, options) }
  total_ms = elapsed_ms { COMPILE_ITERATIONS.times { Exreg::Pattern.new(source, options) } }
  compile_rows << [name, total_ms, total_ms / COMPILE_ITERATIONS]
end

print_table(
  "Part 1: Compilation (warmup=#{COMPILE_WARMUP}, iterations=#{COMPILE_ITERATIONS})",
  ["Pattern", "Total (ms)", "Per-iter"],
  compile_rows,
  compile_fmt
) do |r|
  puts compile_fmt % [r[0], "%.2f" % r[1], "%.2f ms" % r[2]]
end

# ---------------------------------------------------------------------------
# Part 2: match? (boolean)
# ---------------------------------------------------------------------------

results = []

# mariomka patterns
results << run_match("Email (mariomka)", '[\\w\\.+-]+@[\\w\\.-]+\\.[\\w\\.-]+', MIXED_TEXT)
results << run_match("URI (mariomka)", '[\\w]+://[^/\\s?#]+[^\\s?#]+(?:\\?[^\\s#]*)?(?:#[^\\s]*)?', MIXED_TEXT)
results << run_match("IPv4 (mariomka)", '(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)', MIXED_TEXT)

# Literal
results << run_match("Literal hit (short)", "fox", SHORT_TEXT)
results << run_match("Literal hit (long)", "abcdefghij", LONG_ALPHA)
results << run_match("Literal miss (long)", "ZZZZZ", LONG_ALPHA)

# Character classes
results << run_match("\\d+ (digits)", '\\d+', MIXED_TEXT)
results << run_match("[a-zA-Z]+ (alpha)", '[a-zA-Z]+', MIXED_TEXT)
results << run_match("\\w+ (word, short text)", '\\w+', SHORT_TEXT)
results << run_match("\\w+ (word, Unicode)", '\\w+', UNICODE_TEXT)

# Quantifiers
results << run_match("[ACGT]{4} (DNA 4-mer)", '[ACGT]{4}', DNA_TEXT)
results << run_match("a{3,5} (bounded repeat)", 'a{3,5}', LONG_ALPHA)

# Alternation
results << run_match("cat|dog|bird (3-way)", 'cat|dog|bird', MIXED_TEXT)
results << run_match("Mon|Tue|...|Sun (7-way)", 'Mon|Tue|Wed|Thu|Fri|Sat|Sun', MIXED_TEXT)

# Anchors
results << run_match("^The (BOL, multiline)", '^The', SHORT_TEXT, options: Exreg::Option::MULTILINE)
results << run_match("\\Ahttps (BOS anchor)", '\\Ahttps', MIXED_TEXT)
results << run_match("\\bfox\\b (word boundary)", '\\bfox\\b', SHORT_TEXT)

# Pathological
results << run_match("a?^15 a^15 (classic NFA)", "a?" * 15 + "a" * 15, "a" * 15)
results << run_match("a?^20 a^20 (classic NFA)", "a?" * 20 + "a" * 20, "a" * 20)
results << run_match("a?^25 a^25 (classic NFA)", "a?" * 25 + "a" * 25, "a" * 25)

# Nested
results << run_match("[a-z]+[0-9]+[a-z]+ (nested)", '[a-z]+[0-9]+[a-z]+', MIXED_TEXT)

print_match_table("Part 2: match? (boolean, iterations=#{MATCH_ITERATIONS})", results)

# ---------------------------------------------------------------------------
# Part 3: match (with captures)
# ---------------------------------------------------------------------------

results2 = []
results2 << run_match("Email capture", '[\\w\\.+-]+@[\\w\\.-]+\\.[\\w\\.-]+', MIXED_TEXT, method: :match)
results2 << run_match("([a-z]+)@([a-z]+)", '([a-z]+)@([a-z]+)', MIXED_TEXT, method: :match)
results2 << run_match("(a?){15}a{15}", "(a?)" * 15 + "a" * 15, "a" * 15, method: :match)
results2 << run_match("(a?){20}a{20}", "(a?)" * 20 + "a" * 20, "a" * 20, method: :match)

print_match_table("Part 3: match (with captures, iterations=#{MATCH_ITERATIONS})", results2)

# ---------------------------------------------------------------------------
# Part 4: Repeated matching (same pattern, many strings)
# ---------------------------------------------------------------------------

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

  strings_50.each { |s| exreg.match?(s); ruby.match?(s) }

  exreg_ms = elapsed_ms { MATCH_ITERATIONS.times { strings_50.each { |s| exreg.match?(s) } } }
  ruby_ms = elapsed_ms { MATCH_ITERATIONS.times { strings_50.each { |s| ruby.match?(s) } } }
  ratio = ruby_ms > 0 ? exreg_ms / ruby_ms : Float::INFINITY
  results3 << [name, ruby_ms, exreg_ms, ratio]
end

print_match_table("Part 4: Repeated matching (same pattern, 50 different strings, iterations=#{MATCH_ITERATIONS})", results3)

# ---------------------------------------------------------------------------
# Footer
# ---------------------------------------------------------------------------

puts "=" * 76
puts
puts "Legend:"
puts "  Regexp = Ruby's built-in Regexp (Oniguruma, C implementation)"
puts "  Exreg  = Exreg pattern engine (pure Ruby, Thompson NFA + lazy DFA)"
puts "  Ratio  = Exreg / Regexp (lower is better for Exreg, <1x means Exreg wins)"
