# frozen_string_literal: true

module Railwatch
  module Server
    VERSION = "0.1.0.pre1"
    # The railwatch-rs commit the bundled binaries are built from, plus the
    # patches in rust-patches/ (README, "The Rust patch").
    RAILWATCH_RS = "fc318ed+rust-patches/0001-0002"
  end
end
