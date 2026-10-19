# frozen_string_literal: true

require "minitest/autorun"
require "base64"
require "json"
require "openssl"
require_relative "../lib/railwatch/server/proxy_auth"

class ProxyAuthTest < Minitest::Test
  SECRET = "proxy-secret-proxy-secret-proxy-secret-0123"

  # The server (railwatch-rs web/proxy_auth.rs) verifies HMAC over
  # "v1." + payload and reads email/name/role/exp from the payload JSON.
  def test_the_header_is_what_the_server_verifies
    header = Railwatch::Server::ProxyAuth.sign(SECRET, email: "ada@example.com", name: "Ada", role: "admin", now: 1_000)
    version, payload, signature = header.split(".")
    assert_equal "v1", version
    expected = OpenSSL::HMAC.digest("SHA256", SECRET, "v1.#{payload}")
    assert_equal expected, Base64.urlsafe_decode64(signature + "=" * (-signature.size % 4))
    claims = JSON.parse(Base64.urlsafe_decode64(payload + "=" * (-payload.size % 4)))
    assert_equal({ "email" => "ada@example.com", "name" => "Ada", "role" => "admin", "exp" => 1_060 }, claims)
  end

  def test_a_header_is_good_for_a_minute_well_inside_the_servers_five_minute_cap
    assert_operator Railwatch::Server::ProxyAuth::TTL, :<=, 300
  end

  def test_only_admin_or_member_can_be_signed
    assert_raises(ArgumentError) { Railwatch::Server::ProxyAuth.sign(SECRET, email: "a@b.c", name: "A", role: "owner") }
  end
end
