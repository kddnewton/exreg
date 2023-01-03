# frozen_string_literal: true

require_relative "lib/exreg/version"

Gem::Specification.new do |spec|
  spec.name = "exreg"
  spec.version = Exreg::VERSION
  spec.authors = ["Kevin Newton"]
  spec.email = ["kddnewton@gmail.com"]

  spec.summary = "A Ruby regular expression engine"
  spec.homepage = "https://github.com/kddnewton/exreg"
  spec.license = "MIT"

  spec.files =
    Dir.chdir(__dir__) do
      `git ls-files -z`.split("\x0")
        .reject { |f| f.match(%r{^(\.github|demo|test|spec|features)/}) }
    end

  spec.metadata = { "rubygems_mfa_required" => "true" }
  spec.require_paths = ["lib"]
end
