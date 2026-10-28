# frozen_string_literal: true

require_relative "lib/railwatch/server/version"

Gem::Specification.new do |spec|
  spec.name = "railwatch-server"
  spec.version = Railwatch::Server::VERSION
  spec.authors = [ "Rebulk" ]
  spec.summary = "The Railwatch server, bundled: the full Railwatch dashboard at /railwatch in your Rails app, run as its own process"
  spec.homepage = "https://github.com/Rebulk/railwatch-server"
  # This gem ships the Railwatch server binary (NOTICE). The railwatch agent it
  # depends on is MIT and a separate gem.
  spec.license = "FSL-1.1-ALv2"
  spec.required_ruby_version = ">= 3.2"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["railwatch_rs_source"] = "https://github.com/Rebulk/railwatch-rs"

  spec.files = Dir["{app,lib}/**/*", "LICENSE", "NOTICE", "README.md"]
  # `rake gem:<platform>` sets RAILWATCH_SERVER_PLATFORM to build the
  # platform gem with that platform's binary; without it, the plain "ruby"
  # gem, which has none and tells the user how to get one (Binary.path).
  if (platform = ENV["RAILWATCH_SERVER_PLATFORM"])
    spec.platform = platform
    spec.files += [ "exe/#{platform}/railwatch" ]
  end
  spec.require_paths = [ "lib" ]

  spec.add_dependency "railwatch", ">= 1.4"
  spec.add_dependency "railties", ">= 7.2"

  # test/inertia_host_test.rb: the 3.22 middleware that turned dashboard clicks into full reloads.
  spec.add_development_dependency "inertia_rails", ">= 3.22"
end
