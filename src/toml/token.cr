module TOML
  # Token kinds emitted by the lexer.
  #
  # The lexer is intentionally fine-grained for structural elements
  # (so the parser does not need to look at characters), and
  # coarse-grained for value atoms (Number, BareKeyOrAtom) — those
  # are disambiguated by the parser based on context (a `1979` after
  # `=` in a key/value pair could be an integer, a float, a date, or
  # part of a datetime; only the parser can decide).
  #
  # Trivia tokens (Whitespace, Newline, Comment) are emitted rather
  # than skipped, because the AST keeps them attached to their nodes
  # for byte-identical round-trips.
  enum TokenKind
    # Trivia.
    Whitespace # one or more spaces or tabs
    Newline    # \n or \r\n
    Comment    # # ...... (without trailing newline)

    # Structural punctuation.
    Equal    # =
    Dot      # . (used inside dotted keys and dotted table headers)
    Comma    # ,
    LBracket # [   (parser disambiguates table vs array-of-tables vs nested array)
    RBracket # ]
    LBrace   # {
    RBrace   # }

    # Strings (delimiters included in the raw text).
    BasicString            # "..."
    MultilineBasicString   # """..."""
    LiteralString          # '...'
    MultilineLiteralString # '''...'''

    # An atom that can be a bare key (a-z A-Z 0-9 _ -) OR a value
    # atom (integer, float, boolean, datetime, inf, nan, true,
    # false). The parser disambiguates by context. We keep the raw
    # text byte-for-byte so the serializer can re-emit it unchanged.
    BareKeyOrAtom

    # End of input.
    EOF
  end

  # A lexed token.
  #
  # `raw` is the verbatim slice of source consumed by this token,
  # including delimiters for strings and including the leading `#`
  # for comments. The serializer can re-emit `raw` as-is to achieve
  # byte-identical round-trips for unmodified documents.
  #
  # `line` and `column` are 1-based and point at the start of the
  # token, useful for error messages.
  struct Token
    getter kind : TokenKind
    getter raw : String
    getter line : Int32
    getter column : Int32

    def initialize(@kind : TokenKind, @raw : String, @line : Int32, @column : Int32)
    end

    def to_s(io : IO) : Nil
      io << "Token(" << @kind << ", "
      @raw.inspect(io)
      io << " @ " << @line << ":" << @column << ")"
    end
  end
end
