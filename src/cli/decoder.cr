# Decoder binary for the official `toml-lang/toml-test` interop suite.
#
# Reads a TOML document on STDIN, parses it, and writes the
# normalised JSON representation expected by the test harness on
# STDOUT. Exits 0 on success, 1 on any parse error (the harness
# uses the exit code to discriminate the `valid/` and `invalid/`
# fixtures).

require "../toml"
require "../toml/test_format"

# Court-circuit AVANT lecture STDIN pour les flags méta. Sans ça, un
# `toml-decoder --help` resterait bloqué à attendre STDIN.
USAGE = <<-USAGE
  Usage : toml-decoder < FICHIER.toml > FICHIER.json

  Decoder TOML → JSON conforme à la suite de tests interop
  https://github.com/toml-lang/toml-test[toml-lang/toml-test].
  Le binaire est un FILTRE : il lit le document TOML sur STDIN,
  sort le JSON normalisé sur STDOUT (format BurntSushi). Exit
  code 0 = parse réussi ; exit code 1 = parse échoué (l'erreur
  est sur STDERR).

  Exemples :
    toml-decoder < config.toml
    toml-decoder < config.toml > config.json
    cat config.toml | toml-decoder | jq

  Options :
    -h, --help        Affiche cette aide et quitte
    -v, --version     Affiche la version et quitte
  USAGE

if ARGV.includes?("-h") || ARGV.includes?("--help") || ARGV.first? == "help"
  puts USAGE
  exit 0
end
if ARGV.includes?("-v") || ARGV.includes?("--version")
  puts "toml-decoder #{TOML::VERSION}"
  exit 0
end

input = STDIN.gets_to_end

begin
  doc = TOML.parse(input)
  STDOUT.puts TOML::TestFormat.encode(doc)
rescue ex : TOML::ParseError
  STDERR.puts ex.message
  exit 1
end
