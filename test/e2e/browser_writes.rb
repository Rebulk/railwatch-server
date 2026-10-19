# Writes through the /railwatch proxy the way the dashboard's Inertia client
# makes them: the XSRF-TOKEN cookie the server set, echoed in X-XSRF-TOKEN,
# with Origin and X-Inertia, behind the app's HTTP Basic gate. Each write is
# read back; the same write without the token must be refused.
#
#   ruby test/e2e/browser_writes.rb http://127.0.0.1:3000 admin password
require "net/http"
require "json"
require "uri"

BASE = URI(ARGV[0] || "http://127.0.0.1:3000")
USER, PASS = ARGV[1] || "admin", ARGV[2] || "s3cret-dashboard"

class Browser
  def initialize
    @jar = {}
    @http = Net::HTTP.start(BASE.host, BASE.port)
  end

  def get(path, inertia: false) = request(Net::HTTP::Get.new(path), inertia: inertia)

  def write(verb, path, params, token: true)
    req = Net::HTTP.const_get(verb.capitalize).new(path)
    req["Content-Type"] = "application/json"
    req["X-XSRF-TOKEN"] = URI.decode_www_form_component(@jar["XSRF-TOKEN"]) if token
    req.body = JSON.generate(params)
    request(req, inertia: true)
  end

  def page(path) = JSON.parse(get(path, inertia: true).body)

  private

  def request(req, inertia:)
    req.basic_auth(USER, PASS)
    req["Origin"] = "#{BASE.scheme}://#{BASE.host}:#{BASE.port}"
    req["Cookie"] = @jar.map { |k, v| "#{k}=#{v}" }.join("; ") if @jar.any?
    if inertia
      req["X-Inertia"] = "true"
      req["X-Requested-With"] = "XMLHttpRequest"
      req["X-Inertia-Version"] = @version if @version
    end
    res = @http.request(req)
    Array(res.get_fields("set-cookie")).each { |c| k, v = c.split(";").first.split("=", 2); @jar[k] = v }
    if (data = res.body.to_s[%r{<script data-page="app" type="application/json">(.*?)</script>}m, 1])
      @version ||= JSON.parse(data)["version"]
    end
    res = @http.request(Net::HTTP::Get.new(res["location"]).tap { |r| r.basic_auth(USER, PASS); r["Cookie"] = @jar.map { |k, v| "#{k}=#{v}" }.join("; "); r["X-Inertia"] = "true"; r["X-Inertia-Version"] = @version if @version }) if res.is_a?(Net::HTTPRedirection) && inertia
    res
  end
end

def check(name, ok)
  puts "#{ok ? 'ok  ' : 'FAIL'} #{name}"
  $failed = true unless ok
end

b = Browser.new
b.get("/railwatch/dashboard")
check("dashboard sets XSRF-TOKEN under /railwatch", !b.instance_variable_get(:@jar)["XSRF-TOKEN"].to_s.empty?)
dash = b.page("/railwatch/dashboard")
env = dash["props"]["applications"].first["environments"].first rescue nil
app_id = dash["props"]["applications"].first["id"]
env_id = env && env["id"]
issue = b.page("/railwatch/issues")["props"]["issues"].first

refused = b.write("post", "/railwatch/issues/#{issue['id']}/comments", { body: "no token" }, token: false)
check("a write without the XSRF token is refused (#{refused.code})", refused.code == "422")

b.write("post", "/railwatch/issues/#{issue['id']}/comments", { body: "through the proxy" })
b.write("patch", "/railwatch/issues/#{issue["id"]}", { action_name: "resolve" })
shown = b.page("/railwatch/issues/#{issue['id']}")["props"]
check("issue comment stored", shown.to_s.include?("through the proxy"))
check("issue resolved", shown["issue"]["status"] == "resolved")

b.write("post", "/railwatch/apps/#{app_id}/envs/#{env_id}/saved_views", { name: "Widgets via proxy", page: "requests", query: "route:/widgets" })
views = b.page("/railwatch/apps/#{app_id}/envs/#{env_id}/requests")["props"]["saved_views"]
check("saved view created", views.any? { |v| v["name"] == "Widgets via proxy" })

b.write("patch", "/railwatch/settings/profile", { name: "Proxy Admin", editor: "zed", weekly_digest: false })
profile = b.page("/railwatch/settings/profile")["props"]
check("profile setting changed", profile["auth"]["user"]["name"] == "Proxy Admin" && profile["auth"]["user"]["editor"] == "zed")

exit($failed ? 1 : 0)
