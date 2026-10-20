# An image build must not provision the data dir.
#
# Runs what a Rails Dockerfile runs, `SECRET_KEY_BASE_DUMMY=1 bin/rails
# assets:precompile` in production, against an app with railwatch-server in
# its Gemfile (default /var/tmp/rws-fresh), with the data dir in a temp
# directory. Before the fix the gem's initializer ran `railwatch setup` there,
# so the ingest token, the proxy secret, secret_key_base and control.sqlite3
# landed in an image layer and every volume made from it shared them.
#
#   ruby test/e2e/precompile.rb [/path/to/app]
require "tmpdir"
require "fileutils"
require "open3"

APP = File.expand_path(ARGV[0] || "/var/tmp/rws-fresh")

def check(name, ok, detail = nil)
  puts "#{ok ? 'ok  ' : 'FAIL'} #{name}#{" (#{detail})" if detail}"
  $failed = true unless ok
end

data = File.join(Dir.mktmpdir("rws-precompile-", "/var/tmp"), "storage/railwatch/production")
env = { "RAILS_ENV" => "production", "SECRET_KEY_BASE_DUMMY" => "1", "RAILWATCH_SERVER_DATA_DIR" => data, "RAILWATCH_SERVER_ENABLED" => nil }
out, status = Open3.capture2e(env, "bin/rails", "assets:precompile", chdir: APP)
check("assets:precompile succeeds", status.success?, out.lines.last(3).join.strip)
check("nothing written under storage/railwatch", !File.exist?(File.dirname(data)), Dir.glob("#{data}/**/*").map { File.basename(_1) }.join(" "))
check("and it says nothing about the server", !out.include?("[railwatch-server]"), out[/^.*\[railwatch-server\].*$/])
FileUtils.rm_rf(File.dirname(data, 3))
FileUtils.rm_rf(File.join(APP, "public/assets"))
exit($failed ? 1 : 0)
