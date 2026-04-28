# Example 01 — Simple read with `TOML.parse_to_hash`
# ==================================================
#
# The drop-in API for `crystal-community/TOML.cr`. Returns a flat
# `Hash(String, TOML::Type)`. Comments and the original formatting
# are discarded — use this when you only ever read.
#
# Run it with:
#
#     crystal run examples/01_simple_read.cr

require "../src/crystal-toml"

source = <<-TOML
  # Application configuration
  title = "Example app"
  port  = 8080
  debug = false

  [database]
  host     = "db.example.com"
  port     = 5432
  pool     = 16
  timeout  = 30.5

  [[features]]
  name    = "billing"
  enabled = true

  [[features]]
  name    = "reporting"
  enabled = false
  TOML

config = TOML.parse_to_hash(source)

puts "Title : #{config["title"]}"
puts "Port  : #{config["port"]}"
puts "Debug : #{config["debug"]}"

db = config["database"].as(Hash(String, TOML::Type))
puts "DB host : #{db["host"]} port=#{db["port"]} (timeout=#{db["timeout"]}s)"

features = config["features"].as(Array(TOML::Type))
features.each_with_index do |feature, i|
  f = feature.as(Hash(String, TOML::Type))
  puts "Feature #{i}: #{f["name"]} (enabled=#{f["enabled"]})"
end
