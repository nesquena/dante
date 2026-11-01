# -*- encoding: utf-8 -*-
$:.push File.expand_path("../lib", __FILE__)
require "dante/version"

Gem::Specification.new do |s|
  s.name        = "dante"
  s.version     = Dante::VERSION
  s.authors     = ["Nathan Esquenazi"]
  s.email       = ["nesquena@gmail.com"]
  s.homepage    = "https://github.com/nesquena/dante"
  s.summary     = %q{Turn any process into a demon}
  s.description = %q{Turn any process into a demon.}
  s.license     = "MIT"
  s.metadata    = {
    "source_code_uri"       => "https://github.com/nesquena/dante",
    "changelog_uri"         => "https://github.com/nesquena/dante/blob/master/CHANGELOG.md",
    "bug_tracker_uri"       => "https://github.com/nesquena/dante/issues",
    "rubygems_mfa_required" => "true"
  }

  s.files         = `git ls-files`.split("\n")
  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
  s.require_paths = ["lib"]
  s.required_ruby_version = '>= 2.7'

  s.add_development_dependency 'rake'
  s.add_development_dependency 'minitest', '>= 5.0'
end
