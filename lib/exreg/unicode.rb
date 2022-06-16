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

    # This class represents the cache of all of the expressions that we have
    # previously calculated within the \p{} syntax. We use this cache to quickly
    # efficiently craft transitions between states using properties.
    class Cache
      attr_reader :age, :block, :core_property, :general_category,
                  :miscellaneous, :property, :script, :script_extension

      def initialize
        @age = read_file("age.txt")
        @block = read_file("block.txt")
        @core_property = read_file("core_property.txt")
        @general_category = read_file("general_category.txt")
        @miscellaneous = read_file("miscellaneous.txt")
        @property = read_file("property.txt")
        @script_extension = read_file("script.txt")
        @script = read_file("script.txt")
      end

      # When you look up an entry using [], it's going to lazily convert each of
      # the entries into an actual object that you can use. It does this so it
      # doesn't waste space allocating a bunch of these objects because most
      # properties are not going to end up being used.
      def [](property)
        key, value = property.downcase.split("=", 2)
        entry = value ? find_key_value(key, value) : find_key(key)

        entry.split(",").map do |entry|
          if entry =~ /\A(\d+)\.\.(\d+)\z/
            Range.new(min: $1.to_i, max: $2.to_i)
          else
            Value.new(value: entry.to_i)
          end
        end
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
          general_category[value]
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

      def read_file(filename)
        {}.tap do |entries|
          File.foreach(File.join(CACHE_DIRECTORY, filename), chomp: true) do |line|
            _, name, items = *line.match(/\A(.+?)\s+(.+)\z/)
            entries[name.downcase] = items
          end
        end
      end
    end

    def self.generate
      URI.open("https://www.unicode.org/Public/#{version}/ucd/UCD.zip") do |file|
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
