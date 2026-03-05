# frozen_string_literal: true

require "strscan"
require "set"

module Exreg
  class InternalError < StandardError; end
  class SyntaxError < StandardError; end

  # A set of Unicode code points represented as a collection of half-open
  # ranges.
  class USet
    protected attr_reader :ranges

    # Equivalent to creating a new USet and adding each of the given values.
    def self.[](*values)
      new { |set| values.each { |value| set.add(value) } }
    end

    def initialize
      @ranges = []
      yield self if block_given?
      @ranges.freeze
      freeze
    end

    # Determine if the given codepoint value is included in the set.
    def has?(value)
      found = @ranges.bsearch { |range| range.end > value }
      found && found.begin <= value
    end

    # True if no codepoints are included in the set.
    def empty?
      @ranges.empty?
    end

    # Invert the set by returning a new USet that contains all codepoints not in
    # this set.
    def invert
      USet[0...0x110000] - self
    end

    # Create and return a new USet that includes all codepoints that are
    # case-insensitively equivalent to codepoints in this set through common
    # case folding.
    def common_case_fold
      UCD.common_case_fold(self)
    end

    # Add a value to the set. The value may be an Integer representing a
    # specific codepoint or a Range representing a range of codepoints. This
    # will also merge overlapping or adjacent ranges as necessary.
    def add(value)
      rbegin, rend =
        case value
        when Integer
          [value, value + 1]
        when Range
          [value.begin, value.end + (value.exclude_end? ? 0 : 1)]
        else
          raise InternalError, "value must be Integer or Range: #{value.inspect}"
        end

      if rbegin < rend
        idx = @ranges.bsearch_index { |current| current.end >= rbegin } || @ranges.length
        while idx < @ranges.length && @ranges[idx].begin <= rend
          current = @ranges[idx]
          rbegin = [rbegin, current.begin].min
          rend = [rend, current.end].max
          @ranges.delete_at(idx)
        end

        @ranges.insert(idx, rbegin...rend)
      end
    end

    # Iterate over each half-open range in the set.
    def each_range(&block)
      return enum_for(:each_range) unless block_given?
      @ranges.each(&block)
    end

    # Perform a union with another USet, returning a new USet that contains all
    # codepoints in either set.
    def union(other)
      USet.new do |result|
        left_idx = 0
        right_idx = 0

        while left_idx < @ranges.length || right_idx < other.ranges.length
          left = @ranges[left_idx]
          right = other.ranges[right_idx]

          if right.nil? || (left && left.begin <= right.begin)
            result.add(left)
            left_idx += 1
          else
            result.add(right)
            right_idx += 1
          end
        end
      end
    end
    alias | union

    # Perform an intersection with another USet, returning a new USet that
    # contains only codepoints in both sets.
    def intersection(other)
      USet.new do |result|
        left_idx = 0
        right_idx = 0

        while left_idx < @ranges.length && right_idx < other.ranges.length
          left = @ranges[left_idx]
          right = other.ranges[right_idx]

          range = [left.begin, right.begin].max...[left.end, right.end].min
          range = yield range, right_idx if block_given?
          result.add(range)

          if left.end < right.end
            left_idx += 1
          else
            right_idx += 1
          end
        end
      end
    end
    alias & intersection

    # Perform a difference with another USet, returning a new USet that contains
    # only codepoints in this set that are not in the other set.
    def difference(other)
      USet.new do |result|
        begin_idx = 0

        @ranges.each do |range|
          cursor = range.begin

          while begin_idx < other.ranges.length && other.ranges[begin_idx].end <= cursor
            begin_idx += 1
          end

          end_idx = begin_idx
          while end_idx < other.ranges.length && other.ranges[end_idx].begin < range.end
            right = other.ranges[end_idx]

            result.add(cursor...right.begin)
            cursor = [cursor, right.end].max

            break if cursor >= range.end
            end_idx += 1
          end

          result.add(cursor...range.end)
        end
      end
    end
    alias - difference
  end

  # The Unicode Character Database, loaded from the serialized binary format as
  # determined by the rake file. This is used to lazily reify USet
  # instances when a property is requested, to avoid loading a whole bunch of
  # data into memory at once.
  #
  # The binary format is as follows:
  #
  #     EXREG     - magic number (5 bytes)
  #     props #   - number of properties (16-bit unsigned native-endian)
  #     props off - offset to property names (32-bit unsigned native-endian)
  #     casef off - offset to case folding data (32-bit unsigned native-endian)
  #     casef deltas - offset to case folding deltas (32-bit unsigned native-endian)
  #
  #     ... for each property ...
  #     ranges #  - number of half-open ranges (16-bit unsigned native-endian)
  #     ... for each half-open range ...
  #     range beg - range begin (32-bit unsigned native-endian)
  #     range end - range end (32-bit unsigned native-endian)
  #
  #     ... for each property ...
  #     name      - null-terminated string
  #     offset    - offset to property values (32-bit unsigned native-endian)
  #
  #     casef #   - number of common case folding segments (16-bit unsigned native-endian)
  #     ... for each case folding segment ...
  #     lower     - lower codepoint where folding starts (32-bit unsigned native-endian)
  #     upper     - upper codepoint where folding ends (32-bit unsigned native-endian)
  #     ... for each case folding segment
  #     delta     - delta to add to codepoints in this range to get their folded equivalent (32-bit signed native-endian)
  #
  # Therefore the portion stored in memory is a mapping from property names to
  # offsets in the binary data where the ranges for that property can be found.
  # When a property is requested, the data is read from the binary and a
  # USet instance is constructed and returned.
  module UCD
    class << self
      # Retrieve the USet for the given property name, or nil if the property is
      # not defined.
      def [](name)
        offset = @names[name]
        read_uset(offset) if offset
      end

      # Return a new USet that includes all codepoints that are
      # case-insensitively equivalent to codepoints in the given USet through
      # common case folding.
      def common_case_fold(uset)
        uset |
          uset.intersection(read_uset(@casef_cursor)) do |range, index|
            delta = @data.unpack1("l", offset: @casef_deltas + index * 4)
            (range.begin + delta)...(range.end + delta)
          end
      end

      private

      # Read a USet from the binary data at the given offset.
      def read_uset(offset)
        USet.new do |set|
          nranges = @data.unpack1("S", offset: offset)
          offset += 2

          nranges.times do
            rbegin, rend = @data.unpack("LL", offset: offset)
            set.add(rbegin...rend)
            offset += 8
          end
        end
      end
    end

    # Immediately executed code to load the binary data and build the property
    # name to offset mapping.
    @data = File.binread(File.expand_path(File.join("exreg", "unicode.data"), __dir__))
    magic, nprops, prop_cursor, @casef_cursor, @casef_deltas = @data.unpack("A5SLLL")
    raise if magic != "EXREG"

    @names = {}
    nprops.times do
      name, offset = @data.unpack("Z*L", offset: prop_cursor)
      @names[name] = offset
      prop_cursor += name.bytesize + 1 + 4
    end
  end

  # An immutable set of byte values from 0 to 255 represented as a collection of
  # 32-bit bitmaps.
  class ByteSet
    protected attr_reader :bitmaps

    # Create a ByteSet that includes all bytes in the given range.
    def self.[](range)
      bitmaps = [0, 0, 0, 0, 0, 0, 0, 0]

      start_byte = range.begin
      end_byte = range.end
      end_byte -= 1 if range.exclude_end?

      raise InternalError, "Byte out of range: #{start_byte}" unless (0..255).cover?(start_byte)
      raise InternalError, "Byte out of range: #{end_byte}" unless (0..255).cover?(end_byte)

      if start_byte <= end_byte
        start_idx = start_byte / 32
        end_idx = end_byte / 32

        start_bit = start_byte % 32
        end_bit = end_byte % 32

        if start_idx == end_idx
          bitmaps[start_idx] |= ((1 << (end_bit - start_bit + 1)) - 1) << start_bit
        else
          bitmaps[start_idx] |= 0xFFFFFFFF ^ ((1 << start_bit) - 1)
          ((start_idx + 1)...end_idx).each { |idx| bitmaps[idx] = 0xFFFFFFFF }
          bitmaps[end_idx] |= (1 << (end_bit + 1)) - 1
        end
      end

      new(bitmaps)
    end

    def initialize(bitmaps = [0, 0, 0, 0, 0, 0, 0, 0])
      @bitmaps = bitmaps.freeze
      freeze
    end

    # True if the given byte is included in the set.
    def has?(byte)
      @bitmaps[byte >> 5].anybits?(1 << (byte & 31))
    end

    # True if no bytes are included in the set.
    def empty?
      @bitmaps.all?(&:zero?)
    end

    # Return the single byte value if exactly one byte is set, nil otherwise.
    def single
      count = 0
      single = nil
      @bitmaps.each_with_index do |bitmap, idx|
        next if bitmap == 0
        b = bitmap
        while b != 0
          count += 1
          return nil if count > 1
          single = idx * 32 + (b & -b).bit_length - 1
          b &= b - 1
        end
      end
      single
    end

    # Perform a union with another ByteSet, returning a new ByteSet that
    # contains all bytes in either set.
    def union(other)
      ByteSet.new(@bitmaps.zip(other.bitmaps).map { |a, b| a | b })
    end
    alias | union

    # Create and return a new ByteSet that is the inversion of this set.
    def invert
      ByteSet.new(@bitmaps.map { |bitmap| ~bitmap & 0xFFFFFFFF })
    end

    # Iterate over each byte value in the set.
    def each
      return enum_for(:each) unless block_given?
      @bitmaps.each_with_index do |bitmap, idx|
        base = idx * 32
        b = bitmap
        while b != 0
          bit = b & -b
          yield base + bit.bit_length - 1
          b &= b - 1
        end
      end
    end

    # Two ByteSets are equal if they have the same bitmaps.
    def ==(other)
      other.is_a?(ByteSet) && @bitmaps == other.bitmaps
    end
    alias eql? ==

    # Hash based on the bitmaps to allow deduplication.
    def hash
      @bitmaps.hash
    end
  end

  # Partitions bytes 0..255 into equivalence classes such that bytes behaving
  # identically across all consume instructions share a class. This reduces
  # DFA transition tables from 256 entries to num_classes entries.
  class ByteEquivalenceClasses
    attr_reader :byte_to_class, :num_classes, :representatives

    def initialize(insns)
      byte_to_class = Array.new(256, 0)
      class_sizes = [256]
      num_classes = 1
      seen_sets = {}

      insns.each do |insn|
        case insn[0]
        when :consume_exact
          byte = insn[1]
          next unless byte < 256
          old_cls = byte_to_class[byte]
          if class_sizes[old_cls] > 1
            byte_to_class[byte] = num_classes
            class_sizes[old_cls] -= 1
            class_sizes << 1
            num_classes += 1
          end
        when :consume_set
          set = insn[1]
          next if seen_sets[set]
          seen_sets[set] = true

          # Count how many bytes of each class are in the set, iterating
          # only the set bits rather than all 256 bytes.
          class_in_count = Hash.new(0)
          set.each { |b| class_in_count[byte_to_class[b]] += 1 }

          # A class is split when it has members both in and out of the set.
          remap = {}
          class_in_count.each do |cls, in_count|
            if in_count < class_sizes[cls]
              remap[cls] = num_classes
              class_sizes[cls] -= in_count
              class_sizes << in_count
              num_classes += 1
            end
          end

          # Remap bytes in the set that belong to split classes, again
          # iterating only the set bits.
          unless remap.empty?
            set.each do |b|
              new_cls = remap[byte_to_class[b]]
              byte_to_class[b] = new_cls if new_cls
            end
          end
        end
      end

      @byte_to_class = byte_to_class.freeze
      @num_classes = num_classes
      @representatives = Array.new(num_classes)
      256.times do |b|
        cls = byte_to_class[b]
        @representatives[cls] ||= b
      end
      @representatives.freeze
      freeze
    end
  end

  # The parser that converts a regex pattern string into an abstract syntax
  # tree.
  class Parser < StringScanner
    def parse
      node = parse_expr
      raise SyntaxError, "Unmatched ')'" unless eos?
      node
    end

    private

    def parse_expr
      node = parse_seq
      node = [:alt, node, parse_seq] while skip("|")
      node
    end

    def parse_seq
      seq = []

      while !eos? && !match?(/[|)]/)
        if scan(/\(\?#[^)]*(\)?)/)
          raise SyntaxError, "Unterminated comment" if self[1].empty?
        else
          seq << parse_quant
        end
      end

      return [:seq, seq] if seq.length != 1
      seq[0]
    end

    def parse_quant_mode
      case
      when skip("?") then :lazy
      when skip("+") then :possessive
      else :greedy
      end
    end

    def parse_quant
      term = parse_term

      case
      when skip("*") then [:quant, term, 0, nil, parse_quant_mode]
      when skip("+") then [:quant, term, 1, nil, parse_quant_mode]
      when skip("?") then [:quant, term, 0, 1, parse_quant_mode]
      when scan(/\{\s*(\d+)\s*\}/)
        amount = Integer(self[1])
        [:quant, term, amount, amount, parse_quant_mode]
      when scan(/\{\s*(\d+)\s*,\s*(\d+)\s*\}/)
        min = Integer(self[1])
        max = Integer(self[2])
        raise SyntaxError, "Invalid quantifier range {#{min},#{max}}" if max < min
        [:quant, term, min, max, parse_quant_mode]
      when scan(/\{\s*(\d+)\s*,\s*\}/)
        min = Integer(self[1])
        [:quant, term, min, nil, parse_quant_mode]
      when scan(/\{\s*,\s*(\d+)\s*\}/)
        max = Integer(self[1])
        [:quant, term, 0, max, parse_quant_mode]
      else
        term
      end
    end

    def parse_term
      case
      when skip(/[?+*]/)
        raise SyntaxError, "Unexpected quantifier"
      when skip(".") then [:any]
      when skip("^") then [:bol]
      when skip("$") then [:eol]
      when skip("\\A") then [:bos]
      when skip("\\Z") then [:eosnl]
      when skip("\\z") then [:eos]
      when skip("\\B") then [:nwb]
      when skip("\\b") then [:wb]
      when skip("\\D") then [:ndig]
      when skip("\\d") then [:dig]
      when skip("\\H") then [:nhex]
      when skip("\\h") then [:hex]
      when skip("\\R") then [:nl]
      when skip("\\S") then [:nspc]
      when skip("\\s") then [:spc]
      when skip("\\W") then [:nword]
      when skip("\\w") then [:word]
      when scan(/\\([Pp])\{(\^)?([^\}]+)\}/)
        [:prop, (self[1] == "P") ^ (self[2] == "^"), self[3]]
      when scan(/\(\?<(\w+)>/)
        [:capture, self[1], parse_expr].tap do
          raise SyntaxError, "Unmatched '(?'" unless skip(")")
        end
      when scan(/\(\?'(\w+)'/)
        [:capture, self[1], parse_expr].tap do
          raise SyntaxError, "Unmatched '(?'" unless skip(")")
        end
      when skip("(?:")
        [:nocapture, parse_expr].tap do
          raise SyntaxError, "Unmatched '(?:'" unless skip(")")
        end
      when skip("(?>")
        [:atomic, parse_expr].tap do
          raise SyntaxError, "Unmatched '(?>'" unless skip(")")
        end
      when scan(/\(\?([im]*)(?:-([im]*))?:/)
        [:options, self[1], self[2], parse_expr].tap do
          raise SyntaxError, "Unmatched '(?'" unless skip(")")
        end
      when scan(/\(\?([im]*)(?:-([im]*))?\)/)
        [:options, self[1], self[2], parse_expr]
      when skip("(")
        [:capture, nil, parse_expr].tap do
          raise SyntaxError, "Unmatched '('" unless skip(")")
        end
      when skip("[")
        parse_class.tap do
          raise SyntaxError, "Unterminated character class" unless skip("]")
        end
      when skip("\\")
        raise SyntaxError, "Dangling '\'" if eos?
        [:exact, parse_escape(false)]
      when skip(")")
        raise SyntaxError, "Unmatched ')'"
      when scan(/./m)
        [:exact, self[0].ord]
      end
    end

    def parse_class
      terms = []
      invert = skip("^")

      until eos? || match?("]")
        term = parse_class_term
        term = [:and, term, parse_class_term] while skip("&&")
        terms << term
      end

      raise SyntaxError, "Unterminated character set" unless match?("]")
      raise SyntaxError, "Empty character set" if terms.empty?
      [:class, invert, terms]
    end

    def parse_class_term
      if scan(/\[:([a-z]+):\]/)
        [:posix, self[1]]
      elsif scan(/\\([Pp])\{(\^)?([^\}]+)\}/)
        [:prop, (self[1] == "P") ^ (self[2] == "^"), self[3]]
      elsif skip("[")
        parse_class.tap do
          raise SyntaxError, "Unterminated character class" unless skip("]")
        end
      else
        first = parse_class_exact

        if skip(/-(?=[^\]])/)
          [:range, first, parse_class_exact]
        else
          [:exact, first]
        end
      end
    end

    def parse_class_exact
      raise SyntaxError, "Unterminated character set" if eos?

      if skip("\\")
        raise SyntaxError, "Dangling escape in set" if eos?
        parse_escape(true)
      else
        scan(/./m).ord
      end
    end

    def parse_escape(in_class, in_control = false, in_meta = false)
      case
      when skip(/c|C-/)
        raise SyntaxError, "\\c/\\C- cannot be nested" if in_control

        value =
          if skip("\\")
            parse_escape(in_class, true, in_meta)
          else
            scan(/[\x20-\x7E]/).tap { |chr| raise SyntaxError, "\\c/\\C- requires ASCII-printable character" unless chr }.ord
          end

        0x9f & value
      when skip("M-")
        raise SyntaxError, "\\M- cannot be nested" if in_meta

        value =
          if skip("\\")
            parse_escape(in_class, in_control, true)
          else
            scan(/[\x20-\x7E]/).tap { |chr| raise SyntaxError, "\\M- requires ASCII-printable character" unless chr }.ord
          end

        value | 0x80
      when scan(/[0-7]{1,3}/)    then Integer(self[0], 8)
      when scan(/x(\h\h)/)       then Integer(self[1], 16)
      when scan(/u(\h{4})/)      then Integer(self[1], 16)
      when skip("t")             then "\t".ord
      when skip("v")             then "\v".ord
      when skip("n")             then "\n".ord
      when skip("r")             then "\r".ord
      when skip("f")             then "\f".ord
      when skip("a")             then "\a".ord
      when skip("e")             then "\e".ord
      when in_class && skip("b") then "\b".ord
      else                            scan(/./m).ord
      end
    end
  end

  # A byte order handler for little-endian encoding.
  # Sequences split at the LSB first (first stream byte for LE) to avoid
  # overlapping first elements in the trie.
  class ByteOrderLE
    def order(bytes)
      bytes
    end

    # Yield byte-level sequences for a value range in LE stream order.
    # Each sequence element is an Integer or Range. Sequences are split so
    # that first elements never overlap across yields from the same call.
    # Uses a shared buffer to avoid intermediate array allocations.
    def byte_sequences(start_val, end_val, num_bytes, buf = Array.new(num_bytes), depth = 0, &block)
      remaining = num_bytes - depth

      if remaining == 1
        buf[depth] = start_val..end_val
        yield buf
        return
      end

      max_val = (1 << (8 * remaining)) - 1
      if start_val == 0 && end_val == max_val
        remaining.times { |i| buf[depth + i] = 0..0xFF }
        yield buf
        return
      end

      b_s = start_val & 0xFF
      b_e = end_val & 0xFF
      upper_s = start_val >> 8
      upper_e = end_val >> 8

      if upper_s == upper_e
        buf[depth] = b_s..b_e
        byte_sequences(upper_s, upper_e, num_bytes, buf, depth + 1, &block)
      elsif b_s <= b_e
        if b_s > 0
          buf[depth] = 0..(b_s - 1)
          byte_sequences(upper_s + 1, upper_e, num_bytes, buf, depth + 1, &block)
        end
        buf[depth] = b_s..b_e
        byte_sequences(upper_s, upper_e, num_bytes, buf, depth + 1, &block)
        if b_e < 0xFF
          buf[depth] = (b_e + 1)..0xFF
          byte_sequences(upper_s, upper_e - 1, num_bytes, buf, depth + 1, &block)
        end
      else
        buf[depth] = 0..b_e
        byte_sequences(upper_s + 1, upper_e, num_bytes, buf, depth + 1, &block)
        if b_e + 1 <= b_s - 1 && upper_e >= upper_s + 2
          buf[depth] = (b_e + 1)..(b_s - 1)
          byte_sequences(upper_s + 1, upper_e - 1, num_bytes, buf, depth + 1, &block)
        end
        buf[depth] = b_s..0xFF
        byte_sequences(upper_s, upper_e - 1, num_bytes, buf, depth + 1, &block)
      end
    end
  end

  # A byte order handler for big-endian encoding.
  # Sequences split at the MSB first (first stream byte for BE).
  class ByteOrderBE
    def order(bytes)
      bytes.reverse
    end

    # Yield byte-level sequences for a value range in BE stream order.
    # Uses a shared buffer to avoid intermediate array allocations.
    def byte_sequences(start_val, end_val, num_bytes, buf = Array.new(num_bytes), depth = 0, &block)
      remaining = num_bytes - depth

      if remaining == 1
        buf[depth] = start_val..end_val
        yield buf
        return
      end

      max_val = (1 << (8 * remaining)) - 1
      if start_val == 0 && end_val == max_val
        remaining.times { |i| buf[depth + i] = 0..0xFF }
        yield buf
        return
      end

      shift = 8 * (remaining - 1)
      mask = (1 << shift) - 1

      first_s = start_val >> shift
      first_e = end_val >> shift
      rem_s = start_val & mask
      rem_e = end_val & mask

      if first_s == first_e
        buf[depth] = first_s
        byte_sequences(rem_s, rem_e, num_bytes, buf, depth + 1, &block)
      else
        buf[depth] = first_s
        byte_sequences(rem_s, mask, num_bytes, buf, depth + 1, &block)
        if first_e > first_s + 1
          buf[depth] = (first_s + 1)..(first_e - 1)
          byte_sequences(0, mask, num_bytes, buf, depth + 1, &block)
        end
        buf[depth] = first_e
        byte_sequences(0, rem_e, num_bytes, buf, depth + 1, &block)
      end
    end
  end

  # A word boundary checker for each supported encoding. Necessary for
  # implementing the \b and \B assertions.
  module WordBoundary
    class UTF_8
      def initialize(word_set)
        @word_set = word_set
      end

      def boundary?(string, byte_idx)
        prevc = previous_codepoint(string, byte_idx)
        nextc = next_codepoint(string, byte_idx)
        (prevc && @word_set.has?(prevc)) ^ (nextc && @word_set.has?(nextc))
      end

      private

      def previous_codepoint(string, byte_idx)
        if byte_idx > 0
          idx = byte_idx - 1
          byte = string.getbyte(idx)
          return byte if byte < 0x80

          idx -= 1 while idx > 0 && idx > byte_idx - 4 && (string.getbyte(idx) & 0xC0) == 0x80
          next_codepoint(string, idx) if idx >= 0
        end
      end

      def next_codepoint(string, byte_idx)
        if byte_idx < string.bytesize
          byte = string.getbyte(byte_idx)

          if (byte & 0x80) == 0x00  # 1-byte (0xxxxxxx)
            byte
          elsif (byte & 0xE0) == 0xC0  # 2-byte (110xxxxx)
            ((byte & 0x1F) << 6) | (string.getbyte(byte_idx + 1) & 0x3F) if byte_idx + 1 < string.bytesize
          elsif (byte & 0xF0) == 0xE0  # 3-byte (1110xxxx)
            ((byte & 0x0F) << 12) | ((string.getbyte(byte_idx + 1) & 0x3F) << 6) | (string.getbyte(byte_idx + 2) & 0x3F) if byte_idx + 2 < string.bytesize
          elsif (byte & 0xF8) == 0xF0  # 4-byte (11110xxx)
            ((byte & 0x07) << 18) | ((string.getbyte(byte_idx + 1) & 0x3F) << 12) | ((string.getbyte(byte_idx + 2) & 0x3F) << 6) | (string.getbyte(byte_idx + 3) & 0x3F) if byte_idx + 3 < string.bytesize
          end
        end
      end
    end

    class UTF_16
      def initialize(byte_order, word_set)
        @byte_order = byte_order
        @word_set = word_set
      end

      def boundary?(string, byte_idx)
        prevc = previous_codepoint(string, byte_idx)
        nextc = next_codepoint(string, byte_idx)
        (prevc && @word_set.has?(prevc)) ^ (nextc && @word_set.has?(nextc))
      end

      private

      def previous_codepoint(string, byte_idx)
        if byte_idx >= 2
          low = code_unit_at(string, byte_idx - 2)

          if (low & 0xFC00) == 0xDC00
            if byte_idx >= 4
              high = code_unit_at(string, byte_idx - 4)
              codepoint_from(high, low) if (high & 0xFC00) == 0xD800
            end
          else
            low if (low & 0xFC00) != 0xD800
          end
        end
      end

      def next_codepoint(string, byte_idx)
        if byte_idx + 2 <= string.bytesize
          high = code_unit_at(string, byte_idx)

          if (high & 0xFC00) == 0xD800
            if byte_idx + 3 < string.bytesize
              low = code_unit_at(string, byte_idx + 2)
              codepoint_from(high, low) if (low & 0xFC00) == 0xDC00
            end
          else
            high if (high & 0xFC00) != 0xDC00
          end
        end
      end

      def code_unit_at(string, byte_idx)
        @byte_order.order(string.byteslice(byte_idx, 2).bytes).pack("C2").unpack1("S<")
      end

      def codepoint_from(high, low)
        0x10000 + ((high & 0x3FF) << 10) + (low & 0x3FF)
      end
    end

    class UTF_32
      def initialize(byte_order, word_set)
        @byte_order = byte_order
        @word_set = word_set
      end

      def boundary?(string, byte_idx)
        prevc = (codepoint_at(string, byte_idx - 4) if byte_idx >= 4)
        nextc = (codepoint_at(string, byte_idx) if byte_idx + 4 <= string.bytesize)
        (prevc && @word_set.has?(prevc)) ^ (nextc && @word_set.has?(nextc))
      end

      private

      def codepoint_at(string, byte_idx)
        @byte_order.order(string.byteslice(byte_idx, 4).bytes).pack("C4").unpack1("L<")
      end
    end
  end

  # The compiler that translates a source pattern into bytecode instructions.
  class Compiler
    # A collection of ByteSet instances to allow reuse of identical sets. This
    # can cut down fairly significantly on the number of ByteSet instances that
    # need to be stored in compiled patterns.
    class ByteSetSet
      def initialize
        @sets = {}
      end

      def add(range)
        @sets[range] ||= ByteSet[range]
      end
    end

    # Create a Compiler instance for the given encoding.
    def self.for(encoding)
      case Encoding.find(encoding)
      when Encoding::UTF_8    then UTF_8.new
      when Encoding::UTF_16LE then UTF_16.new(ByteOrderLE.new)
      when Encoding::UTF_16BE then UTF_16.new(ByteOrderBE.new)
      when Encoding::UTF_32LE then UTF_32.new(ByteOrderLE.new)
      when Encoding::UTF_32BE then UTF_32.new(ByteOrderBE.new)
      else
        raise ArgumentError, "Unsupported encoding: #{encoding.inspect}"
      end
    end

    attr_reader :insns, :start_pc, :ncaptures, :named_captures,
                :alternation_prefixes, :required_literal

    def initialize
      @bytesets = ByteSetSet.new
      @insns = []
      @start_pc = 0
      @ncaptures = 1
      @named_captures = {}
      @alternation_prefixes = nil
      @required_literal = nil
    end

    def compile(source, options)
      ast = Parser.new(source).parse
      @alternation_prefixes = extract_alternation_prefixes(ast)
      @required_literal = extract_required_literal(ast)
      frag = compile_node(ast, options)

      enter = emit_insn([:save, 0, -1])
      patch_insns([[enter, 2]], frag[0])

      match_insn = emit_insn([:match])
      leave = emit_insn([:save, 1, -1])
      patch_insns(frag[1], leave)
      patch_insns([[leave, 2]], match_insn)

      @start_pc = enter
    end

    def word_boundary
      raise InternalError, "Implemented in subclass"
    end

    def encode_codepoint(codepoint)
      raise InternalError, "Implemented in subclass"
    end

    private

    def encode_codepoints(codepoints)
      bytes = []
      codepoints.each { |codepoint| bytes.concat(encode_codepoint(codepoint)) }
      bytes.pack("C*").freeze
    end

    # Extract literal byte-string prefixes from a top-level alternation AST
    # node. For a pattern like "cat|dog|bird", returns ["cat", "dog", "bird"]
    # as frozen binary strings. These are used by Start::Literals to quickly
    # scan for candidate match positions using String#index. Returns nil if
    # the root node is not an :alt, or if any branch lacks a literal prefix.
    def extract_alternation_prefixes(node)
      return nil unless node[0] == :alt

      branches = []
      flatten_alt(node, branches)

      prefixes = branches.map do |branch|
        codepoints = extract_node_literal_prefix(branch)
        return nil if codepoints.empty?
        encode_codepoints(codepoints)
      end

      prefixes
    end

    def flatten_alt(node, branches)
      if node[0] == :alt
        flatten_alt(node[1], branches)
        flatten_alt(node[2], branches)
      else
        branches << node
      end
    end

    def extract_node_literal_prefix(node)
      case node[0]
      when :seq
        codepoints = []
        node[1].each do |child|
          break unless child[0] == :exact
          codepoints << child[1]
        end
        codepoints
      when :exact
        [node[1]]
      when :capture
        extract_node_literal_prefix(node[2])
      when :nocapture
        extract_node_literal_prefix(node[1])
      else
        []
      end
    end

    # Walk the AST to find the longest contiguous run of :exact nodes on a
    # path that every match must traverse (sequences, required quantifiers,
    # captures). The result is used as a fast rejection filter in match/match?
    # — if the haystack doesn't contain this literal, the pattern cannot
    # match. Returns a frozen binary string of at least 2 bytes, or nil.
    def extract_required_literal(node)
      codepoints = extract_required_literal_codepoints(node)
      return nil if codepoints.nil? || codepoints.length < 2
      encode_codepoints(codepoints)
    end

    def extract_required_literal_codepoints(node)
      case node[0]
      when :seq
        best = nil
        current_run = []
        node[1].each do |child|
          if child[0] == :exact
            current_run << child[1]
          else
            if current_run.length > (best&.length || 0)
              best = current_run.dup
            end
            current_run.clear
            # Check required children recursively
            candidate = extract_required_literal_from_child(child)
            if candidate && candidate.length > (best&.length || 0)
              best = candidate
            end
          end
        end
        if current_run.length > (best&.length || 0)
          best = current_run.dup
        end
        best
      when :exact
        [node[1]]
      when :capture
        extract_required_literal_codepoints(node[2])
      when :nocapture
        extract_required_literal_codepoints(node[1])
      when :quant
        _, child, min, = node
        min >= 1 ? extract_required_literal_codepoints(child) : nil
      else
        nil
      end
    end

    def extract_required_literal_from_child(node)
      case node[0]
      when :capture
        extract_required_literal_codepoints(node[2])
      when :nocapture
        extract_required_literal_codepoints(node[1])
      when :quant
        _, child, min, = node
        min >= 1 ? extract_required_literal_codepoints(child) : nil
      else
        nil
      end
    end

    def emit_insn(insn)
      @insns << insn
      @insns.length - 1
    end

    def patch_insns(unpatched, target_pc)
      unpatched.each do |idx, field|
        raise InternalError, "Already patched" if (insn = @insns[idx])[field] != -1
        insn[field] = target_pc
      end
    end

    def compile_alt(frag1, frag2)
      idx = emit_insn([:split, frag1[0], frag2[0], :greedy])
      [idx, frag1[1] + frag2[1]]
    end

    def compile_alts(alts)
      alts.inject do |result, frag|
        idx = emit_insn([:split, result[0], frag[0], :greedy])
        [idx, result[1] + frag[1]]
      end
    end

    def compile_consume_exact(byte)
      idx = emit_insn([:consume_exact, byte, -1])
      [idx, [[idx, 2]]]
    end

    def compile_consume_set(set)
      idx = emit_insn([:consume_set, set, -1])
      [idx, [[idx, 2]]]
    end

    def compile_empty
      idx = emit_insn([:jmp, -1])
      [idx, [[idx, 1]]]
    end

    def compile_seq(parts)
      frag = nil

      parts.each do |part|
        atom =
          case part
          when Range
            compile_consume_set(@bytesets.add(part))
          when ByteSet
            compile_consume_set(part)
          when Integer
            compile_consume_exact(part)
          else
            raise InternalError, "Unknown atom part: #{part.inspect}"
          end

        if frag
          patch_insns(frag[1], atom[0])
          frag = [frag[0], atom[1]]
        else
          frag = atom
        end
      end

      frag
    end

    # Insert a byte sequence into the trie. Each trie node is a Hash mapping
    # byte values (Integer) to child nodes. Leaf entries map to :leaf.
    def trie_insert(node, seq, depth)
      entry = seq[depth]

      if depth == seq.length - 1
        # Last element in sequence - these are always ranges (or
        # convertible to ranges) representing the final byte set.
        r = entry.is_a?(Integer) ? entry..entry : entry
        r.each { |byte| node[byte] = :leaf }
      elsif entry.is_a?(Integer)
        child = (node[entry] ||= {})
        trie_insert(child, seq, depth + 1) if child != :leaf
      else
        # When inserting a range, children shared with bytes outside our
        # range must be cloned so modifications don't leak.
        originals = {}
        entry.each do |byte|
          c = node[byte]
          originals[c.object_id] = c if c && c != :leaf && !originals.key?(c.object_id)
        end

        unless originals.empty?
          # Build reverse map once: child_id -> bytes referencing it
          child_bytes = {}
          node.each { |b, c| (child_bytes[c.object_id] ||= []) << b unless c == :leaf }

          originals.each do |oid, child|
            if child_bytes[oid]&.any? { |b| !entry.cover?(b) }
              cloned = trie_dup(child)
              entry.each { |byte| node[byte] = cloned if node[byte].equal?(child) }
            end
          end
        end

        # For bytes without an entry, share one child hash so that
        # compile_trie can group them into a single consume_set.
        shared = nil
        recursed = {}
        entry.each do |byte|
          existing = node[byte]
          if existing == :leaf
            next
          elsif existing
            unless recursed[existing.object_id]
              recursed[existing.object_id] = true
              trie_insert(existing, seq, depth + 1)
            end
          else
            shared ||= {}
            node[byte] = shared
          end
        end
        trie_insert(shared, seq, depth + 1) if shared
      end
    end

    # Deep-copy a trie node so that modifications to the copy don't affect
    # the original.
    def trie_dup(node)
      result = {}
      node.each { |k, v| result[k] = (v == :leaf ? :leaf : trie_dup(v)) }
      result
    end

    # Build a trie from all sequences at once, avoiding the sharing/cloning
    # problem of incremental trie_insert. At each depth, bytes with identical
    # continuing sequence sets share a single child node.
    def build_trie_batch(sequences, depth = 0)
      node = {}

      # Separate leaf-level sequences from continuing ones
      leaf_seqs = []
      cont_seqs = []

      sequences.each do |seq|
        if depth == seq.length - 1
          leaf_seqs << seq
        else
          cont_seqs << seq
        end
      end

      # Mark leaf bytes
      leaf_seqs.each do |seq|
        entry = seq[depth]
        r = entry.is_a?(Integer) ? entry..entry : entry
        r.each { |byte| node[byte] = :leaf }
      end

      return node if cont_seqs.empty?

      # Fast path: single continuing sequence - build chain iteratively
      if cont_seqs.length == 1
        seq = cont_seqs[0]
        child = build_trie_single(seq, depth)
        child.each { |byte, c| node[byte] = c unless node[byte] == :leaf }
        return node
      end

      # Map each byte to the indices of continuing sequences that cover it
      byte_indices = {}

      cont_seqs.each_with_index do |seq, idx|
        entry = seq[depth]
        if entry.is_a?(Integer)
          (byte_indices[entry] ||= []) << idx
        else
          entry.each { |byte| (byte_indices[byte] ||= []) << idx }
        end
      end

      # Group bytes with identical index sets and share one child
      cache = {}
      byte_indices.each do |byte, indices|
        next if node[byte] == :leaf

        child = (cache[indices] ||= build_trie_batch(indices.map { |i| cont_seqs[i] }, depth + 1))
        node[byte] = child
      end

      node
    end

    # Build a trie chain from a single sequence iteratively (no recursion).
    def build_trie_single(seq, start_depth)
      # Build from leaf backwards to start_depth
      child = nil
      (seq.length - 1).downto(start_depth) do |d|
        new_node = {}
        entry = seq[d]
        if d == seq.length - 1
          r = entry.is_a?(Integer) ? entry..entry : entry
          r.each { |byte| new_node[byte] = :leaf }
        elsif entry.is_a?(Integer)
          new_node[entry] = child
        else
          entry.each { |byte| new_node[byte] = child }
        end
        child = new_node
      end
      child
    end

    # Compile a trie node into NFA instructions. Groups consecutive byte
    # keys that share the same child node, emitting consume_set for ranges
    # and consume_exact for single bytes.
    def compile_trie(node)
      # Group consecutive bytes that point to the same child (by object_id
      # for Hash children, or :leaf for leaves).
      groups = []
      sorted_bytes = node.keys.sort

      sorted_bytes.each do |byte|
        child = node[byte]
        child_id = child.object_id

        if groups.last && groups.last[2] == child_id && groups.last[1] == byte - 1
          groups.last[1] = byte
        else
          groups << [byte, byte, child_id, child]
        end
      end

      alts = groups.map do |first, last, _, child|
        if child == :leaf
          # Terminal: emit a consume instruction
          if first == last
            compile_consume_exact(first)
          else
            compile_consume_set(@bytesets.add(first..last))
          end
        else
          # Non-terminal: emit consume then recurse
          head =
            if first == last
              compile_consume_exact(first)
            else
              compile_consume_set(@bytesets.add(first..last))
            end

          tail = compile_trie(child)
          patch_insns(head[1], tail[0])
          [head[0], tail[1]]
        end
      end

      compile_alts(alts)
    end

    def compile_atomic(frag)
      enter = emit_insn([:atomic_enter, -1])
      leave = emit_insn([:atomic_leave, -1])

      patch_insns([[enter, 1]], frag[0])
      patch_insns(frag[1], leave)

      # Inside an atomic group we want to prevent backtracking into alternate
      # branches once the group has finished. Converting internal splits to
      # possessive form enforces the first-branch-only semantics appropriate
      # for atomic groups.
      visited = Set.new([leave])
      stack = [frag[0]]
      while (pc = stack.pop)
        next if visited.include?(pc)
        visited.add(pc)

        insn = @insns[pc]
        case insn[0]
        when :split
          insn[3] = :possessive
          stack << insn[1]
          stack << insn[2]
        when :jmp, :atomic_enter, :atomic_leave
          stack << insn[1]
        when :consume_exact, :consume_set
          stack << insn[2]
        end
      end

      [enter, [[leave, 1]]]
    end

    def compile_capture(frag, idx, name = nil)
      start_slot = idx * 2
      end_slot = start_slot + 1

      enter = emit_insn([:save, start_slot, -1])
      patch_insns([[enter, 2]], frag[0])

      leave = emit_insn([:save, end_slot, -1])
      patch_insns(frag[1], leave)

      @ncaptures = [@ncaptures, idx + 1].max
      @named_captures[name] = idx if name

      [enter, [[leave, 2]]]
    end

    def compile_set(set, options)
      set = set.common_case_fold if options.anybits?(Option::IGNORECASE)
      compile_set_encoded(set)
    end

    def compile_set_encoded(set)
      raise InternalError, "Implemented in subclass"
    end

    def compile_node_seq(frags, options)
      frag = nil

      frags.each do |node|
        part = compile_node(node, options)

        if frag
          patch_insns(frag[1], part[0])
          frag = [frag[0], part[1]]
        else
          frag = part
        end
      end

      frag || compile_empty
    end

    def compile_opts(opts)
      (opts || "")
        .each_char
        .map do |opt|
          case opt
          when "i"
            Option::IGNORECASE
          when "m"
            Option::MULTILINE
          else
            raise InternalError, "Unknown option: #{opt}"
          end
        end
        .inject(0, :|)
    end

    def compile_node(node, options)
      case node[0]
      when :seq
        compile_node_seq(node[1], options)
      when :bol, :eol, :bos, :eos, :eosnl, :wb, :nwb
        idx = emit_insn([node[0], -1])
        [idx, [[idx, 1]]]
      when :exact
        compile_set(USet[node[1]], options)
      when :quant
        _, child, min, max, mode = node

        required = Array.new(min) { child }
        frag = compile_node_seq(required, options)
        start_pc, outs = frag

        if max
          (max - min).times do
            opt = compile_node(child, options)
            split = emit_insn([:split, opt[0], -1, mode])
            patch_insns(outs, split)

            outs = opt[1] + [[split, 2]]
          end

          frag = [start_pc, outs]
        else
          loop_body = compile_node(child, options)
          split = emit_insn([:split, loop_body[0], -1, mode])
          patch_insns(outs, split)
          patch_insns(loop_body[1], split)

          start_pc = split if min.zero?
          frag = [start_pc, [[split, 2]]]
        end

        frag = compile_atomic(frag) if mode == :possessive
        frag
      when :class
        compile_set(compile_class_set(node, options), options)
      when :options
        compile_node(node[3], (options | compile_opts(node[1])) & ~compile_opts(node[2]))
      when :alt
        left = node[1] ? compile_node(node[1], options) : compile_empty
        right = node[2] ? compile_node(node[2], options) : compile_empty
        compile_alt(left, right)
      when :any
        any = USet.new { |set| set.add(0x000A) unless options.anybits?(Option::MULTILINE) }.invert
        compile_set(any, options)
      when :spc
        compile_set(space_set, options)
      when :nspc
        compile_set(space_set.invert, options)
      when :hex
        compile_set(hex_set, options)
      when :nhex
        compile_set(hex_set.invert, options)
      when :word
        compile_set(word_set, options)
      when :nword
        compile_set(word_set.invert, options)
      when :dig
        compile_set(digit_set, options)
      when :ndig
        compile_set(digit_set.invert, options)
      when :nl
        compile_alt(compile_seq([0x0D, 0x0A]), compile_set(USet[0x0A..0x0D, 0x85, 0x2028, 0x2029], options))
      when :capture
        idx = @ncaptures
        @ncaptures += 1
        compile_capture(compile_node(node[2], options), idx, node[1])
      when :nocapture
        compile_node(node[1], options)
      when :atomic
        compile_atomic(compile_node(node[1], options))
      when :prop
        set = unicode_property_set(node[2])
        set = set.invert if node[1]
        compile_set(set, options)
      else
        raise InternalError, "Unknown node type: #{node[0].inspect}"
      end
    end

    def compile_class_set(node, options)
      case node[0]
      when :class
        set = USet.new
        node[2].each { |term| set |= compile_class_set(term, options) }
        node[1] ? set.invert : set
      when :posix
        posix_class_set(node[1])
      when :range
        USet[node[1]..node[2]]
      when :exact
        USet[node[1]]
      when :and
        compile_class_set(node[1], options) & compile_class_set(node[2], options)
      when :prop
        set = unicode_property_set(node[2])
        node[1] ? set.invert : set
      else
        raise InternalError, "Unknown class term: #{node[0].inspect}"
      end
    end

    #--------------------------------------------------------------------------#
    # Unicode character sets                                                   #
    #--------------------------------------------------------------------------#

    def digit_set = UCD["decimalnumber"]
    def hex_set   = USet[0x0030..0x0039, 0x0041..0x0046, 0x0061..0x0066]
    def space_set = UCD["spaceseparator"] | UCD["lineseparator"] | UCD["paragraphseparator"] | USet[0x09, 0x0A..0x0D, 0x85]
    def word_set  = UCD["letter"] | UCD["mark"] | UCD["decimalnumber"] | UCD["connectorpunctuation"]

    def posix_class_set(name)
      case name
      when "alnum"  then UCD["letter"] | UCD["mark"] | UCD["decimalnumber"] | UCD["letternumber"]
      when "alpha"  then UCD["letter"] | UCD["mark"] | UCD["letternumber"]
      when "ascii"  then USet[0x0000..0x007F]
      when "blank"  then UCD["spaceseparator"] | USet[0x0009]
      when "cntrl"  then UCD["control"] | UCD["format"] | UCD["unassigned"] | UCD["privateuse"] | UCD["surrogate"]
      when "digit"  then UCD["decimalnumber"]
      when "graph"  then posix_class_set("space").invert & UCD["control"].invert & UCD["unassigned"].invert & UCD["surrogate"].invert
      when "lower"  then UCD["lowercaseletter"]
      when "print"  then posix_class_set("graph") | UCD["spaceseparator"]
      when "punct"  then UCD["punctuation"] | USet[0x24, 0x2B, 0x3C, 0x3D, 0x3E, 0x5E, 0x60, 0x7C, 0x7E]
      when "space"  then UCD["spaceseparator"] | UCD["lineseparator"] | UCD["paragraphseparator"] | USet[0x09, 0x0A..0x0D, 0x85]
      when "upper"  then UCD["uppercaseletter"]
      when "word"   then UCD["letter"] | UCD["mark"] | UCD["decimalnumber"] | UCD["connectorpunctuation"] | UCD["letternumber"]
      when "xdigit" then USet[0x0030..0x0039, 0x0041..0x0046, 0x0061..0x0066]
      else
        raise SyntaxError, "Unsupported POSIX class [:#{name}:]"
      end
    end

    def unicode_property_set(name)
      case (normal = name.downcase.delete(" _-"))
      when "alnum", "alpha", "ascii", "blank", "cntrl", "digit", "graph", "lower", "print", "punct", "space", "upper", "word", "xdigit"
        posix_class_set(normal)
      when "xposixpunct"
        posix_class_set("punct")
      when "any"
        USet.new.invert
      when "assigned"
        UCD["unassigned"].invert
      else
        if (set = UCD[normal])
          set
        else
          raise SyntaxError, "Unsupported Unicode property \\p{#{name}}"
        end
      end
    end
  end

  # A UTF-8 specific compiler that handles compilation of character sets
  # into sequences of byte consumption instructions per the UTF-8 encoding.
  class Compiler::UTF_8 < Compiler
    def word_boundary
      WordBoundary::UTF_8.new(word_set)
    end

    def encode_codepoint(codepoint)
      if codepoint <= 0x7F
        [codepoint]
      elsif codepoint <= 0x7FF
        [0xC0 | (codepoint >> 6), 0x80 | (codepoint & 0x3F)]
      elsif codepoint <= 0xFFFF
        [0xE0 | (codepoint >> 12), 0x80 | ((codepoint >> 6) & 0x3F), 0x80 | (codepoint & 0x3F)]
      else
        [0xF0 | (codepoint >> 18), 0x80 | ((codepoint >> 12) & 0x3F), 0x80 | ((codepoint >> 6) & 0x3F), 0x80 | (codepoint & 0x3F)]
      end
    end

    private

    def compile_set_encoded(unicode_set)
      # Build a byte-level trie from all codepoint ranges, then compile it
      # into NFA instructions. This shares common UTF-8 prefixes instead of
      # generating duplicate instruction chains for each codepoint range.
      trie = {}

      unicode_set.each_range do |range|
        start_codepoint = range.begin
        end_codepoint = range.end - 1
        next if start_codepoint > end_codepoint

        # Decompose each codepoint range into byte-level sequences and
        # insert them into the trie.
        utf8_sequences(start_codepoint, end_codepoint) { |seq| trie_insert(trie, seq, 0) }
      end

      raise InternalError, "Empty character set" if trie.empty?
      compile_trie(trie)
    end

    # Yield byte-level sequences for a codepoint range. Each sequence is an
    # array where each element is either an Integer (exact byte) or a Range
    # (byte range). For example, U+0080..U+00BF yields [[0xC2, 0x80..0xBF]].
    def utf8_sequences(start_codepoint, end_codepoint)
      if start_codepoint <= 0x7F
        yield [start_codepoint..[end_codepoint, 0x7F].min]
      end

      if end_codepoint >= 0x80 && start_codepoint <= 0x7FF
        range_2_sequences([start_codepoint, 0x80].max, [end_codepoint, 0x7FF].min) { |s| yield s }
      end

      if end_codepoint >= 0x800 && start_codepoint <= 0xFFFF
        range_3_sequences([start_codepoint, 0x800].max, [end_codepoint, 0xFFFF].min) { |s| yield s }
      end

      if end_codepoint >= 0x10000
        range_4_sequences([start_codepoint, 0x10000].max, [end_codepoint, 0x10FFFF].min) { |s| yield s }
      end
    end

    def range_2_sequences(start_codepoint, end_codepoint)
      lead_start = 0xC0 | (start_codepoint >> 6)
      lead_end = 0xC0 | (end_codepoint >> 6)

      if lead_start == lead_end
        yield [lead_start, (0x80 | (start_codepoint & 0x3F))..(0x80 | (end_codepoint & 0x3F))]
      else
        yield [lead_start, (0x80 | (start_codepoint & 0x3F))..0xBF]
        if lead_end > lead_start + 1
          yield [(lead_start + 1)..lead_end - 1, 0x80..0xBF]
        end
        yield [lead_end, 0x80..(0x80 | (end_codepoint & 0x3F))]
      end
    end

    def range_3_sequences(start_codepoint, end_codepoint)
      lead_start = 0xE0 | (start_codepoint >> 12)
      lead_end = 0xE0 | (end_codepoint >> 12)

      if lead_start == lead_end
        single_lead_3_sequences(lead_start, start_codepoint, end_codepoint) { |s| yield s }
      else
        codepoint_max = [end_codepoint, ((lead_start & 0x0F) << 12) + 0xFFF].min
        single_lead_3_sequences(lead_start, start_codepoint, codepoint_max) { |s| yield s }
        if lead_end > lead_start + 1
          yield [(lead_start + 1)..lead_end - 1, 0x80..0xBF, 0x80..0xBF]
        end
        codepoint_min = [start_codepoint, ((lead_end & 0x0F) << 12)].max
        single_lead_3_sequences(lead_end, codepoint_min, end_codepoint) { |s| yield s }
      end
    end

    def single_lead_3_sequences(lead, start_codepoint, end_codepoint)
      s2s = 0x80 | ((start_codepoint >> 6) & 0x3F)
      s2e = 0x80 | ((end_codepoint >> 6) & 0x3F)

      if s2s == s2e
        yield [lead, s2s, (0x80 | (start_codepoint & 0x3F))..(0x80 | (end_codepoint & 0x3F))]
      else
        yield [lead, s2s, (0x80 | (start_codepoint & 0x3F))..0xBF]
        yield [lead, (s2s + 1)..s2e - 1, 0x80..0xBF] if s2e > s2s + 1
        yield [lead, s2e, 0x80..(0x80 | (end_codepoint & 0x3F))]
      end
    end

    def range_4_sequences(start_codepoint, end_codepoint)
      lead_start = 0xF0 | (start_codepoint >> 18)
      lead_end = 0xF0 | (end_codepoint >> 18)

      if lead_start == lead_end
        single_lead_4_sequences(lead_start, start_codepoint, end_codepoint) { |s| yield s }
      else
        codepoint_max = [end_codepoint, ((lead_start & 0x07) << 18) + 0x3FFFF].min
        single_lead_4_sequences(lead_start, start_codepoint, codepoint_max) { |s| yield s }
        if lead_end > lead_start + 1
          yield [(lead_start + 1)..lead_end - 1, 0x80..0xBF, 0x80..0xBF, 0x80..0xBF]
        end
        codepoint_min = [start_codepoint, ((lead_end & 0x07) << 18)].max
        single_lead_4_sequences(lead_end, codepoint_min, end_codepoint) { |s| yield s }
      end
    end

    def single_lead_4_sequences(lead, start_codepoint, end_codepoint)
      s2s = 0x80 | ((start_codepoint >> 12) & 0x3F)
      s2e = 0x80 | ((end_codepoint >> 12) & 0x3F)

      if s2s == s2e
        single_second_4_sequences(lead, s2s, start_codepoint, end_codepoint) { |s| yield s }
      else
        codepoint_max = [end_codepoint, ((start_codepoint >> 12) << 12) + 0xFFF].min
        single_second_4_sequences(lead, s2s, start_codepoint, codepoint_max) { |s| yield s }
        if s2e > s2s + 1
          yield [lead, (s2s + 1)..s2e - 1, 0x80..0xBF, 0x80..0xBF]
        end
        codepoint_min = [start_codepoint, ((end_codepoint >> 12) << 12)].max
        single_second_4_sequences(lead, s2e, codepoint_min, end_codepoint) { |s| yield s }
      end
    end

    def single_second_4_sequences(lead, second, start_codepoint, end_codepoint)
      s3s = 0x80 | ((start_codepoint >> 6) & 0x3F)
      s3e = 0x80 | ((end_codepoint >> 6) & 0x3F)

      if s3s == s3e
        yield [lead, second, s3s, (0x80 | (start_codepoint & 0x3F))..(0x80 | (end_codepoint & 0x3F))]
      else
        yield [lead, second, s3s, (0x80 | (start_codepoint & 0x3F))..0xBF]
        yield [lead, second, (s3s + 1)..s3e - 1, 0x80..0xBF] if s3e > s3s + 1
        yield [lead, second, s3e, 0x80..(0x80 | (end_codepoint & 0x3F))]
      end
    end

  end

  # Base class for UTF-16 encodings (little-endian and big-endian)
  # UTF-16 uses 2 bytes for codepoints U+0000-U+FFFF (except surrogates)
  # and 4 bytes (surrogate pairs) for codepoints U+10000-U+10FFFF
  class Compiler::UTF_16 < Compiler
    def initialize(byte_order)
      super()
      @byte_order = byte_order
    end

    def word_boundary
      WordBoundary::UTF_16.new(@byte_order, word_set)
    end

    def encode_codepoint(codepoint)
      if codepoint <= 0xFFFF
        @byte_order.order([codepoint & 0xFF, (codepoint >> 8) & 0xFF])
      else
        offset = codepoint - 0x10000
        high = 0xD800 + (offset >> 10)
        low = 0xDC00 + (offset & 0x3FF)
        @byte_order.order([high & 0xFF, (high >> 8) & 0xFF]) +
          @byte_order.order([low & 0xFF, (low >> 8) & 0xFF])
      end
    end

    private

    def compile_set_encoded(unicode_set)
      sequences = []

      unicode_set.each_range do |range|
        start_codepoint = range.begin
        end_codepoint = range.end - 1
        next if start_codepoint > end_codepoint

        # Split range into BMP (skip surrogates) and supplementary sub-ranges
        # BMP before surrogates: U+0000-U+D7FF
        bmp1_start = [start_codepoint, 0x0000].max
        bmp1_end = [end_codepoint, 0xD7FF].min
        if bmp1_start <= bmp1_end
          @byte_order.byte_sequences(bmp1_start, bmp1_end, 2) { |seq| sequences << seq.dup }
        end

        # BMP after surrogates: U+E000-U+FFFF
        bmp2_start = [start_codepoint, 0xE000].max
        bmp2_end = [end_codepoint, 0xFFFF].min
        if bmp2_start <= bmp2_end
          @byte_order.byte_sequences(bmp2_start, bmp2_end, 2) { |seq| sequences << seq.dup }
        end

        # Supplementary: U+10000-U+10FFFF
        supp_start = [start_codepoint, 0x10000].max
        supp_end = [end_codepoint, 0x10FFFF].min
        if supp_start <= supp_end
          surrogate_sequences(supp_start, supp_end) { |seq| sequences << seq.dup }
        end
      end

      raise InternalError, "Empty character set" if sequences.empty?
      trie = build_trie_batch(sequences)
      compile_trie(trie)
    end

    # Yield 4-element stream-ordered byte sequences for supplementary codepoints
    # encoded as surrogate pairs. Splits at high surrogate boundaries, then
    # decomposes each surrogate into 2 bytes via byte_sequences.
    def surrogate_sequences(start_codepoint, end_codepoint)
      start_offset = start_codepoint - 0x10000
      end_offset = end_codepoint - 0x10000

      high_start = 0xD800 + (start_offset >> 10)
      high_end = 0xD800 + (end_offset >> 10)
      low_start = 0xDC00 + (start_offset & 0x3FF)
      low_end = 0xDC00 + (end_offset & 0x3FF)

      if high_start == high_end
        surrogate_pair_sequences(high_start, high_start, low_start, low_end) { |seq| yield seq }
      else
        surrogate_pair_sequences(high_start, high_start, low_start, 0xDFFF) { |seq| yield seq }
        if high_end > high_start + 1
          surrogate_pair_sequences(high_start + 1, high_end - 1, 0xDC00, 0xDFFF) { |seq| yield seq }
        end
        surrogate_pair_sequences(high_end, high_end, 0xDC00, low_end) { |seq| yield seq }
      end
    end

    # Yield 4-element stream-ordered byte sequences for a surrogate pair range.
    def surrogate_pair_sequences(high_start, high_end, low_start, low_end)
      buf = Array.new(4)
      @byte_order.byte_sequences(high_start, high_end, 2) do |high_seq|
        buf[0] = high_seq[0]
        buf[1] = high_seq[1]
        @byte_order.byte_sequences(low_start, low_end, 2) do |low_seq|
          buf[2] = low_seq[0]
          buf[3] = low_seq[1]
          yield buf
        end
      end
    end
  end

  # Base class for UTF-32 encodings (little-endian and big-endian)
  class Compiler::UTF_32 < Compiler
    def initialize(byte_order)
      super()
      @byte_order = byte_order
    end

    def word_boundary
      WordBoundary::UTF_32.new(@byte_order, word_set)
    end

    def encode_codepoint(codepoint)
      @byte_order.order([codepoint & 0xFF, (codepoint >> 8) & 0xFF, (codepoint >> 16) & 0xFF, (codepoint >> 24) & 0xFF])
    end

    private

    def compile_set_encoded(unicode_set)
      sequences = []

      unicode_set.each_range do |range|
        start_codepoint = range.begin
        end_codepoint = range.end - 1
        next if start_codepoint > end_codepoint

        @byte_order.byte_sequences(start_codepoint, end_codepoint, 4) { |seq| sequences << seq.dup }
      end

      raise InternalError, "Empty character set" if sequences.empty?
      trie = build_trie_batch(sequences)
      compile_trie(trie)
    end
  end

  # A module containing different strategies for finding the next positions to
  # try matching from, based on the first instruction of the pattern. Used to
  # optimize matching by skipping positions that cannot possibly match the
  # pattern.
  module Start
    # A start strategy that matches a fixed byte sequence (e.g. from a literal
    # string).
    class Prefix
      def initialize(prefix)
        @prefix = prefix
        freeze
      end

      def each_pos(string, string_len)
        binary = string.b
        pos = binary.index(@prefix, 0)
        while pos
          yield pos
          pos = binary.index(@prefix, pos + 1)
        end
      end
    end

    # A start strategy that matches any of a set of literal byte strings
    # (e.g. from alternation prefixes like cat|dog|bird).
    class Literals
      def initialize(literals)
        @literals = literals
        freeze
      end

      def each_pos(string, string_len)
        binary = string.b
        positions = @literals.map { |lit| binary.index(lit, 0) }
        last_yielded = -1

        loop do
          min_pos = nil
          min_idx = nil
          positions.each_with_index do |pos, idx|
            next unless pos
            if min_pos.nil? || pos < min_pos
              min_pos = pos
              min_idx = idx
            end
          end

          break unless min_pos

          if min_pos > last_yielded
            yield min_pos
            last_yielded = min_pos
          end

          positions[min_idx] = binary.index(@literals[min_idx], min_pos + 1)
        end
      end
    end

    # A start strategy that matches a single byte from a set of bytes (e.g. from
    # a character class).
    class ByteSet
      def initialize(byte_set)
        @byte_set = byte_set
        freeze
      end

      def each_pos(string, string_len)
        idx = 0
        string.each_byte do |byte|
          yield idx if @byte_set.has?(byte)
          idx += 1
        end
      end
    end

    # A start strategy for patterns anchored at the beginning of the string
    # (\A). Only yields position 0.
    class BeginningOfString
      def initialize
        freeze
      end

      def each_pos(string, string_len)
        yield 0
      end
    end

    # A start strategy that matches any position (e.g. from a pattern that
    # starts with a zero-width assertion or an unanchored consume).
    class Any
      def initialize
        freeze
      end

      def each_pos(string, string_len)
        (string_len + 1).times { |idx| yield idx }
      end
    end
  end

  # Matcher classes that handle NFA and DFA matching. Extracted from Pattern
  # to separate matching concerns from pattern compilation and start strategy.
  module Matcher
    class Base
      def initialize(insns, start_pc, ncaptures, named_captures, word_boundary)
        @insns = insns
        @start_pc = start_pc
        @ncaptures = ncaptures
        @named_captures = named_captures
        @word_boundary = word_boundary
      end

      private

      def next_pcs(insn, string, string_idx, string_len)
        case insn[0]
        when :split
          yield insn[1]
          yield insn[2]
        when :jmp
          yield insn[1]
        when :atomic_enter, :atomic_leave
          yield insn[1]
        when :save
          yield insn[2]
        when :bol
          yield insn[1] if (string_idx == 0) || (string_idx > 0 && string.getbyte(string_idx - 1) == "\n".ord)
        when :bos
          yield insn[1] if string_idx == 0
        when :eol
          yield insn[1] if (string_idx == string_len) || (string_idx < string_len && string.getbyte(string_idx) == "\n".ord)
        when :eos
          yield insn[1] if string_idx == string_len
        when :eosnl
          yield insn[1] if (string_idx == string_len) || (string_idx + 1 == string_len && string.getbyte(string_idx) == "\n".ord)
        when :wb
          yield insn[1] if @word_boundary.boundary?(string, string_idx)
        when :nwb
          yield insn[1] unless @word_boundary.boundary?(string, string_idx)
        else
          raise InternalError, "Unexpected instruction: #{insn[0].inspect}"
        end
      end
    end

    class NFA < Base
      def initialize(insns, start_pc, ncaptures, named_captures, word_boundary)
        super
        @visited = Array.new(insns.length)
        @consume_visited = Array.new(insns.length)
      end

      def match(start, string)
        string_len = string.bytesize
        start.each_pos(string, string_len) do |string_idx|
          result = match_at(string, string_idx, string_len)
          return result if result
        end
        nil
      end

      def match?(start, string)
        string_len = string.bytesize
        start.each_pos(string, string_len) do |string_idx|
          return true if match_at?(string, string_idx, string_len)
        end
        false
      end

      def match_at(string, start_idx, string_len)
        last_match = nil
        state, match_data = closure([[@start_pc, [start_idx, *Array.new(@ncaptures * 2 - 1)]]], start_idx, string_len, string)

        if match_data
          last_match = match_data
          return match_data if state.empty?
        end

        string_idx = start_idx
        while string_idx < string_len
          byte = string.getbyte(string_idx)
          next_entries = []

          state.each do |pc, captures|
            case (insn = @insns[pc])[0]
            when :consume_exact
              next_entries << [insn[2], captures] if insn[1] == byte
            when :consume_set
              next_entries << [insn[2], captures] if insn[1].has?(byte)
            end
          end

          break if next_entries.empty?
          state, match_data = closure(next_entries, string_idx + 1, string_len, string)

          if match_data
            last_match = match_data
            return match_data if state.empty?
          end

          string_idx += 1
        end

        last_match
      end

      def match_at?(string, start_idx, string_len)
        !match_at(string, start_idx, string_len).nil?
      end

      private

      def closure(entries, string_idx, string_len, string)
        state = []
        stack = entries.dup
        visited = @visited
        visited.fill(nil)
        last_match = nil

        while (entry = stack.pop)
          pc, captures = entry
          next if visited[pc]
          visited[pc] = true

          case (insn = @insns[pc])[0]
          when :consume_exact, :consume_set
            state << [pc, captures]
          when :match
            last_match =
              MatchData.new(
                string,
                captures.each_slice(2).map do |start_pos, end_pos|
                  (start_pos...end_pos) if start_pos && end_pos
                end,
                @named_captures
              )
          when :save
            updated = captures.dup
            updated[insn[1]] = string_idx
            stack << [insn[2], updated]
          when :split
            case insn[3]
            when :lazy
              stack << [insn[1], captures]
              stack << [insn[2], captures]
            when :possessive
              if consume?(insn[1], string, string_idx, string_len)
                stack << [insn[1], captures]
              else
                stack << [insn[2], captures]
              end
            when :greedy
              stack << [insn[2], captures]
              stack << [insn[1], captures]
            else
              raise InternalError, "Unknown split mode: #{insn[3].inspect}"
            end
          when :atomic_enter
            stack.clear
            visited.fill(nil)
            stack << [insn[1], captures]
          when :atomic_leave
            stack.clear
            visited.fill(nil)
            stack << [insn[1], captures]
          else
            next_pcs(insn, string, string_idx, string_len) { |next_pc| stack << [next_pc, captures] }
          end
        end

        [state, last_match]
      end

      def consume?(pc, string, string_idx, string_len)
        return false if string_idx >= string_len

        byte = string.getbyte(string_idx)
        visited = @consume_visited
        visited.fill(nil)
        stack = [pc]

        while (current = stack.pop)
          next if visited[current]
          visited[current] = true

          case (insn = @insns[current])[0]
          when :consume_exact
            return true if insn[1] == byte
          when :consume_set
            return true if insn[1].has?(byte)
          else
            next_pcs(insn, string, string_idx, string_len) { |next_pc| stack << next_pc }
          end
        end

        false
      end
    end

    class DFA
      def initialize(initial_state, dead_state, nfa, byte_to_class)
        @initial_state = initial_state
        @dead_state = dead_state
        @nfa = nfa
        @byte_to_class = byte_to_class
      end

      def match(start, string)
        string_len = string.bytesize
        return @nfa.match_at(string, 0, string_len) if @initial_state.is_match

        start.each_pos(string, string_len) do |string_idx|
          return @nfa.match_at(string, string_idx, string_len) if run?(string, string_idx, string_len)
        end
        nil
      end

      def match?(start, string)
        return true if @initial_state.is_match

        string_len = string.bytesize
        start.each_pos(string, string_len) do |string_idx|
          return true if run?(string, string_idx, string_len)
        end
        false
      end

      private

      def run?(string, string_idx, string_len)
        state = @initial_state
        dead = @dead_state
        btc = @byte_to_class

        while string_idx < string_len
          state = state.transitions[btc[string.getbyte(string_idx)]]
          string_idx += 1
          return true if state.is_match
          return false if state.equal?(dead)
        end

        false
      end

    end

    class LazyDFA < Base
      # Bits for detect_anchor_types: which anchor instructions exist in the
      # pattern. Used to skip unnecessary context computation.
      ANCHOR_OPCODES = %i[bol eol bos eos eosnl wb nwb].freeze

      module AnchorType
        BOL           = 1 << 0 # pattern contains ^ (beginning of line)
        EOL           = 1 << 1 # pattern contains $ (end of line)
        BOS           = 1 << 2 # pattern contains \A (beginning of string)
        EOS           = 1 << 3 # pattern contains \z (end of string)
        EOSNL         = 1 << 4 # pattern contains \Z (end of string or before final \n)
        WORD_BOUNDARY = 1 << 5 # pattern contains \b or \B
      end

      # Bits for compute_context: which positional conditions hold at a given
      # byte index. Included in the DFA cache key so transitions that depend
      # on anchors are correctly distinguished.
      module Context
        AT_START       = 1 << 0 # string_idx == 0
        PREV_NEWLINE   = 1 << 1 # previous byte was \n
        AT_END         = 1 << 2 # string_idx == string_len
        CURR_NEWLINE   = 1 << 3 # current byte is \n
        PENULTIMATE    = 1 << 4 # string_idx + 1 == string_len
        WORD_BOUNDARY  = 1 << 5 # at a word boundary
      end

      # A DFA state is a set of NFA program counters (at consume instructions)
      # after epsilon closure, plus whether the closure reached a match state.
      class State
        attr_reader :pc_set, :is_match, :transitions

        def initialize(pc_set, is_match)
          @pc_set = pc_set
          @is_match = is_match
          @hash = pc_set.hash
          @transitions = nil
          @ctx_transitions = nil
        end

        def hash = @hash
        def eql?(other) = @pc_set == other.pc_set
        def dead? = @pc_set.empty?

        def next_state(context, cls)
          if context == 0
            @transitions&.[](cls)
          else
            @ctx_transitions&.[](context)&.[](cls)
          end
        end

        def set_next_state(context, cls, state, num_classes)
          if context == 0
            (@transitions ||= Array.new(num_classes))[cls] = state
          else
            ((@ctx_transitions ||= {})[context] ||= Array.new(num_classes))[cls] = state
          end
        end

        def set_transitions(transitions)
          @transitions = transitions
        end
      end

      def initialize(insns, start_pc, ncaptures, named_captures, word_boundary, equiv_classes)
        super(insns, start_pc, ncaptures, named_captures, word_boundary)
        @anchor_types = find_anchor_types
        @byte_to_class = equiv_classes.byte_to_class
        @num_classes = equiv_classes.num_classes
        @states = {}
        @visited = Array.new(insns.length)
        @next_pcs = []
        @initial_state = @anchor_types == 0 ? closure([@start_pc], "".b, 0, 0) : nil
        @nfa = NFA.new(insns, start_pc, ncaptures, named_captures, word_boundary)
      end

      def match(start, string)
        string_len = string.bytesize
        start.each_pos(string, string_len) do |string_idx|
          if run(string, string_idx, string_len)
            return @nfa.match_at(string, string_idx, string_len)
          end
        end
        nil
      end

      def match?(start, string)
        string_len = string.bytesize
        start.each_pos(string, string_len) do |string_idx|
          return true if run(string, string_idx, string_len)
        end
        false
      end

      private

      def find_anchor_types
        types = 0
        @insns.each do |insn|
          case insn[0]
          when :bol then types |= AnchorType::BOL
          when :eol then types |= AnchorType::EOL
          when :bos then types |= AnchorType::BOS
          when :eos then types |= AnchorType::EOS
          when :eosnl then types |= AnchorType::EOSNL
          when :wb, :nwb then types |= AnchorType::WORD_BOUNDARY
          end
        end
        types
      end

      def compute_context(string, string_idx, string_len)
        return 0 if @anchor_types == 0

        ctx = 0

        if @anchor_types & (AnchorType::BOL | AnchorType::BOS) != 0
          ctx |= Context::AT_START if string_idx == 0
        end

        if @anchor_types & AnchorType::BOL != 0
          ctx |= Context::PREV_NEWLINE if string_idx > 0 && string.getbyte(string_idx - 1) == 0x0A
        end

        if @anchor_types & (AnchorType::EOL | AnchorType::EOS | AnchorType::EOSNL) != 0
          ctx |= Context::AT_END if string_idx == string_len
        end

        if @anchor_types & (AnchorType::EOL | AnchorType::EOSNL) != 0
          ctx |= Context::CURR_NEWLINE if string_idx < string_len && string.getbyte(string_idx) == 0x0A
        end

        if @anchor_types & AnchorType::EOSNL != 0
          ctx |= Context::PENULTIMATE if string_idx + 1 == string_len
        end

        if @anchor_types & AnchorType::WORD_BOUNDARY != 0
          ctx |= Context::WORD_BOUNDARY if @word_boundary.boundary?(string, string_idx)
        end

        ctx
      end

      def closure(pcs, string, string_idx, string_len)
        consume_pcs = []
        stack = pcs.dup
        visited = @visited
        visited.fill(nil)
        is_match = false

        while (pc = stack.pop)
          next if visited[pc]
          visited[pc] = true

          case (insn = @insns[pc])[0]
          when :consume_exact, :consume_set
            consume_pcs << pc
          when :match
            is_match = true
          when :save
            stack << insn[2]
          when :split
            stack << insn[1]
            stack << insn[2]
          when :jmp
            stack << insn[1]
          else
            next_pcs(insn, string, string_idx, string_len) { |next_pc| stack << next_pc }
          end
        end

        consume_pcs.sort!.freeze
        @states[[consume_pcs, is_match]] ||= State.new(consume_pcs, is_match)
      end

      def run(string, start_idx, string_len)
        state = @initial_state || closure([@start_pc], string, start_idx, string_len)

        return nil if state.dead? && !state.is_match

        last_match_end = state.is_match ? start_idx : nil

        string_idx = start_idx
        while string_idx < string_len
          byte = string.getbyte(string_idx)
          cls = @byte_to_class[byte]
          next_ctx = @anchor_types == 0 ? 0 : compute_context(string, string_idx + 1, string_len)

          next_state = state.next_state(next_ctx, cls)

          unless next_state
            @next_pcs.clear
            state.pc_set.each do |pc|
              insn = @insns[pc]
              case insn[0]
              when :consume_exact
                @next_pcs << insn[2] if insn[1] == byte
              when :consume_set
                @next_pcs << insn[2] if insn[1].has?(byte)
              end
            end

            next_state = closure(@next_pcs, string, string_idx + 1, string_len)
            state.set_next_state(next_ctx, cls, next_state, @num_classes)
          end

          state = next_state
          string_idx += 1
          last_match_end = string_idx if state.is_match
          break if state.dead?
        end

        if !state.dead? && !state.is_match
          eof_state = closure(state.pc_set, string, string_idx, string_len)
          last_match_end = string_idx if eof_state.is_match
        end

        last_match_end
      end
    end

    # Attempts to eagerly compile a DFA for the given instructions.
    # Returns a DFA if successful, otherwise a LazyDFA.
    class DFACompiler
      # Maximum number of DFA states to eagerly compile.
      BUDGET = 256

      def initialize(insns, start_pc, ncaptures, named_captures, word_boundary)
        @insns = insns
        @start_pc = start_pc
        @ncaptures = ncaptures
        @named_captures = named_captures
        @word_boundary = word_boundary
        @equiv_classes = ByteEquivalenceClasses.new(insns)
        @states = {}
        @visited = Array.new(insns.length)
        @next_pcs = []
      end

      def compile
        return lazy_dfa if @insns.any? { |insn| LazyDFA::ANCHOR_OPCODES.include?(insn[0]) }

        initial_state = closure([@start_pc])
        return lazy_dfa if initial_state.dead?

        num_classes = @equiv_classes.num_classes
        representatives = @equiv_classes.representatives

        dead = closure([])
        dead_transitions = Array.new(num_classes, dead)
        dead.set_transitions(dead_transitions)

        worklist = [initial_state]
        seen = { [initial_state.pc_set, initial_state.is_match] => true,
                 [dead.pc_set, dead.is_match] => true }

        while (state = worklist.shift)
          transitions = state.transitions || Array.new(num_classes)
          num_classes.times do |cls|
            next if transitions[cls]

            byte = representatives[cls]
            @next_pcs.clear
            state.pc_set.each do |pc|
              insn = @insns[pc]
              case insn[0]
              when :consume_exact
                @next_pcs << insn[2] if insn[1] == byte
              when :consume_set
                @next_pcs << insn[2] if insn[1].has?(byte)
              end
            end

            next_state = closure(@next_pcs)
            next_state.set_transitions(dead_transitions) if next_state.dead?
            transitions[cls] = next_state

            id = [next_state.pc_set, next_state.is_match]
            unless seen[id]
              return lazy_dfa if seen.size >= BUDGET
              seen[id] = true
              worklist << next_state
            end
          end

          state.set_transitions(transitions)
        end

        nfa = NFA.new(@insns, @start_pc, @ncaptures, @named_captures, @word_boundary)
        DFA.new(initial_state, dead, nfa, @equiv_classes.byte_to_class)
      end

      private

      def lazy_dfa
        LazyDFA.new(@insns, @start_pc, @ncaptures, @named_captures, @word_boundary, @equiv_classes)
      end

      def closure(pcs)
        consume_pcs = []
        stack = pcs.dup
        visited = @visited
        visited.fill(nil)
        is_match = false

        while (pc = stack.pop)
          next if visited[pc]
          visited[pc] = true

          case (insn = @insns[pc])[0]
          when :consume_exact, :consume_set
            consume_pcs << pc
          when :match
            is_match = true
          when :save
            stack << insn[2]
          when :split
            stack << insn[1]
            stack << insn[2]
          when :jmp
            stack << insn[1]
          end
        end

        consume_pcs.sort!.freeze
        @states[[consume_pcs, is_match]] ||= LazyDFA::State.new(consume_pcs, is_match)
      end
    end
  end

  private_constant :USet, :UCD, :ByteSet, :ByteEquivalenceClasses, :Parser,
                   :ByteOrderLE, :ByteOrderBE, :WordBoundary, :Compiler,
                   :Start, :Matcher

  # The result of a successful pattern match.
  class MatchData
    def initialize(string, ranges, named_captures = {})
      @string = string
      @ranges = ranges
      @named_captures = named_captures
    end

    def [](key)
      case key
      when Integer
        range = @ranges[key]
        @string.byteslice(range) if range
      when String
        index = @named_captures[key]
        range = @ranges[index] if index
        @string.byteslice(range) if range
      else
        raise TypeError, "Invalid key type: #{key.inspect}"
      end
    end
  end

  # Options that can be used when creating patterns.
  module Option
    # No special options.
    NONE = 0

    # Option to perform case-insensitive matching.
    IGNORECASE = Regexp::IGNORECASE

    # Option to perform multiline matching. By default in Ruby regular
    # expressions, `.` does not match newline characters. With this option,
    # `.` matches newline characters as well.
    MULTILINE = Regexp::MULTILINE
  end

  # A pattern that can be used to match against strings. A pattern instance is
  # analogous to a Regexp instance, and has loosely the same API.
  class Pattern
    # The source string used to create the pattern.
    attr_reader :source, :options

    def initialize(source, options = Option::NONE, encoding = Encoding::UTF_8)
      @source = source
      @options = options
      @encoding = encoding

      compiler = Compiler.for(encoding)
      compiler.compile(source, options)

      insns = compiler.insns.freeze
      start_pc = compiler.start_pc
      ncaptures = compiler.ncaptures
      named_captures = compiler.named_captures.freeze
      word_boundary = compiler.word_boundary

      @matcher =
        if insns.none? { |insn| insn[0] == :atomic_enter || insn[0] == :atomic_leave }
          Matcher::DFACompiler.new(insns, start_pc, ncaptures, named_captures, word_boundary).compile
        else
          Matcher::NFA.new(insns, start_pc, ncaptures, named_captures, word_boundary)
        end

      @required_literal = compiler.required_literal
      @start =
        if bos_anchored?(insns, start_pc)
          Start::BeginningOfString.new
        elsif !(prefix = extract_start_prefix(insns, start_pc)).empty?
          Start::Prefix.new(prefix)
        elsif (literals = compiler.alternation_prefixes)
          Start::Literals.new(literals)
        elsif (byte_set = extract_start_byte_set(insns, start_pc))
          Start::ByteSet.new(byte_set)
        else
          Start::Any.new
        end

      freeze
    end

    # Attempt to match the pattern against the given string. If a match is
    # found, a MatchData instance is returned; otherwise, nil is returned.
    def match(string)
      return nil if @required_literal && !string.b.include?(@required_literal)
      @matcher.match(@start, string)
    end

    # True if the pattern matches the given string.
    def match?(string)
      return false if @required_literal && !string.b.include?(@required_literal)
      @matcher.match?(@start, string)
    end

    if RUBY_VERSION >= "4.0.0"
      def instance_variables_to_inspect
        [:@encoding, :@options, :@source]
      end
    else
      def inspect
        "#<#{self.class}:0x#{object_id.to_s(16)} " \
          "@encoding=#{@encoding.inspect}, " \
          "@options=#{@options.inspect}, " \
          "@source=#{@source.inspect}>"
      end
    end

    private

    # Returns true if every path from start_pc passes through a :bos
    # instruction before reaching any consume instruction. This means the
    # pattern can only match at position 0.
    def bos_anchored?(insns, start_pc)
      found_bos = false
      stack = [start_pc]
      visited = Set.new

      while (pc = stack.pop)
        next if visited.include?(pc)
        visited.add(pc)

        case insns[pc][0]
        when :bos
          found_bos = true
        when :consume_exact, :consume_set
          return false # Reached a consume without hitting :bos
        when :match
          next
        when :split
          stack << insns[pc][1]
          stack << insns[pc][2]
        when :jmp
          stack << insns[pc][1]
        when :save
          stack << insns[pc][2]
        else
          # Other zero-width assertions (:bol, :eos, :eol, etc.)
          stack << insns[pc][1]
        end
      end

      found_bos
    end

    # common literal byte prefix that every match must start with. Returns a
    # frozen binary string (possibly empty).
    def extract_start_prefix(insns, start_pc)
      prefix = []
      pc = start_pc
      seen_pcs = Set.new

      loop do
        break if seen_pcs.include?(pc)
        seen_pcs.add(pc)
        stack = [pc]
        visited = Set.new
        consume_insns = []

        while (current = stack.pop)
          next if visited.include?(current)
          visited.add(current)

          case (insn = insns[current])[0]
          when :consume_exact, :consume_set
            consume_insns << insn
          when :match
            return prefix.pack("C*").freeze
          when :split
            stack << insn[1]
            stack << insn[2]
          when :jmp
            stack << insn[1]
          when :save
            stack << insn[2]
          else
            stack << insn[1]
          end
        end

        break if consume_insns.empty?

        byte = nil
        next_pc = nil
        all_same = true

        consume_insns.each do |insn|
          insn_byte =
            case insn[0]
            when :consume_exact then insn[1]
            when :consume_set then insn[1].single
            end

          if insn_byte.nil? || insn_byte > 255
            all_same = false
            break
          elsif byte.nil?
            byte = insn_byte
            next_pc = insn[2]
          elsif byte != insn_byte || next_pc != insn[2]
            all_same = false
            break
          end
        end

        break unless all_same && byte

        prefix << byte
        pc = next_pc
      end

      prefix.pack("C*").freeze
    end

    # Walk the NFA from start_pc through epsilon transitions and union all
    # bytes from reachable consume instructions into a ByteSet. Returns nil if
    # a zero-length match is possible or all 256 bytes are present.
    def extract_start_byte_set(insns, start_pc)
      stack = [start_pc]
      visited = Set.new
      result = ByteSet.new

      while (current = stack.pop)
        next if visited.include?(current)
        visited.add(current)

        case (insn = insns[current])[0]
        when :consume_exact
          byte = insn[1]
          return nil if byte > 255
          result = result | ByteSet[byte..byte]
        when :consume_set
          result = result | insn[1]
        when :match
          return nil
        when :split
          stack << insn[1]
          stack << insn[2]
        when :jmp
          stack << insn[1]
        when :save
          stack << insn[2]
        else
          stack << insn[1]
        end
      end

      return nil if result == ByteSet[0..255]

      result
    end
  end
end
