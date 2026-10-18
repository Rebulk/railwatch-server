# frozen_string_literal: true

require "base64"
require "json"
require "openssl"

module Railwatch
  module Server
    # The header the server trusts as "this request is user X with role Y"
    # (rust-patches/: web/proxy_auth.rs, `trusted_proxy_secret_file`):
    #
    #   v1.<base64url(claims JSON)>.<base64url(HMAC-SHA256(secret, "v1." + claims))>
    #
    # Signed per request and valid for TTL seconds; the server refuses
    # anything valid for longer than 300.
    module ProxyAuth
      HEADER = "X-Railwatch-Proxy-Auth"
      TTL = 60
      ROLES = %w[admin member].freeze

      module_function

      def sign(secret, email:, name:, role:, now: Time.now.to_i)
        raise ArgumentError, "role must be one of #{ROLES.join(', ')}" unless ROLES.include?(role.to_s)

        claims = { email: email.to_s, name: name.to_s, role: role.to_s, exp: now + TTL }
        signed = "v1.#{Base64.urlsafe_encode64(JSON.generate(claims), padding: false)}"
        signature = Base64.urlsafe_encode64(OpenSSL::HMAC.digest("SHA256", secret, signed), padding: false)
        "#{signed}.#{signature}"
      end
    end
  end
end
