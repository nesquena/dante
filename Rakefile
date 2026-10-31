require 'bundler/gem_tasks'
require 'rake/testtask'
# require 'yard'

TEST_FILES = FileList[File.expand_path('../test/**/*_test.rb', __FILE__)]

Rake::TestTask.new do |t|
  t.libs.push "lib"
  t.test_files = TEST_FILES
  t.verbose = true
end

# Rake::TestTask treats an empty file list as a passing run of nothing.
task :test_files_present do
  abort "No test files match test/**/*_test.rb" if TEST_FILES.empty?
end
task :test => :test_files_present

task :default => :test

# task :doc do
#  YARD::CLI::Yardoc.new.run
# end
