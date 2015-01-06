# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'intermodal/version'

Gem::Specification.new do |spec|
  spec.name          = "intermodal"
  spec.version       = Intermodal::VERSION
  spec.authors       = ["Noah Zoschke"]
  spec.email         = ["noah@heroku.com"]
  spec.summary       = %q{Development, build, test and release workflow for 12 factor apps, via Docker.}
  spec.description   = %q{}
  spec.homepage      = ""
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`.split("\x0")
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_dependency "docker-api", "~> 1.17"

  spec.add_development_dependency "bundler", "~> 1.7"
  spec.add_development_dependency "rake", "~> 10.0"
end
