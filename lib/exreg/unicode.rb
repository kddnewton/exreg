# frozen_string_literal: true

module Exreg
  module Unicode
    CACHE_DIRECTORY = File.join(__dir__, "unicode")

    # This represents a range of codepoints.
    class Range
      attr_reader :min, :max

      def initialize(min:, max:)
        @min = min
        @max = max
      end

      def deconstruct_keys(keys)
        { min: min, max: max }
      end
    end

    # This represents a single codepoint.
    class Value
      attr_reader :value

      def initialize(value:)
        @value = value
      end

      def deconstruct_keys(keys)
        { value: value }
      end
    end

    # This represents a property that can be queried. Until it's _actually_
    # queried we don't want to have to read the file that contains all of the
    # codepoints.
    class LazyProperty
      attr_reader :filename, :entries

      def initialize(filename)
        @filename = filename
        @entries = nil
      end

      def [](key)
        value = (entries || read)[key]
        return nil unless value

        value
          .split(",")
          .map do |entry|
            if entry =~ /\A(\d+)\.\.(\d+)\z/
              Range.new(min: $1.to_i, max: $2.to_i)
            else
              Value.new(value: entry.to_i)
            end
          end
      end

      private

      # Read through the file and cache each of the entries.
      def read
        @entries = {}
        File.foreach(
          File.join(CACHE_DIRECTORY, filename),
          chomp: true
        ) do |line|
          _, name, items = *line.match(/\A(.+?)\s+(.+)\z/)
          @entries[name.downcase] = items
        end

        @entries
      end
    end

    # This class represents the cache of all of the expressions that we have
    # previously calculated within the \p{} syntax. We use this cache to quickly
    # efficiently craft transitions between states using properties.
    class Cache
      attr_reader :age,
                  :block,
                  :core_property,
                  :general_category,
                  :miscellaneous,
                  :property,
                  :script,
                  :script_extension

      def initialize
        @age = LazyProperty.new("age.txt")
        @block = LazyProperty.new("block.txt")
        @core_property = LazyProperty.new("core_property.txt")
        @general_category = LazyProperty.new("general_category.txt")
        @miscellaneous = LazyProperty.new("miscellaneous.txt")
        @property = LazyProperty.new("property.txt")
        @script_extension = LazyProperty.new("script.txt")
        @script = LazyProperty.new("script.txt")
      end

      # When you look up an entry using [], it's going to lazily convert each of
      # the entries into an actual object that you can use. It does this so it
      # doesn't waste space allocating a bunch of these objects because most
      # properties are not going to end up being used.
      def [](property)
        key, value = property.downcase.split("=", 2)
        value ? find_key_value(key, value) : find_key(key)
      end

      private

      def find_key(key)
        core_property[key] || general_category[key] || miscellaneous[key] ||
          property[key] || script_extension[key] || script[key] || raise
      end

      def find_key_value(key, value)
        case key
        when "age"
          age[value]
        when "block"
          block[value]
        when "general_category"
          case value
          when "letter"
            general_category["uppercase_letter"] +
              general_category["lowercase_letter"] +
              general_category["titlecase_letter"] +
              general_category["modifier_letter"] +
              general_category["other_letter"]
          when "mark"
            general_category["nonspacing_mark"] +
              general_category["enclosing_mark"] +
              general_category["spacing_mark"]
          else
            general_category[value]
          end
        when "script_extension"
          script_extension[value]
        when "script"
          script[value]
        else
          if core_property.key?(key) && value == "true"
            core_property[key]
          elsif property.key?(key) && value == "true"
            property[key]
          else
            raise
          end
        end
      end
    end

    def self.generate
      URI.open(
        "https://www.unicode.org/Public/#{version}/ucd/UCD.zip"
      ) do |file|
        Zip::File.open_buffer(file) do |zipfile|
          Generate.new(zipfile, CACHE_DIRECTORY).generate
        end
      end
    end

    def self.version
      RbConfig::CONFIG["UNICODE_VERSION"]
    end
  end
end
