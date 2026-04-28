require "./toml/version"
require "./toml/parse_error"
require "./toml/token"
require "./toml/lexer"
require "./toml/key"
require "./toml/value"
require "./toml/node"
require "./toml/value_decoder"
require "./toml/parser"

# TOML v1.0 parser and serializer for Crystal, with comment-and-format
# preservation across parse → modify → write round-trips.
#
# Two entry points are exposed:
#
# * `TOML.parse_to_hash(string)` — drop-in replacement for the
#   `crystal-community/TOML.cr` API. Returns a plain `Hash`, fast,
#   loses every comment and the original formatting. Use this when
#   you only ever read.
#
# * `TOML.parse(string)` — returns a `TOML::Document` AST that
#   preserves comments, blank lines, and the original byte-level
#   formatting. Use this when you need to modify a TOML file in
#   place and re-serialize it without diffing the whole document.
#
# See `CRYSTAL-TOML-SPECS.adoc` (sibling repo `prod-crystal/`) for
# the full specification.
module TOML
  # Parses a TOML v1.0 document into a `Document` AST. The
  # returned document preserves comments, blank lines, key order
  # and the original byte-level formatting, so a round-trip
  # `TOML.parse(s).to_toml == s` for any unmodified `s`.
  #
  # Raises `TOML::ParseError` on invalid input.
  def self.parse(source : String) : Document
    Parser.new(source).parse
  end
end
