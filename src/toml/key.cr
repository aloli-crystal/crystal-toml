module TOML
  # One segment of a TOML key. A bare key (`server`), a quoted key
  # (`"127.0.0.1"`) or a literal-quoted key (`'a.b.c'`) all become
  # one `KeyPart`.
  #
  # `raw` is the verbatim source slice (including quotes if any).
  # `decoded` is the logical key string used for lookups.
  struct KeyPart
    getter raw : String
    getter decoded : String

    def initialize(@raw : String, @decoded : String)
    end
  end

  # A possibly-dotted key, e.g. `physical.shape` or `"a"."b".c`.
  # Stored as the ordered list of its parts plus the verbatim raw
  # source text (including any whitespace around the dots), so the
  # serializer can re-emit the key byte-for-byte.
  class Key
    getter parts : Array(KeyPart)
    getter raw : String

    def initialize(@parts : Array(KeyPart), @raw : String)
    end

    # The logical path of this key as an `Array(String)` (decoded).
    def path : Array(String)
      @parts.map(&.decoded)
    end

    # Convenience: shorthand for `path.join('.')`. Useful for error
    # messages but not for storage — TOML keys with dots in them are
    # legal and would round-trip incorrectly through this method.
    def to_s(io : IO) : Nil
      io << @raw
    end
  end
end
