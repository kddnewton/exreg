# frozen_string_literal: true

require "rake/clean"
require "rake/testtask"

namespace :ext do
  load "ext/exreg/Rakefile"
end

Rake::TestTask.new(:test) do |t|
  t.libs << "lib"
  t.libs << "test"
  t.test_files = FileList["test/**/*_test.rb"]
end

CLEAN << "lib/exreg/unicode.data"
Rake::Task[:test].prerequisites << "ext:default"

task default: :test
