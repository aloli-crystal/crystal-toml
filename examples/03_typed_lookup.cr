# Example 03 — Typed lookups by dotted path
# ==========================================
#
# Once a document is parsed, `Document` exposes typed accessors
# for every TOML scalar. Each accessor has two flavours :
#
#  * `#TYPE?(path)` returns nil if missing or wrong type
#  * `#TYPE(path)`  raises KeyError / TypeCastError
#
# Use the `?`-form for optional config values and the raising
# form for required ones — the type system makes the contract
# explicit.
#
# Run it with:
#
#     crystal run examples/03_typed_lookup.cr

require "../src/toml"

source = <<-TOML
  app_name = "Aloli"

  [server]
  host = "0.0.0.0"
  port = 8080

  [server.tls]
  cert = "/etc/aloli/cert.pem"
  key  = "/etc/aloli/key.pem"

  [scheduler]
  next_run = 2026-04-29T03:00:00+02:00
  retry_in = 00:30:00
  enabled  = true
  TOML

doc = TOML.parse(source)

# Required values — fail loudly if missing or wrong type.
app_name = doc.string("app_name")
host = doc.string("server.host")
port = doc.int("server.port")
puts "Starting #{app_name} on #{host}:#{port}"

# Optional values — `nil` if absent.
admin_email = doc.string?("admin.email") || "noreply@aloli.fr"
puts "Admin contact : #{admin_email}"

# Type checks are part of the contract: a TOML int is rejected
# as a string.
debug = doc.bool?("server.debug") || false
puts "Debug mode : #{debug}"

# Datetime accessor returns a Crystal `Time` for any of the
# RFC 3339 forms. The offset is preserved.
next_run = doc.datetime("scheduler.next_run")
puts "Next run  : #{next_run} (offset #{next_run.offset // 3600}h)"

# Local time → `Time::Span` from midnight.
retry_in = doc.time_of_day("scheduler.retry_in")
puts "Retry in  : #{retry_in.total_minutes.to_i} minutes"

# Membership tests via dotted path.
{"server.tls.cert", "server.tls.ca", "scheduler.enabled"}.each do |path|
  puts "  #{path} present? #{doc.has_key?(path)}"
end

# Exception examples (uncomment to see them in action) :
#   doc.string("missing.path")    # raises KeyError
#   doc.int("server.host")        # raises TypeCastError
