# Decoder binary for the official `toml-lang/toml-test` interop suite.
#
# Reads a TOML document on STDIN, parses it, and writes the
# normalised JSON representation expected by the test harness on
# STDOUT. Exits 0 on success, 1 on any parse error (the harness
# uses the exit code to discriminate the `valid/` and `invalid/`
# fixtures).

require "../crystal-toml"
require "../toml/test_format"

input = STDIN.gets_to_end

begin
  doc = TOML.parse(input)
  STDOUT.puts TOML::TestFormat.encode(doc)
rescue ex : TOML::ParseError
  STDERR.puts ex.message
  exit 1
end
