# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.test_files = FileList["test/**/*_test.rb"].exclude("test/inertia_host_test.rb")
end

# Its own process: it boots Rails (inertia_rails needs it), and Rails.env
# would then decide every other test's environment.
Rake::TestTask.new(:test_inertia_host) do |t|
  t.libs << "test"
  t.test_files = FileList["test/inertia_host_test.rb"]
end
task test: :test_inertia_host

PLATFORMS = %w[x86_64-linux aarch64-linux x86_64-darwin arm64-darwin].freeze

namespace :gem do
  desc "Build the plain gem (no binary)"
  task :ruby do
    sh({ "RAILWATCH_SERVER_PLATFORM" => nil }, "gem build railwatch-server.gemspec -o pkg/railwatch-server-ruby.gem")
  end

  PLATFORMS.each do |platform|
    desc "Build the #{platform} gem with exe/#{platform}/railwatch (script/build-server makes it)"
    task platform do
      abort "exe/#{platform}/railwatch is missing: script/build-server <railwatch-rs> #{platform}" unless File.executable?("exe/#{platform}/railwatch")
      sh({ "RAILWATCH_SERVER_PLATFORM" => platform }, "gem build railwatch-server.gemspec -o pkg/railwatch-server-#{platform}.gem")
    end
  end

  desc "Build every gem"
  task all: [ :ruby, *PLATFORMS ]
end

task default: :test
