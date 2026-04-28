require "./parse_error"
require "./token"
require "./lexer"
require "./key"
require "./value"
require "./value_decoder"
require "./node"

module TOML
  # Parses a TOML v1.0 document into a `Document` AST.
  #
  # The parser is a thin layer over `Lexer`: it consumes the token
  # stream, builds AST nodes, and decodes value text through
  # `ValueDecoder`. Trivia tokens (`Whitespace`, `Newline`,
  # `Comment`) are *not* skipped — they are folded into the
  # surrounding node's `raw_*` fields so that `Document#to_toml`
  # produces byte-identical output for unmodified documents.
  #
  # Scope of the current MVP
  # ========================
  #
  # Implemented:
  #
  # * Top-level `key = value` lines
  # * `[a.b.c]` standard table headers
  # * `[[a.b]]` array-of-tables headers
  # * Bare keys, quoted keys (basic and literal), dotted keys
  # * Values: strings (basic, multi-line basic, literal,
  #   multi-line literal), integers (decimal, hex, octal, binary,
  #   with optional sign and `_` digit separators), floats
  #   (including `inf` and `nan`), booleans
  # * Standalone comment lines and blank lines
  #
  # Not yet implemented (planned for the next iteration):
  #
  # * Datetimes (RFC 3339 offset, local datetime, local date,
  #   local time)
  # * Arrays `[1, 2, 3]`
  # * Inline tables `{ key = "val" }`
  # * Validation that the same key is not redefined and that an
  #   already-defined inline table is not extended later
  class Parser
    @source : String
    @lexer : Lexer
    @lookahead : Deque(Token)

    def initialize(@source : String)
      @lexer = Lexer.new(@source)
      @lookahead = Deque(Token).new
    end

    def parse : Document
      nodes = [] of Node
      trailing = String::Builder.new
      collected_eof_trivia = false

      loop do
        # Capture leading whitespace (spaces/tabs only) — it is
        # part of the next semantic line.
        leading_ws = consume_whitespace_run

        case peek.kind
        when TokenKind::EOF
          # Anything captured as `leading_ws` above belongs to
          # the document trailing trivia.
          trailing << leading_ws
          collected_eof_trivia = true
          break
        when TokenKind::Newline
          tok = consume
          nodes << BlankLine.new(leading_ws + tok.raw)
        when TokenKind::Comment
          tok = consume
          term = consume_line_terminator
          nodes << CommentLine.new(leading_ws + tok.raw + term)
        when TokenKind::LDoubleBracket
          nodes << parse_array_of_tables_header(leading_ws)
        when TokenKind::LBracket
          nodes << parse_table_header(leading_ws)
        else
          nodes << parse_key_value_line(leading_ws)
        end
      end

      Document.new(nodes, collected_eof_trivia ? trailing.to_s : "")
    end

    # ------------------------------------------------------------------
    # Top-level lines
    # ------------------------------------------------------------------

    private def parse_key_value_line(leading_ws : String) : KeyValueLine
      key = parse_key
      eq_prefix = consume_whitespace_run
      tok = consume
      unless tok.kind.equal?
        error!(tok, "expected '=' after key")
      end
      eq_suffix = consume_whitespace_run
      value = parse_value
      trailing = consume_trailing_raw
      KeyValueLine.new(leading_ws, key, eq_prefix, eq_suffix, value, trailing)
    end

    private def parse_table_header(leading_ws : String) : TableHeaderLine
      consume # the [
      inner_prefix = consume_whitespace_run
      key = parse_key
      inner_suffix = consume_whitespace_run
      tok = consume
      unless tok.kind.r_bracket?
        error!(tok, "expected ']' to close table header")
      end
      trailing = consume_trailing_raw
      TableHeaderLine.new(leading_ws, key, inner_prefix, inner_suffix, trailing)
    end

    private def parse_array_of_tables_header(leading_ws : String) : ArrayOfTablesLine
      consume # the [[
      inner_prefix = consume_whitespace_run
      key = parse_key
      inner_suffix = consume_whitespace_run
      tok = consume
      unless tok.kind.r_double_bracket?
        error!(tok, "expected ']]' to close array-of-tables header")
      end
      trailing = consume_trailing_raw
      ArrayOfTablesLine.new(leading_ws, key, inner_prefix, inner_suffix, trailing)
    end

    # ------------------------------------------------------------------
    # Keys
    # ------------------------------------------------------------------

    private def parse_key : Key
      raw_builder = String::Builder.new
      parts = [] of KeyPart
      part = parse_key_part(raw_builder)
      parts << part

      loop do
        # A dot may legitimately have whitespace around it.
        # Look past optional whitespace without committing to it
        # until we confirm a dot follows.
        next_pos = peek.kind.whitespace? ? 1 : 0
        break unless peek(next_pos).kind.dot?

        if next_pos == 1
          raw_builder << consume.raw # the whitespace
        end
        raw_builder << consume.raw # the dot
        if peek.kind.whitespace?
          raw_builder << consume.raw
        end
        parts << parse_key_part(raw_builder)
      end

      Key.new(parts, raw_builder.to_s)
    end

    private def parse_key_part(raw : String::Builder) : KeyPart
      tok = consume
      case tok.kind
      when .bare_key_or_atom?
        validate_bare_key(tok)
        raw << tok.raw
        KeyPart.new(tok.raw, tok.raw)
      when .basic_string?
        decoded = ValueDecoder.decode_basic_string(tok.raw, tok.line, tok.column).decoded
        raw << tok.raw
        KeyPart.new(tok.raw, decoded)
      when .literal_string?
        decoded = ValueDecoder.decode_literal_string(tok.raw, tok.line, tok.column).decoded
        raw << tok.raw
        KeyPart.new(tok.raw, decoded)
      else
        error!(tok, "expected a key (bare, quoted or literal-quoted)")
      end
    end

    # Bare keys may only contain A-Z a-z 0-9 _ and -.
    private def validate_bare_key(tok : Token) : Nil
      tok.raw.each_byte do |b|
        ok = (b >= 'A'.ord && b <= 'Z'.ord) ||
             (b >= 'a'.ord && b <= 'z'.ord) ||
             (b >= '0'.ord && b <= '9'.ord) ||
             b == '_'.ord || b == '-'.ord
        unless ok
          error!(tok, "invalid character #{b.unsafe_chr.inspect} in bare key")
        end
      end
    end

    # ------------------------------------------------------------------
    # Values
    # ------------------------------------------------------------------

    private def parse_value : Value
      tok = consume
      case tok.kind
      when .basic_string?
        ValueDecoder.decode_basic_string(tok.raw, tok.line, tok.column)
      when .multiline_basic_string?
        ValueDecoder.decode_multiline_basic_string(tok.raw, tok.line, tok.column)
      when .literal_string?
        ValueDecoder.decode_literal_string(tok.raw, tok.line, tok.column)
      when .multiline_literal_string?
        ValueDecoder.decode_multiline_literal_string(tok.raw, tok.line, tok.column)
      when .bare_key_or_atom?
        parse_atom_or_float(tok)
      else
        error!(tok, "expected a value")
      end
    end

    # The lexer emits a float `1.5` as `Atom("1") Dot Atom("5")`.
    # Reassemble here when we see a Dot following the first atom.
    private def parse_atom_or_float(first : Token) : Value
      if peek.kind.dot?
        # Could be a float literal like `3.14` or `1e2.something`.
        # Concatenate first.raw + "." + next atom into one string
        # and try to parse as Float64.
        consume # the Dot
        next_tok = consume
        unless next_tok.kind.bare_key_or_atom?
          error!(next_tok, "expected fractional part after '.'")
        end
        raw = first.raw + "." + next_tok.raw
        decoded = ValueDecoder.decode_float(raw)
        return decoded if decoded
        error!(first, "invalid float literal #{raw.inspect}")
      end

      decoded = ValueDecoder.try_decode_atom(first.raw)
      return decoded if decoded
      error!(first, "unrecognised value #{first.raw.inspect}")
    end

    # ------------------------------------------------------------------
    # Trailing trivia helpers
    # ------------------------------------------------------------------

    # Everything from after a value/header until (and including)
    # the line terminator: optional whitespace, optional `# comment`,
    # then a newline (or EOF). Anything else is a syntax error.
    private def consume_trailing_raw : String
      io = String::Builder.new
      ws = consume_whitespace_run
      io << ws

      if peek.kind.comment?
        io << consume.raw
      end

      io << consume_line_terminator
      io.to_s
    end

    # Consumes a single Newline token if present and returns its
    # raw text. Returns "" at EOF.
    private def consume_line_terminator : String
      case peek.kind
      when .newline?
        consume.raw
      when .eof?
        ""
      else
        error!(peek, "expected newline or end of input, got #{peek.kind}")
      end
    end

    private def consume_whitespace_run : String
      io = String::Builder.new
      while peek.kind.whitespace?
        io << consume.raw
      end
      io.to_s
    end

    # ------------------------------------------------------------------
    # Token stream plumbing
    # ------------------------------------------------------------------

    # Returns the token at `offset` ahead in the stream without
    # consuming it. `peek` (offset 0) is the next token.
    private def peek(offset : Int32 = 0) : Token
      while @lookahead.size <= offset
        @lookahead << @lexer.next_token
      end
      @lookahead[offset]
    end

    private def consume : Token
      @lookahead.empty? ? @lexer.next_token : @lookahead.shift
    end

    private def error!(tok : Token, message : String) : NoReturn
      raise ParseError.new(message, tok.line, tok.column)
    end
  end
end
