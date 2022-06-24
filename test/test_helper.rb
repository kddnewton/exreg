# frozen_string_literal: true

require "simplecov"
SimpleCov.start

$:.unshift File.expand_path("../lib", __dir__)
require "exreg"
require "graphviz"
require "pp"

unless `which dot`.chomp.end_with?("dot")
  warn "YOU HAVE NOT INSTALLED GRAPHVIZ. We found no 'dot' in your path.\n" \
       "Please install Graphviz if you want dotfile visual output to work."
end

require "minitest/autorun"
