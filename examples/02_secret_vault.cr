# Example 02 — Editing a secret vault while keeping comments
# ===========================================================
#
# This is the use case `toml` was originally built for :
# storing secrets in a TOML file annotated with rotation comments,
# editing one secret programmatically (e.g. after a rotation), and
# writing the file back without losing the surrounding annotations.
#
# Run it with:
#
#     crystal run examples/02_secret_vault.cr

require "../src/toml"

# Fictitious vault — in real life this would be the decrypted
# contents of an `age`-encrypted file managed by `crystal-secrets`.
vault_source = <<-TOML
  # Production secrets vault
  # Recipients : philippe@aloli.fr
  # Last rotated : 2026-01-15

  DATABASE_URL = "postgres://prod-db.aloli.fr/aloli"
  REDIS_URL    = "redis://prod-redis.aloli.fr:6379"

  # Stripe — rotate every 90 days
  STRIPE_KEY     = "sk_live_old_value"     # rotated 2026-01-15
  STRIPE_WEBHOOK = "whsec_old_value"

  [smtp]
  host     = "smtp.example.com"
  user     = "noreply@aloli.fr"
  password = "smtp_old_password"
  TOML

doc = TOML.parse(vault_source)

# Read a secret with a typed accessor.
puts "Current Stripe key : #{doc.string("STRIPE_KEY")}"

# Rotate two secrets. The trailing comment is updated automatically;
# every other byte of the file remains unchanged.
doc.set_with_comment("STRIPE_KEY", "sk_live_new_value", "rotated 2026-04-28")
doc.set_with_comment("STRIPE_WEBHOOK", "whsec_new_value", "rotated 2026-04-28")

# Drop a no-longer-used secret.
doc.delete("REDIS_URL")

# Add a brand new top-level secret. The new line is inserted at the
# end of the top-level KV block, before the first `[section]`.
doc.set("SENTRY_DSN", "https://abc@sentry.io/42")

puts ""
puts "─── Updated vault ───"
puts doc.to_toml

# What's preserved byte-for-byte:
#  - The two leading comments (banner)
#  - The blank lines
#  - The "# Stripe — rotate every 90 days" comment
#  - The [smtp] section and all its KVs
#
# What changed:
#  - STRIPE_KEY and STRIPE_WEBHOOK values
#  - Their trailing # comments (set via set_with_comment)
#  - REDIS_URL line removed
#  - SENTRY_DSN line added
