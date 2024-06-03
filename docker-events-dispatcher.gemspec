# coding: utf-8

lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'docker_events_dispatcher/version'
require 'find'

Gem::Specification.new do |spec|
  spec.name     = "docker-events-dispatcher"
  spec.version  = DockerEventsDispatcher::VERSION
  spec.authors  = ["konsolebox"]
  spec.email    = ["konsolebox@gmail.com"]
  spec.summary  = "Calls hook scripts on every docker event"
  spec.homepage = "https://github.com/konsolebox/docker-events-dispatcher"
  spec.license  = "MIT"

  spec.required_ruby_version = ">= 3.2"

  spec.files = %w[
    Gemfile
    LICENSE
    NOTICE
    README.md
    Rakefile
    docker-events-dispatcher.gemspec
  ]
  spec.files += Find.find("lib").to_a

  spec.bindir        = "exe"
  spec.executables   = ["docker-events-dispatcher"]
  spec.test_files    = []
  spec.require_paths = ["lib"]

  spec.add_runtime_dependency "httparty", "~> 0.22"
  spec.add_development_dependency "rake"
end
