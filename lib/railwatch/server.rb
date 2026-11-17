# frozen_string_literal: true

# `require "railwatch/server"`, the path before the rename (railwatch-server);
# it loads railwatch-sidecar, and Railwatch::Server is Railwatch::Sidecar.
require_relative "sidecar"
