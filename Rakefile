# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"
require "syntax_tree/rake_tasks"

UNICODE_CACHES =
  %w[
    age
    core_property
    general_category
    miscellaneous
    property
    script
    script_extension
  ].map { "lib/exreg/unicode/#{_1}.txt" }

UNICODE_CACHES.each do |filepath|
  file filepath do
    require "bundler/setup"

    $:.unshift(File.expand_path("lib", __dir__))
    require "exreg"
    require "exreg/unicode/generate"

    Exreg::Unicode.generate
  end
end

Rake::TestTask.new(test: UNICODE_CACHES) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

task default: :test

configure = ->(task) do
  task.source_files =
    FileList[%w[Gemfile Rakefile *.gemspec lib/**/*.rb test/**/*.rb]]

  task.source_files -= FileList[%w[lib/exreg/alphabet.rb lib/exreg/parser.rb]]
end

SyntaxTree::Rake::CheckTask.new(&configure)
SyntaxTree::Rake::WriteTask.new(&configure)
