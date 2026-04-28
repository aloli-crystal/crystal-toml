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
    # Stack of active capture builders. Every token consumed while
    # at least one capture is active is appended to *all* of them,
    # so a nested capture (e.g. an array inside an array) feeds
    # both its own buffer and its enclosing one. Used to assemble
    # the byte-identical `raw` of arrays and inline tables.
    @captures : Array(String::Builder)

    def initialize(@source : String)
      @lexer = Lexer.new(@source)
      @lookahead = Deque(Token).new
      @captures = [] of String::Builder
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
        when TokenKind::LBracket
          if peek(1).kind.l_bracket?
            nodes << parse_array_of_tables_header(leading_ws)
          else
            nodes << parse_table_header(leading_ws)
          end
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
      consume_expect(TokenKind::LBracket, "expected '[' (first of '[[')")
      consume_expect(TokenKind::LBracket, "expected '[' (second of '[[')")
      inner_prefix = consume_whitespace_run
      key = parse_key
      inner_suffix = consume_whitespace_run
      consume_expect(TokenKind::RBracket, "expected ']' (first of ']]')")
      consume_expect(TokenKind::RBracket, "expected ']' (second of ']]')")
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
      case peek.kind
      when .l_bracket?
        parse_array
      when .l_brace?
        parse_inline_table
      else
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
    end

    # ------------------------------------------------------------------
    # Arrays
    # ------------------------------------------------------------------

    # `[ value, value, ... ]`. Items may be separated by any
    # combination of whitespace, newlines and comments, and a
    # trailing comma is allowed. Items keep their own raw text
    # (preserved inside `ArrayValue#raw` for byte-identical
    # round-trips); the trivia between items is preserved only as
    # part of the array's own `raw`, not on the items.
    private def parse_array : ArrayValue
      items = [] of Value
      raw = with_capture do
        consume_expect(TokenKind::LBracket, "expected '[' to open array")

        loop do
          consume_array_trivia
          break if peek.kind.r_bracket?
          items << parse_value
          consume_array_trivia
          if peek.kind.comma?
            consume
          elsif !peek.kind.r_bracket?
            error!(peek, "expected ',' or ']' in array, got #{peek.kind}")
          end
        end
        consume_expect(TokenKind::RBracket, "expected ']' to close array")
      end
      ArrayValue.new(raw, items)
    end

    # Whitespace, newlines and comments are all allowed (and
    # ignored as content) between array items.
    private def consume_array_trivia : Nil
      loop do
        case peek.kind
        when .whitespace?, .newline?, .comment?
          consume
        else
          return
        end
      end
    end

    # ------------------------------------------------------------------
    # Inline tables
    # ------------------------------------------------------------------

    # `{ key = value, key = value }`. Strict TOML 1.0 form: no
    # newlines inside, comma-separated, no trailing comma. An
    # empty inline table `{}` is legal.
    private def parse_inline_table : InlineTableValue
      pairs = [] of {Array(String), Value}
      raw = with_capture do
        consume_expect(TokenKind::LBrace, "expected '{' to open inline table")
        consume_inline_trivia
        unless peek.kind.r_brace?
          loop do
            key = parse_key
            consume_inline_trivia
            consume_expect(TokenKind::Equal, "expected '=' in inline table")
            consume_inline_trivia
            value = parse_value
            pairs << {key.path, value}
            consume_inline_trivia
            if peek.kind.comma?
              consume
              consume_inline_trivia
              if peek.kind.r_brace?
                error!(peek, "trailing comma not allowed in inline table")
              end
            else
              break
            end
          end
        end
        consume_expect(TokenKind::RBrace, "expected '}' to close inline table")
      end
      InlineTableValue.new(raw, pairs)
    end

    # Inline tables are strictly single-line: only spaces/tabs may
    # appear between elements (no newlines, no comments).
    private def consume_inline_trivia : Nil
      while peek.kind.whitespace?
        consume
      end
    end

    private def consume_expect(kind : TokenKind, message : String) : Token
      tok = consume
      unless tok.kind == kind
        error!(tok, message)
      end
      tok
    end

    # The lexer emits values that may span multiple tokens because
    # the dot character is always returned as its own `Dot`, and
    # because TOML allows a *space* as the date/time delimiter
    # (which the lexer treats as `Whitespace`). This method
    # reassembles every multi-token value form:
    #
    # * `1.5` arrives as `Atom("1") Dot Atom("5")` → float.
    # * `1979-05-27T07:32:00.999-07:00` arrives as
    #   `Atom("1979-05-27T07:32:00") Dot Atom("999-07:00")` →
    #   fractional offset datetime.
    # * `1979-05-27 07:32:00` arrives as
    #   `Atom("1979-05-27") Whitespace(" ") Atom("07:32:00")` →
    #   local datetime with space delimiter.
    # * `1979-05-27` and `07:32:00` arrive as a single atom →
    #   local date or local time.
    # * `42`, `0xDEAD`, `inf`, `true` arrive as a single atom →
    #   integer / boolean / special float.
    private def parse_atom_or_float(first : Token) : Value
      # Date + space + time form (TOML allows space as the date/time
      # delimiter on top of `T`/`t`).
      if first.raw.size == 10 && local_date_shape?(first.raw) &&
         peek.kind.whitespace? && peek.raw == " " &&
         peek(1).kind.bare_key_or_atom? && local_time_shape?(peek(1).raw)
        ws = consume
        time_tok = consume
        combined = first.raw + ws.raw + time_tok.raw
        if peek.kind.dot?
          consume
          next_tok = consume
          unless next_tok.kind.bare_key_or_atom?
            error!(next_tok, "expected fractional second after '.'")
          end
          combined = combined + "." + next_tok.raw
        end
        if dt = ValueDecoder.try_decode_datetime(combined)
          return dt
        end
        error!(first, "invalid datetime #{combined.inspect}")
      end

      if peek.kind.dot?
        # Atom-Dot-Atom form: could be a fractional datetime or a
        # float. Try datetime first because a value like
        # "1979-05-27T07:32:00" doesn't parse as a float.
        consume # the Dot
        next_tok = consume
        unless next_tok.kind.bare_key_or_atom?
          error!(next_tok, "expected value after '.'")
        end
        combined = first.raw + "." + next_tok.raw
        if dt = ValueDecoder.try_decode_datetime(combined)
          return dt
        end
        if f = ValueDecoder.decode_float(combined)
          return f
        end
        error!(first, "invalid value #{combined.inspect}")
      end

      # Single-atom form: try datetime (LocalDate / LocalTime /
      # LocalDateTime / OffsetDateTime without fraction), then the
      # plain atom decoders.
      if dt = ValueDecoder.try_decode_datetime(first.raw)
        return dt
      end
      if v = ValueDecoder.try_decode_atom(first.raw)
        return v
      end
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
      tok = @lookahead.empty? ? @lexer.next_token : @lookahead.shift
      @captures.each &.<< tok.raw
      tok
    end

    # Run *block* with a fresh capture buffer pushed onto the
    # stack; returns the captured string. Used by array and
    # inline-table parsers to obtain the byte-exact source slice
    # they consumed.
    private def with_capture(& : -> _) : String
      builder = String::Builder.new
      @captures << builder
      begin
        yield
      ensure
        @captures.pop
      end
      builder.to_s
    end

    private def error!(tok : Token, message : String) : NoReturn
      raise ParseError.new(message, tok.line, tok.column)
    end

    # Does `s` syntactically look like a `yyyy-mm-dd` local date?
    # Used purely as a fast filter for the date+space+time form;
    # full validation happens in `ValueDecoder.try_decode_datetime`.
    private def local_date_shape?(s : String) : Bool
      return false unless s.size == 10
      bytes = s.to_slice
      bytes[4] == '-'.ord && bytes[7] == '-'.ord &&
        ascii_digit?(bytes[0]) && ascii_digit?(bytes[1]) &&
        ascii_digit?(bytes[2]) && ascii_digit?(bytes[3]) &&
        ascii_digit?(bytes[5]) && ascii_digit?(bytes[6]) &&
        ascii_digit?(bytes[8]) && ascii_digit?(bytes[9])
    end

    # Does `s` syntactically *start* like a `hh:mm:ss` local time?
    # The atom may carry a trailing offset (`Z`, `+07:00`) which we
    # do not validate here.
    private def local_time_shape?(s : String) : Bool
      return false if s.size < 8
      bytes = s.to_slice
      bytes[2] == ':'.ord && bytes[5] == ':'.ord &&
        ascii_digit?(bytes[0]) && ascii_digit?(bytes[1]) &&
        ascii_digit?(bytes[3]) && ascii_digit?(bytes[4]) &&
        ascii_digit?(bytes[6]) && ascii_digit?(bytes[7])
    end

    private def ascii_digit?(b : UInt8) : Bool
      b >= '0'.ord && b <= '9'.ord
    end
  end
end
