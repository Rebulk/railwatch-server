# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "rails"
require "action_controller/railtie"
require "action_dispatch/middleware/flash"
require "action_controller/test_case"
require "railwatch/server"
require_relative "../app/controllers/railwatch/server/proxy_controller"

require "inertia_rails"
require "inertia_rails/extensions/request"

# A host app on inertia_rails puts its middleware around the proxy, and that
# middleware answers an Inertia visit whose X-Inertia-Version isn't the app's
# with a 409 and X-Inertia-Location: a full page load. The version the
# dashboard sends is the server's, so every click in the dashboard was a
# full reload (inertia_rails 3.22, which looks only at X-Inertia and the
# version, not at what the controller is).
class InertiaHostTest < Minitest::Test
  def setup
    # What the gem's engine does when the app boots.
    ActionController::Base.include(InertiaRails::Controller) unless ActionController::Base < InertiaRails::Controller
    ActionDispatch::Request.include(InertiaRails::InertiaRequest) if defined?(InertiaRails::InertiaRequest)
    InertiaRails.configure { |c| c.version = "the-apps-version" }
    @dir = Dir.mktmpdir
    File.write(File.join(@dir, "proxy_secret"), "s" * 64)
    Railwatch::Server.configure { |c| c.data_dir = @dir }
  end

  def teardown
    FileUtils.rm_rf(@dir) if @dir
  end

  # The server's answer stands in for the proxied response: what matters is
  # whether the app's middleware replaces it with its own 409.
  def visit(controller_class)
    app = InertiaRails::Middleware.new(lambda do |env|
      controller_class.action(:forward).call(env)
    end)
    env = Rack::MockRequest.env_for("http://shop.example/railwatch/dashboard",
                                    "HTTP_X_INERTIA" => "true", "HTTP_X_INERTIA_VERSION" => "the-servers-version")
    env["rack.session"] = ActionController::TestSession.new
    env["action_dispatch.request.path_parameters"] = { controller: "railwatch/server/proxy", action: "forward" }
    app.call(env)
  end

  def test_a_dashboard_click_is_not_turned_into_a_full_page_load
    controller = Class.new(Railwatch::Server::ProxyController) do
      def self.name = "Railwatch::Server::ProxyController"
      private def hand_off(_secret) = render(json: { component: "dashboard/index" })
      private def hijackable? = true
    end
    status, headers, = visit(controller)
    assert_equal 200, status, "inertia_rails answered #{status} (X-Inertia-Location: #{headers['x-inertia-location'].inspect})"
  end

  def test_the_apps_own_pages_still_get_the_version_check
    page = Class.new(ActionController::Base) do
      def self.name = "PagesController"
      def forward = render(json: {})
    end
    status, = visit(page)
    assert_equal 409, status
  end
end
