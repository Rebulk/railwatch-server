# frozen_string_literal: true

require "puma/plugin"

# `plugin :railwatch_server`, the name before railwatch-server became
# railwatch-sidecar (0.2.0): the same plugin. Use `plugin :railwatch_sidecar`;
# this one works until 1.0.
require_relative "railwatch_sidecar"

warn("[railwatch-sidecar] DEPRECATED: `plugin :railwatch_server` is now `plugin :railwatch_sidecar` in config/puma.rb " \
     "(railwatch-server was renamed railwatch-sidecar; the old name works until 1.0)")
Puma::Plugins.register("railwatch_server", Puma::Plugins.find("railwatch_sidecar"))
