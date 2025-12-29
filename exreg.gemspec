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
  spec.require_paths = ["lib"]
  spec.extensions = ["ext/exreg/Rakefile"]

  spec.metadata = {
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "changelog_uri" => "#{spec.homepage}/blob/v#{spec.version}/CHANGELOG.md",
    "source_code_uri" => spec.homepage,
    "rubygems_mfa_required" => "true"
  }

  spec.files = %w[
    README.md
    Rakefile
    exreg.gemspec
    ext/exreg/Rakefile
    lib/exreg.rb
    lib/exreg/version.rb
  ]

  spec.add_dependency "rubyzip"
  spec.add_dependency "strscan"

  spec.add_development_dependency "bundler"
  spec.add_development_dependency "minitest"
  spec.add_development_dependency "rake"
end
