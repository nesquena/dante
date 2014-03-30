# coding: utf-8
lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "dante/version"

Gem::Specification.new do |spec|
  spec.name          = "dante"
  spec.version       = Dante::VERSION
  spec.authors       = ["Nathan Esquenazi"]
  spec.email         = ["nesquena@gmail.com"]
  spec.summary       = %q{Turn any process into a demon}
  spec.description   = spec.summary
  spec.homepage      = "https://nesquena.github.io/dante"
  spec.license       = "MIT"

  spec.files         = Dir["lib/**/*"]
  spec.executables   = Dir["bin/**/*"].map! { |f| f.gsub(/bin\//, "") }
  spec.test_files    = Dir["test/**/*", "spec/**/*"]
  spec.require_paths = ["lib"]

  spec.add_runtime_dependency "astruct", "~> 2.11"
  spec.add_development_dependency "bundler", "~> 1.3"
  spec.add_development_dependency "rspec", "~> 2.14"
  spec.add_development_dependency "rake", "~> 10.1"
  spec.add_development_dependency "yard", "~> 0.8"
  spec.add_development_dependency "kramdown", "~> 1.2"
  spec.add_development_dependency "pry", "~> 0.9"
  spec.add_development_dependency "coveralls", "~> 0.7"
  spec.add_development_dependency "rubocop", "~> 0.15"
end
