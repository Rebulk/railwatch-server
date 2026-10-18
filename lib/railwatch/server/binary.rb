# frozen_string_literal: true

module Railwatch
  module Server
    # The bundled `railwatch` executable, the way tailwindcss-ruby finds its
    # own: one directory per platform under exe/, and the platform gem for
    # this machine carries exactly one of them. The plain "ruby" gem has
    # none and says so.
    module Binary
      PLATFORMS = %w[x86_64-linux aarch64-linux x86_64-darwin arm64-darwin].freeze
      DIR = File.expand_path("../../../exe", __dir__)
      GEM_NAME = "railwatch-server"

      class NotFound < StandardError; end

      module_function

      def path
        own = Railwatch::Server.config.binary
        if own
          raise NotFound, "RAILWATCH_SERVER_BINARY=#{own} is not an executable file" unless File.executable?(own)

          return own
        end

        found = Dir.glob(File.join(DIR, "*", "railwatch")).find do |file|
          Gem::Platform.match_gem?(Gem::Platform.new(File.basename(File.dirname(file))), GEM_NAME)
        end
        return found if found && File.executable?(found)

        raise NotFound, <<~MESSAGE.strip
          railwatch-server has no Railwatch server binary for #{local_platform}.
          Prebuilt binaries ship in the #{PLATFORMS.join(', ')} gems; this is the plain one.
          Either let Bundler pick the platform gem (`bundle lock --add-platform #{local_platform}`,
          and check `bundle config force_ruby_platform` is not true), or install the server
          yourself (https://github.com/Rebulk/railwatch-rs, docs/SELF-HOST.md) and set
          RAILWATCH_SERVER_BINARY=/path/to/railwatch.
        MESSAGE
      end

      def local_platform
        [ Gem::Platform.local.cpu, Gem::Platform.local.os ].join("-")
      end
    end
  end
end
