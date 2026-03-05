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
  class ByteOrderLE
    def order(bytes)
      bytes
    end
  end

  # A byte order handler for big-endian encoding.
  class ByteOrderBE
    def order(bytes)
      bytes.reverse
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

    attr_reader :insns, :start_pc, :ncaptures, :named_captures

    def initialize
      @bytesets = ByteSetSet.new
      @insns = []
      @start_pc = 0
      @ncaptures = 1
      @named_captures = {}
    end

    def compile(source, options)
      frag = compile_node(Parser.new(source).parse, options)

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

    private

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
      when "alnum"  then UCD["letter"] | UCD["mark"] | UCD["decimalnumber"]
      when "alpha"  then UCD["letter"] | UCD["mark"]
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
      when "word"   then UCD["letter"] | UCD["mark"] | UCD["decimalnumber"] | UCD["connectorpunctuation"]
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

    private

    def compile_set_encoded(unicode_set)
      frags = []

      unicode_set.each_range do |range|
        start_codepoint = range.begin
        end_codepoint = range.end - 1
        next if start_codepoint > end_codepoint

        alts = []

        if start_codepoint <= 0x7F
          alts << compile_consume_set(@bytesets.add(start_codepoint..[end_codepoint, 0x7F].min))
        end

        if end_codepoint >= 0x80
          if start_codepoint <= 0x7FF
            alts << compile_range_2([start_codepoint, 0x80].max, [end_codepoint, 0x7FF].min)
          end

          if end_codepoint >= 0x800
            alts << compile_range_3([start_codepoint, 0x800].max, [end_codepoint, 0xFFFF].min)
          end

          if end_codepoint >= 0x10000
            alts << compile_range_4([start_codepoint, 0x10000].max, [end_codepoint, 0x10FFFF].min)
          end
        end

        frags << compile_alts(alts)
      end

      raise InternalError, "Empty character set" if frags.empty?
      compile_alts(frags)
    end

    def compile_range_2(start_codepoint, end_codepoint)
      lead_start = 0xC0 | (start_codepoint >> 6)
      lead_end = 0xC0 | (end_codepoint >> 6)

      if lead_start == lead_end
        cont_start = 0x80 | (start_codepoint & 0x3F)
        cont_end = 0x80 | (end_codepoint & 0x3F)
        compile_seq([lead_start, cont_start..cont_end])
      else
        alts = []

        cont_start = 0x80 | (start_codepoint & 0x3F)
        alts << compile_seq([lead_start, cont_start..0xBF])

        if lead_end > lead_start + 1
          alts << compile_seq([(lead_start + 1)...lead_end, 0x80..0xBF])
        end

        cont_end = 0x80 | (end_codepoint & 0x3F)
        alts << compile_seq([lead_end, 0x80..cont_end])
        compile_alts(alts)
      end
    end

    def compile_range_3(start_codepoint, end_codepoint)
      lead_start = 0xE0 | (start_codepoint >> 12)
      lead_end = 0xE0 | (end_codepoint >> 12)

      if lead_start == lead_end
        compile_3byte_single_lead(lead_start, start_codepoint, end_codepoint)
      else
        alts = []

        codepoint_min = start_codepoint
        codepoint_max = [end_codepoint, ((lead_start & 0x0F) << 12) + 0xFFF].min
        alts << compile_3byte_single_lead(lead_start, codepoint_min, codepoint_max)

        if lead_end > lead_start + 1
          alts << compile_seq([(lead_start + 1)...lead_end, 0x80..0xBF, 0x80..0xBF])
        end

        codepoint_min = [start_codepoint, ((lead_end & 0x0F) << 12)].max
        codepoint_max = end_codepoint
        alts << compile_3byte_single_lead(lead_end, codepoint_min, codepoint_max)

        compile_alts(alts)
      end
    end

    def compile_3byte_single_lead(lead, start_codepoint, end_codepoint)
      second_start = 0x80 | ((start_codepoint >> 6) & 0x3F)
      second_end = 0x80 | ((end_codepoint >> 6) & 0x3F)

      if second_start == second_end
        third_start = 0x80 | (start_codepoint & 0x3F)
        third_end = 0x80 | (end_codepoint & 0x3F)

        compile_seq([lead, second_start, third_start..third_end])
      else
        alts = []

        third_start = 0x80 | (start_codepoint & 0x3F)
        alts << compile_seq([lead, second_start, third_start..0xBF])

        if second_end > second_start + 1
          alts << compile_seq([lead, (second_start + 1)...second_end, 0x80..0xBF])
        end

        third_end = 0x80 | (end_codepoint & 0x3F)
        alts << compile_seq([lead, second_end, 0x80..third_end])
        compile_alts(alts)
      end
    end

    def compile_range_4(start_codepoint, end_codepoint)
      lead_start = 0xF0 | (start_codepoint >> 18)
      lead_end = 0xF0 | (end_codepoint >> 18)

      if lead_start == lead_end
        compile_4byte_single_lead(lead_start, start_codepoint, end_codepoint)
      else
        alts = []

        codepoint_min = start_codepoint
        codepoint_max = [end_codepoint, ((lead_start & 0x07) << 18) + 0x3FFFF].min
        alts << compile_4byte_single_lead(lead_start, codepoint_min, codepoint_max)

        if lead_end > lead_start + 1
          alts << compile_seq([(lead_start + 1)...lead_end, 0x80..0xBF, 0x80..0xBF, 0x80..0xBF])
        end

        codepoint_min = [start_codepoint, ((lead_end & 0x07) << 18)].max
        codepoint_max = end_codepoint
        alts << compile_4byte_single_lead(lead_end, codepoint_min, codepoint_max)

        compile_alts(alts)
      end
    end

    def compile_4byte_single_lead(lead, start_codepoint, end_codepoint)
      second_start = 0x80 | ((start_codepoint >> 12) & 0x3F)
      second_end = 0x80 | ((end_codepoint >> 12) & 0x3F)

      if second_start == second_end
        compile_4byte_single_second(lead, second_start, start_codepoint, end_codepoint)
      else
        alts = []

        alts << compile_4byte_single_second(lead, second_start, start_codepoint, [end_codepoint, ((start_codepoint >> 12) << 12) + 0xFFF].min)
        if second_end > second_start + 1
          alts << compile_seq([lead, (second_start + 1)...second_end, 0x80..0xBF, 0x80..0xBF])
        end

        alts << compile_4byte_single_second(lead, second_end, [start_codepoint, ((end_codepoint >> 12) << 12)].max, end_codepoint)

        compile_alts(alts)
      end
    end

    def compile_4byte_single_second(lead, second, start_codepoint, end_codepoint)
      third_start = 0x80 | ((start_codepoint >> 6) & 0x3F)
      third_end = 0x80 | ((end_codepoint >> 6) & 0x3F)

      if third_start == third_end
        fourth_start = 0x80 | (start_codepoint & 0x3F)
        fourth_end = 0x80 | (end_codepoint & 0x3F)

        compile_seq([lead, second, third_start, fourth_start..fourth_end])
      else
        alts = []

        fourth_start = 0x80 | (start_codepoint & 0x3F)
        alts << compile_seq([lead, second, third_start, fourth_start..0xBF])

        if third_end > third_start + 1
          alts << compile_seq([lead, second, (third_start + 1)...third_end, 0x80..0xBF])
        end

        fourth_end = 0x80 | (end_codepoint & 0x3F)
        alts << compile_seq([lead, second, third_end, 0x80..fourth_end])
        compile_alts(alts)
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

    private

    def stream_order(bytes)
      @byte_order.order(bytes)
    end

    def compile_set_encoded(unicode_set)
      frags = []

      unicode_set.each_range do |range|
        start_codepoint = range.begin
        end_codepoint = range.end - 1
        next if start_codepoint > end_codepoint

        # Split range into BMP (U+0000-U+D7FF and U+E000-U+FFFF) and supplementary (U+10000-U+10FFFF)
        # Note: U+D800-U+DFFF are surrogate codepoints and invalid as scalar values

        alts = []

        # BMP before surrogates: U+0000-U+D7FF
        bmp1_start = [start_codepoint, 0x0000].max
        bmp1_end = [end_codepoint, 0xD7FF].min

        # BMP after surrogates: U+E000-U+FFFF
        bmp2_start = [start_codepoint, 0xE000].max
        bmp2_end = [end_codepoint, 0xFFFF].min

        # Supplementary: U+10000-U+10FFFF
        supp_start = [start_codepoint, 0x10000].max
        supp_end = [end_codepoint, 0x10FFFF].min

        # Handle BMP range before surrogates
        if bmp1_start <= bmp1_end
          alts << compile_bmp_range(bmp1_start, bmp1_end)
        end

        # Handle BMP range after surrogates
        if bmp2_start <= bmp2_end
          alts << compile_bmp_range(bmp2_start, bmp2_end)
        end

        # Handle supplementary range (4-byte surrogate pairs)
        if supp_start <= supp_end
          alts << compile_surrogate_range(supp_start, supp_end)
        end

        frags << compile_alts(alts)
      end

      raise InternalError, "Empty character set" if frags.empty?
      compile_alts(frags)
    end

    # Compile BMP codepoints (U+0000-U+FFFF) as 2-byte sequences
    def compile_bmp_range(start_codepoint, end_codepoint)
      # Extract logical bytes (byte0=LSB, byte1=MSB) for start and end
      byte0_start = start_codepoint & 0xFF
      byte0_end = end_codepoint & 0xFF
      byte1_start = (start_codepoint >> 8) & 0xFF
      byte1_end = (end_codepoint >> 8) & 0xFF

      if byte1_start == byte1_end
        # Only byte0 varies
        compile_seq(stream_order([byte0_start..byte0_end, byte1_start]))
      else
        alts = []

        # First: byte0_start..0xFF, byte1_start
        alts << compile_seq(stream_order([byte0_start..0xFF, byte1_start]))

        # Middle: 0..0xFF, (byte1_start+1)...(byte1_end)
        if byte1_end > byte1_start + 1
          alts << compile_seq(stream_order([0..0xFF, (byte1_start + 1)...byte1_end]))
        end

        # Last: 0..byte0_end, byte1_end
        alts << compile_seq(stream_order([0..byte0_end, byte1_end]))

        compile_alts(alts)
      end
    end

    # Compile supplementary codepoints (U+10000-U+10FFFF) as 4-byte surrogate pairs
    # High surrogate: 0xD800 + ((codepoint - 0x10000) >> 10)
    # Low surrogate: 0xDC00 + ((codepoint - 0x10000) & 0x3FF)
    def compile_surrogate_range(start_codepoint, end_codepoint)
      alts = []

      # Convert codepoints to surrogate pair components
      start_offset = start_codepoint - 0x10000
      end_offset = end_codepoint - 0x10000

      high_start = 0xD800 + (start_offset >> 10)
      high_end = 0xD800 + (end_offset >> 10)
      low_start = 0xDC00 + (start_offset & 0x3FF)
      low_end = 0xDC00 + (end_offset & 0x3FF)

      if high_start == high_end
        # Same high surrogate, only low surrogate varies
        alts << compile_surrogate_pair_range(high_start, high_start, low_start, low_end)
      else
        # First: high_start with low_start..0xDFFF
        alts << compile_surrogate_pair_range(high_start, high_start, low_start, 0xDFFF)

        # Middle: (high_start+1)...(high_end) with 0xDC00..0xDFFF
        if high_end > high_start + 1
          alts << compile_surrogate_pair_range(high_start + 1, high_end - 1, 0xDC00, 0xDFFF)
        end

        # Last: high_end with 0xDC00..low_end
        alts << compile_surrogate_pair_range(high_end, high_end, 0xDC00, low_end)
      end

      compile_alts(alts)
    end

    # Compile a range of surrogate pairs where high surrogate is in [high_start, high_end]
    # and low surrogate is in [low_start, low_end]
    def compile_surrogate_pair_range(high_start, high_end, low_start, low_end)
      high_frag = if high_start == high_end
        compile_bmp_range(high_start, high_start)
      else
        compile_bmp_range(high_start, high_end)
      end

      low_frag = if low_start == low_end
        compile_bmp_range(low_start, low_start)
      else
        compile_bmp_range(low_start, low_end)
      end

      # Concatenate high and low surrogate fragments
      patch_insns(high_frag[1], low_frag[0])
      [high_frag[0], low_frag[1]]
    end
  end

  # Base class for UTF-32 encodings (little-endian and big-endian)
  # This class treats byte0 as LSB and byte3 as MSB for logical operations
  # Subclasses must implement stream_order to convert to actual byte order
  class Compiler::UTF_32 < Compiler
    def initialize(byte_order)
      super()
      @byte_order = byte_order
    end

    def word_boundary
      WordBoundary::UTF_32.new(@byte_order, word_set)
    end

    private

    def stream_order(bytes)
      @byte_order.order(bytes)
    end

    def compile_set_encoded(unicode_set)
      frags = []

      unicode_set.each_range do |range|
        start_codepoint = range.begin
        end_codepoint = range.end - 1
        next if start_codepoint > end_codepoint

        # Extract logical bytes (byte0=LSB, byte3=MSB) for start and end codepoints
        byte0_start = start_codepoint & 0xFF
        byte0_end = end_codepoint & 0xFF
        byte1_start = (start_codepoint >> 8) & 0xFF
        byte1_end = (end_codepoint >> 8) & 0xFF
        byte2_start = (start_codepoint >> 16) & 0xFF
        byte2_end = (end_codepoint >> 16) & 0xFF
        byte3_start = (start_codepoint >> 24) & 0xFF
        byte3_end = (end_codepoint >> 24) & 0xFF

        if byte3_start == byte3_end && byte2_start == byte2_end && byte1_start == byte1_end
          # All bytes except byte0 are the same
          frags << compile_seq(stream_order([byte0_start..byte0_end, byte1_start, byte2_start, byte3_start]))
        elsif byte3_start == byte3_end && byte2_start == byte2_end
          # Bytes 2 and 3 are the same, bytes 0 and 1 vary
          alts = []

          if byte1_start == byte1_end
            # Only byte0 varies
            alts << compile_seq(stream_order([byte0_start..byte0_end, byte1_start, byte2_start, byte3_start]))
          else
            # First sequence: byte0_start..0xFF, byte1_start
            alts << compile_seq(stream_order([byte0_start..0xFF, byte1_start, byte2_start, byte3_start]))

            # Middle sequences: 0..0xFF, (byte1_start+1)...(byte1_end)
            if byte1_end > byte1_start + 1
              alts << compile_seq(stream_order([0..0xFF, (byte1_start + 1)...byte1_end, byte2_start, byte3_start]))
            end

            # Last sequence: 0..byte0_end, byte1_end
            alts << compile_seq(stream_order([0..byte0_end, byte1_end, byte2_start, byte3_start]))
          end

          frags << compile_alts(alts)
        elsif byte3_start == byte3_end
          # Byte 3 is the same, bytes 0-2 vary
          alts = []

          # First: handle start_codepoint to end of its byte2 range
          codepoint_max = [end_codepoint, ((byte2_start << 16) | 0xFFFF)].min
          alts << compile_utf32_byte2_range(byte2_start, byte3_start, start_codepoint, codepoint_max)

          # Middle: full byte2 ranges
          if byte2_end > byte2_start + 1
            alts << compile_seq(stream_order([0..0xFF, 0..0xFF, (byte2_start + 1)...byte2_end, byte3_start]))
          end

          # Last: beginning of byte2_end range to end_codepoint
          codepoint_min = [start_codepoint, (byte2_end << 16)].max
          alts << compile_utf32_byte2_range(byte2_end, byte3_start, codepoint_min, end_codepoint)

          frags << compile_alts(alts)
        else
          # Byte 3 varies (most complex case)
          alts = []

          # First: handle start_codepoint to end of its byte3 range
          codepoint_max = [end_codepoint, ((byte3_start << 24) | 0xFFFFFF)].min
          alts << compile_utf32_byte3_range(byte3_start, start_codepoint, codepoint_max)

          # Middle: full byte3 ranges
          if byte3_end > byte3_start + 1
            alts << compile_seq(stream_order([0..0xFF, 0..0xFF, 0..0xFF, (byte3_start + 1)...byte3_end]))
          end

          # Last: beginning of byte3_end range to end_codepoint
          codepoint_min = [start_codepoint, (byte3_end << 24)].max
          alts << compile_utf32_byte3_range(byte3_end, codepoint_min, end_codepoint)

          frags << compile_alts(alts)
        end
      end

      raise InternalError, "Empty character set" if frags.empty?
      compile_alts(frags)
    end

    def compile_utf32_byte2_range(byte2, byte3, start_codepoint, end_codepoint)
      byte0_start = start_codepoint & 0xFF
      byte0_end = end_codepoint & 0xFF
      byte1_start = (start_codepoint >> 8) & 0xFF
      byte1_end = (end_codepoint >> 8) & 0xFF

      if byte1_start == byte1_end
        compile_seq(stream_order([byte0_start..byte0_end, byte1_start, byte2, byte3]))
      else
        alts = []

        # First: byte0_start..0xFF, byte1_start
        alts << compile_seq(stream_order([byte0_start..0xFF, byte1_start, byte2, byte3]))

        # Middle: 0..0xFF, (byte1_start+1)...(byte1_end)
        if byte1_end > byte1_start + 1
          alts << compile_seq(stream_order([0..0xFF, (byte1_start + 1)...byte1_end, byte2, byte3]))
        end

        # Last: 0..byte0_end, byte1_end
        alts << compile_seq(stream_order([0..byte0_end, byte1_end, byte2, byte3]))

        compile_alts(alts)
      end
    end

    def compile_utf32_byte3_range(byte3, start_codepoint, end_codepoint)
      byte2_start = (start_codepoint >> 16) & 0xFF
      byte2_end = (end_codepoint >> 16) & 0xFF

      if byte2_start == byte2_end
        compile_utf32_byte2_range(byte2_start, byte3, start_codepoint, end_codepoint)
      else
        alts = []

        # First: handle start_codepoint to end of its byte2 range
        codepoint_max = [end_codepoint, ((byte2_start << 16) | 0xFFFF)].min
        alts << compile_utf32_byte2_range(byte2_start, byte3, start_codepoint, codepoint_max)

        # Middle: full byte2 ranges
        if byte2_end > byte2_start + 1
          alts << compile_seq(stream_order([0..0xFF, 0..0xFF, (byte2_start + 1)...byte2_end, byte3]))
        end

        # Last: beginning of byte2_end range to end_codepoint
        codepoint_min = [start_codepoint, (byte2_end << 16)].max
        alts << compile_utf32_byte2_range(byte2_end, byte3, codepoint_min, end_codepoint)

        compile_alts(alts)
      end
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

    # A start strategy that matches a single byte from a set of bytes (e.g. from
    # a character class).
    class ByteSet
      def initialize(byte_set)
        @byte_set = byte_set
        freeze
      end

      def each_pos(string, string_len)
        string_len.times do |idx|
          yield idx if @byte_set.has?(string.getbyte(idx))
        end
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

  # Bitmask constants for the lazy DFA.
  module DFA
    # Bits for detect_anchor_types: which anchor instructions exist in the
    # pattern. Used to skip unnecessary context computation.
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
      attr_reader :pc_set, :is_match

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

      def next_state(context, byte)
        if context == 0
          @transitions&.[](byte)
        else
          @ctx_transitions&.[](context)&.[](byte)
        end
      end

      def set_next_state(context, byte, state)
        if context == 0
          (@transitions ||= Array.new(256))[byte] = state
        else
          ((@ctx_transitions ||= {})[context] ||= Array.new(256))[byte] = state
        end
      end
    end
  end

  private_constant :USet, :UCD, :ByteSet, :Parser, :ByteOrderLE, :ByteOrderBE,
                   :WordBoundary, :Compiler, :Start, :DFA

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
    attr_reader :source

    def initialize(source, options = Option::NONE, encoding = Encoding::UTF_8)
      compiler = Compiler.for(encoding)
      compiler.compile(source, options)

      @source = source
      @insns = compiler.insns.freeze
      @start_pc = compiler.start_pc
      @ncaptures = compiler.ncaptures
      @named_captures = compiler.named_captures.freeze
      @word_boundary = compiler.word_boundary

      @dfa_eligible = @insns.none? { |insn| insn[0] == :atomic_enter || insn[0] == :atomic_leave }

      if @dfa_eligible
        @anchor_types = detect_anchor_types
        @dfa_states = {}
        @dfa_visited = Array.new(@insns.length)
        @dfa_next_pcs = []
        @dfa_initial_state = @anchor_types == 0 ? dfa_closure([@start_pc], "".b, 0, 0) : nil
      end

      @nfa_visited = Array.new(@insns.length)
      @nfa_consume_visited = Array.new(@insns.length)

      @start =
        if !(prefix = extract_literal_prefix).empty?
          Start::Prefix.new(prefix)
        elsif (byte_set = extract_first_byte_set)
          Start::ByteSet.new(byte_set)
        else
          Start::Any.new
        end

      freeze
    end

    # Attempt to match the pattern against the given string. If a match is
    # found, a MatchData instance is returned; otherwise, nil is returned.
    def match(string)
      string_len = string.bytesize

      if @dfa_eligible
        @start.each_pos(string, string_len) do |string_idx|
          if dfa_match_at(string, string_idx, string_len)
            match = match_at(string, string_idx, string_len)
            return match if match
          end
        end
        nil
      else
        @start.each_pos(string, string_len) do |string_idx|
          match = match_at(string, string_idx, string_len)
          return match if match
        end
        nil
      end
    end

    # True if the pattern matches the given string.
    def match?(string)
      if @dfa_eligible
        string_len = string.bytesize
        @start.each_pos(string, string_len) do |string_idx|
          return true if dfa_match_at(string, string_idx, string_len)
        end
        false
      else
        !match(string).nil?
      end
    end

    private

    # Walk the NFA from @start_pc through epsilon transitions to find a
    # common literal byte prefix that every match must start with. Returns a
    # frozen binary string (possibly empty).
    def extract_literal_prefix
      prefix = []
      pc = @start_pc
      seen_pcs = Set.new

      loop do
        break if seen_pcs.include?(pc)
        seen_pcs.add(pc)
        # Walk epsilon closure from pc, collecting all reachable consume instructions.
        stack = [pc]
        visited = Set.new
        consume_insns = []

        while (current = stack.pop)
          next if visited.include?(current)
          visited.add(current)

          case (insn = @insns[current])[0]
          when :consume_exact, :consume_set
            consume_insns << insn
          when :match
            # A match is reachable — the prefix could be empty, stop here.
            return prefix.pack("C*").freeze
          when :split
            stack << insn[1]
            stack << insn[2]
          when :jmp
            stack << insn[1]
          when :save
            stack << insn[2]
          else
            # Anchors — treat as epsilon
            stack << insn[1]
          end
        end

        break if consume_insns.empty?

        # Check if all consume instructions agree on the same single byte
        # and the same next PC.
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

    # Walk the NFA from @start_pc through epsilon transitions and union all
    # bytes from reachable consume instructions into a ByteSet. Returns nil if
    # a zero-length match is possible or all 256 bytes are present.
    def extract_first_byte_set
      stack = [@start_pc]
      visited = Set.new
      result = ByteSet.new

      while (current = stack.pop)
        next if visited.include?(current)
        visited.add(current)

        case (insn = @insns[current])[0]
        when :consume_exact
          byte = insn[1]
          return nil if byte > 255
          result = result | ByteSet[byte..byte]
        when :consume_set
          result = result | insn[1]
        when :match
          # Zero-length match possible — all positions are candidates.
          return nil
        when :split
          stack << insn[1]
          stack << insn[2]
        when :jmp
          stack << insn[1]
        when :save
          stack << insn[2]
        else
          # Anchors — treat as epsilon
          stack << insn[1]
        end
      end

      # If all 256 bits are set, the set is useless.
      return nil if result == ByteSet[0..255]

      result
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

    def closure(entries, string_idx, string_len, string)
      state = []
      stack = entries.dup
      visited = @nfa_visited
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
      visited = @nfa_consume_visited
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

    # Detect which anchor instruction types exist in the pattern. Returns a
    # bitmask so compute_context can skip unnecessary work.
    def detect_anchor_types
      types = 0
      @insns.each do |insn|
        case insn[0]
        when :bol then types |= DFA::AnchorType::BOL
        when :eol then types |= DFA::AnchorType::EOL
        when :bos then types |= DFA::AnchorType::BOS
        when :eos then types |= DFA::AnchorType::EOS
        when :eosnl then types |= DFA::AnchorType::EOSNL
        when :wb, :nwb then types |= DFA::AnchorType::WORD_BOUNDARY
        end
      end
      types
    end

    # Compute position-dependent context flags for DFA epsilon closure. Only
    # computes flags for anchor types actually used by the pattern.
    def compute_context(string, string_idx, string_len)
      return 0 if @anchor_types == 0

      ctx = 0

      if @anchor_types & (DFA::AnchorType::BOL | DFA::AnchorType::BOS) != 0
        ctx |= DFA::Context::AT_START if string_idx == 0
      end

      if @anchor_types & DFA::AnchorType::BOL != 0
        ctx |= DFA::Context::PREV_NEWLINE if string_idx > 0 && string.getbyte(string_idx - 1) == 0x0A
      end

      if @anchor_types & (DFA::AnchorType::EOL | DFA::AnchorType::EOS | DFA::AnchorType::EOSNL) != 0
        ctx |= DFA::Context::AT_END if string_idx == string_len
      end

      if @anchor_types & (DFA::AnchorType::EOL | DFA::AnchorType::EOSNL) != 0
        ctx |= DFA::Context::CURR_NEWLINE if string_idx < string_len && string.getbyte(string_idx) == 0x0A
      end

      if @anchor_types & DFA::AnchorType::EOSNL != 0
        ctx |= DFA::Context::PENULTIMATE if string_idx + 1 == string_len
      end

      if @anchor_types & DFA::AnchorType::WORD_BOUNDARY != 0
        ctx |= DFA::Context::WORD_BOUNDARY if @word_boundary.boundary?(string, string_idx)
      end

      ctx
    end

    # Capture-free epsilon closure for DFA. Returns a DFA::State representing
    # the set of NFA PCs at consume instructions reachable from the given PCs.
    def dfa_closure(pcs, string, string_idx, string_len)
      consume_pcs = []
      stack = pcs.dup
      visited = @dfa_visited
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
      intern_dfa_state(consume_pcs, is_match)
    end

    # Intern DFA states so equal (pc_set, is_match) pairs share the same
    # object. The same pc_set can have different is_match values depending
    # on which epsilon transitions were followed to reach the consume states.
    def intern_dfa_state(sorted_pcs, is_match)
      key = [sorted_pcs, is_match]
      if (existing = @dfa_states[key])
        existing
      else
        state = DFA::State.new(sorted_pcs, is_match)
        @dfa_states[key] = state
        state
      end
    end

    # DFA matching loop. Returns the end position of the match (Integer) or
    # nil if no match exists starting at start_idx.
    def dfa_match_at(string, start_idx, string_len)
      state = @dfa_initial_state || dfa_closure([@start_pc], string, start_idx, string_len)

      return nil if state.dead? && !state.is_match

      last_match_end = state.is_match ? start_idx : nil

      string_idx = start_idx
      while string_idx < string_len
        byte = string.getbyte(string_idx)
        next_ctx = @anchor_types == 0 ? 0 : compute_context(string, string_idx + 1, string_len)

        # Cache key uses next position's context since the epsilon closure
        # that produces next_state runs at string_idx + 1.
        next_state = state.next_state(next_ctx, byte)

        unless next_state
          @dfa_next_pcs.clear
          state.pc_set.each do |pc|
            insn = @insns[pc]
            case insn[0]
            when :consume_exact
              @dfa_next_pcs << insn[2] if insn[1] == byte
            when :consume_set
              @dfa_next_pcs << insn[2] if insn[1].has?(byte)
            end
          end

          next_state = dfa_closure(@dfa_next_pcs, string, string_idx + 1, string_len)
          state.set_next_state(next_ctx, byte, next_state)
        end

        state = next_state
        string_idx += 1
        last_match_end = string_idx if state.is_match
        break if state.dead?
      end

      # Check for match at EOF (for anchors like $, \z, \Z)
      if !state.dead? && !state.is_match
        eof_state = dfa_closure(state.pc_set.to_a, string, string_idx, string_len)
        last_match_end = string_idx if eof_state.is_match
      end

      last_match_end
    end
  end
end
