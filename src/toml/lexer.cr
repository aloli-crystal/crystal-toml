require "./parse_error"
require "./token"

module TOML
  # Streaming lexer for TOML v1.0 documents.
  #
  # Design notes
  # ============
  #
  # * **Trivia is emitted, not skipped.** Whitespace, newlines and
  #   comments are returned as tokens because the AST keeps them
  #   attached to nodes for byte-identical round-trips.
  #
  # * **Atoms are coarse-grained.** Anything that is not a delimiter,
  #   string, or trivia is returned as a single `BareKeyOrAtom`
  #   token whose `raw` is the verbatim source slice. The parser
  #   decides whether it is a bare key, integer, float, datetime,
  #   boolean, `inf`, or `nan` based on context. Two consequences:
  #
  #     * The dot character is *always* emitted as `Dot`. A float
  #       like `1.5` lexes as `Atom("1") Dot Atom("5")`; the parser
  #       reassembles it. This keeps the lexer context-free at the
  #       cost of a tiny bit of parser work.
  #     * The colon `:` is part of an atom (so a time value like
  #       `07:32:00` is a single `Atom`).
  #
  # * **Brackets are always single-character.** `[` and `]` are
  #   emitted one at a time even when adjacent. The parser
  #   disambiguates `[[products]]` (array-of-tables header) from
  #   `[[1, 2]]` (nested array) by position: a line that starts
  #   with two consecutive `LBracket` tokens is an AoT header,
  #   anywhere else they open two arrays.
  #
  # * **Line endings.** `\n` and `\r\n` are both valid newlines. A
  #   bare `\r` not followed by `\n` is *not* a TOML line ending and
  #   triggers a `ParseError` if it appears outside a string.
  class Lexer
    # Characters that may appear inside an atom (bare key OR value
    # atom). `.` is intentionally not in this set; see the design
    # notes on the class.
    private ATOM_CHARS = {
      'A'..'Z',
      'a'..'z',
      '0'..'9',
    }

    @source : String
    @bytes : Bytes
    @pos : Int32
    @line : Int32
    @column : Int32

    def initialize(source : String)
      @source = source
      @bytes = source.to_slice
      @pos = 0
      @line = 1
      @column = 1
    end

    # Returns the next token. Once the end of input is reached,
    # returns an `EOF` token at the current position; subsequent
    # calls keep returning `EOF`.
    def next_token : Token
      return make(TokenKind::EOF, "") if eof?

      start_line = @line
      start_column = @column
      start_pos = @pos
      char = current_byte

      case char
      when ' '.ord, '\t'.ord
        consume_whitespace(start_line, start_column, start_pos)
      when '\n'.ord
        advance_newline
        Token.new(TokenKind::Newline, "\n", start_line, start_column)
      when '\r'.ord
        consume_crlf(start_line, start_column)
      when '#'.ord
        consume_comment(start_line, start_column, start_pos)
      when '='.ord
        advance
        Token.new(TokenKind::Equal, "=", start_line, start_column)
      when '.'.ord
        advance
        Token.new(TokenKind::Dot, ".", start_line, start_column)
      when ','.ord
        advance
        Token.new(TokenKind::Comma, ",", start_line, start_column)
      when '['.ord
        advance
        Token.new(TokenKind::LBracket, "[", start_line, start_column)
      when ']'.ord
        advance
        Token.new(TokenKind::RBracket, "]", start_line, start_column)
      when '{'.ord
        advance
        Token.new(TokenKind::LBrace, "{", start_line, start_column)
      when '}'.ord
        advance
        Token.new(TokenKind::RBrace, "}", start_line, start_column)
      when '"'.ord
        consume_basic_string(start_line, start_column, start_pos)
      when '\''.ord
        consume_literal_string(start_line, start_column, start_pos)
      else
        consume_atom(start_line, start_column, start_pos)
      end
    end

    # Returns true if the lexer has consumed all input.
    def eof? : Bool
      @pos >= @bytes.size
    end

    # ------------------------------------------------------------------
    # Internals
    # ------------------------------------------------------------------

    private def current_byte : UInt8
      @bytes[@pos]
    end

    private def peek_byte(offset : Int32 = 1) : UInt8?
      idx = @pos + offset
      return nil if idx >= @bytes.size
      @bytes[idx]
    end

    private def advance : Nil
      @pos += 1
      @column += 1
    end

    private def advance_newline : Nil
      @pos += 1
      @line += 1
      @column = 1
    end

    private def make(kind : TokenKind, raw : String) : Token
      Token.new(kind, raw, @line, @column)
    end

    private def slice(from : Int32) : String
      String.new(@bytes[from, @pos - from])
    end

    private def error!(message : String, line : Int32 = @line, column : Int32 = @column) : NoReturn
      raise ParseError.new(message, line, column)
    end

    # --- whitespace and newlines -------------------------------------

    private def consume_whitespace(start_line, start_column, start_pos) : Token
      while !eof? && (current_byte == ' '.ord || current_byte == '\t'.ord)
        advance
      end
      Token.new(TokenKind::Whitespace, slice(start_pos), start_line, start_column)
    end

    private def consume_crlf(start_line, start_column) : Token
      # `\r` must be immediately followed by `\n` for a valid line
      # ending. A bare `\r` is rejected.
      if peek_byte == '\n'.ord
        @pos += 2
        @line += 1
        @column = 1
        Token.new(TokenKind::Newline, "\r\n", start_line, start_column)
      else
        error!("bare carriage return is not a valid line ending in TOML", start_line, start_column)
      end
    end

    private def consume_comment(start_line, start_column, start_pos) : Token
      while !eof?
        b = current_byte
        break if b == '\n'.ord || b == '\r'.ord
        # Forbidden control characters in comments per TOML v1.0
        # (allow tab; reject other C0 controls and DEL).
        if (b < 0x20 && b != '\t'.ord) || b == 0x7F
          error!("control character not allowed in comment")
        end
        advance
      end
      Token.new(TokenKind::Comment, slice(start_pos), start_line, start_column)
    end

    # --- strings -----------------------------------------------------

    private def consume_basic_string(start_line, start_column, start_pos) : Token
      # Detect triple-quoted multi-line basic string.
      if peek_byte == '"'.ord && peek_byte(2) == '"'.ord
        consume_multiline_basic_string(start_line, start_column, start_pos)
      else
        consume_single_basic_string(start_line, start_column, start_pos)
      end
    end

    private def consume_single_basic_string(start_line, start_column, start_pos) : Token
      advance # opening "
      until eof?
        b = current_byte
        case b
        when '"'.ord
          advance
          return Token.new(TokenKind::BasicString, slice(start_pos), start_line, start_column)
        when '\n'.ord, '\r'.ord
          error!("unterminated basic string (newline before closing quote)", start_line, start_column)
        when '\\'.ord
          consume_basic_escape(start_line, start_column)
        else
          if b < 0x20 && b != '\t'.ord
            error!("invalid control character in basic string")
          end
          advance
        end
      end
      error!("unterminated basic string (end of input)", start_line, start_column)
    end

    private def consume_basic_escape(string_start_line, string_start_column) : Nil
      escape_line = @line
      escape_column = @column
      advance # the backslash
      error!("dangling backslash in basic string", escape_line, escape_column) if eof?
      esc = current_byte
      case esc
      when '"'.ord, '\\'.ord, 'b'.ord, 'f'.ord, 'n'.ord, 'r'.ord, 't'.ord
        advance
      when 'u'.ord
        advance
        consume_hex_escape(4, escape_line, escape_column)
      when 'U'.ord
        advance
        consume_hex_escape(8, escape_line, escape_column)
      else
        error!("invalid escape sequence \\#{esc.unsafe_chr}", escape_line, escape_column)
      end
    end

    private def consume_hex_escape(digits : Int32, escape_line, escape_column) : Nil
      digits.times do
        if eof? || !hex_digit?(current_byte)
          error!("expected #{digits} hex digits after \\u escape", escape_line, escape_column)
        end
        advance
      end
    end

    private def hex_digit?(b : UInt8) : Bool
      (b >= '0'.ord && b <= '9'.ord) ||
        (b >= 'a'.ord && b <= 'f'.ord) ||
        (b >= 'A'.ord && b <= 'F'.ord)
    end

    private def consume_multiline_basic_string(start_line, start_column, start_pos) : Token
      @pos += 3 # opening """
      @column += 3
      # Skip a single immediately-following newline (TOML spec).
      if !eof? && current_byte == '\n'.ord
        advance_newline
      elsif !eof? && current_byte == '\r'.ord && peek_byte == '\n'.ord
        @pos += 2
        @line += 1
        @column = 1
      end

      until eof?
        b = current_byte
        case b
        when '"'.ord
          # A multi-line basic string ends with three or more
          # quotes, but at most two `"` may appear inside the
          # string before the terminator (e.g. `"""ab""c"""` is
          # `ab""c`). The terminator is the *last* run of three or
          # more `"`. We approximate this by counting the run and
          # closing on the first run of length >= 3, leaving any
          # extra `"` consumed as content of the closer up to 5
          # total (per TOML spec: at most two extra quotes allowed).
          quote_run = count_quote_run
          if quote_run >= 3
            extra = Math.min(quote_run - 3, 2)
            (3 + extra).times { advance }
            return Token.new(TokenKind::MultilineBasicString, slice(start_pos), start_line, start_column)
          end
          quote_run.times { advance }
        when '\\'.ord
          # In multi-line basic strings, `\` followed by whitespace
          # and a newline trims the run. We don't validate that
          # here at the lexer level — we just skip the backslash
          # and let the parser interpret. But we must still
          # validate normal escapes if they're used.
          if line_continuation?
            consume_line_continuation
          else
            consume_basic_escape(start_line, start_column)
          end
        when '\n'.ord
          advance_newline
        when '\r'.ord
          if peek_byte == '\n'.ord
            @pos += 2
            @line += 1
            @column = 1
          else
            error!("bare carriage return inside multi-line basic string")
          end
        else
          if b < 0x20 && b != '\t'.ord
            error!("invalid control character in multi-line basic string")
          end
          advance
        end
      end
      error!("unterminated multi-line basic string", start_line, start_column)
    end

    private def count_quote_run : Int32
      i = 0
      while !eof? && @bytes[@pos + i]? == '"'.ord.to_u8
        i += 1
        break if i >= 5 # cap so we don't read past the buffer
      end
      i
    end

    # Returns true if the current backslash is a line-continuation
    # marker: `\` followed by zero or more spaces/tabs and then a
    # newline.
    private def line_continuation? : Bool
      i = @pos + 1
      while i < @bytes.size && (@bytes[i] == ' '.ord || @bytes[i] == '\t'.ord)
        i += 1
      end
      return false if i >= @bytes.size
      @bytes[i] == '\n'.ord || @bytes[i] == '\r'.ord
    end

    private def consume_line_continuation : Nil
      advance # the backslash
      while !eof? && (current_byte == ' '.ord || current_byte == '\t'.ord)
        advance
      end
      # The newline itself is consumed as part of the trim.
      if !eof? && current_byte == '\n'.ord
        advance_newline
      elsif !eof? && current_byte == '\r'.ord && peek_byte == '\n'.ord
        @pos += 2
        @line += 1
        @column = 1
      end
      # Consume any further whitespace (including newlines) until
      # the next non-whitespace character.
      while !eof?
        b = current_byte
        if b == ' '.ord || b == '\t'.ord
          advance
        elsif b == '\n'.ord
          advance_newline
        elsif b == '\r'.ord && peek_byte == '\n'.ord
          @pos += 2
          @line += 1
          @column = 1
        else
          break
        end
      end
    end

    private def consume_literal_string(start_line, start_column, start_pos) : Token
      if peek_byte == '\''.ord && peek_byte(2) == '\''.ord
        consume_multiline_literal_string(start_line, start_column, start_pos)
      else
        consume_single_literal_string(start_line, start_column, start_pos)
      end
    end

    private def consume_single_literal_string(start_line, start_column, start_pos) : Token
      advance # opening '
      until eof?
        b = current_byte
        case b
        when '\''.ord
          advance
          return Token.new(TokenKind::LiteralString, slice(start_pos), start_line, start_column)
        when '\n'.ord, '\r'.ord
          error!("unterminated literal string (newline before closing quote)", start_line, start_column)
        else
          if b < 0x20 && b != '\t'.ord
            error!("invalid control character in literal string")
          end
          advance
        end
      end
      error!("unterminated literal string (end of input)", start_line, start_column)
    end

    private def consume_multiline_literal_string(start_line, start_column, start_pos) : Token
      @pos += 3 # opening '''
      @column += 3
      if !eof? && current_byte == '\n'.ord
        advance_newline
      elsif !eof? && current_byte == '\r'.ord && peek_byte == '\n'.ord
        @pos += 2
        @line += 1
        @column = 1
      end

      until eof?
        b = current_byte
        case b
        when '\''.ord
          quote_run = count_apostrophe_run
          if quote_run >= 3
            extra = Math.min(quote_run - 3, 2)
            (3 + extra).times { advance }
            return Token.new(TokenKind::MultilineLiteralString, slice(start_pos), start_line, start_column)
          end
          quote_run.times { advance }
        when '\n'.ord
          advance_newline
        when '\r'.ord
          if peek_byte == '\n'.ord
            @pos += 2
            @line += 1
            @column = 1
          else
            error!("bare carriage return inside multi-line literal string")
          end
        else
          if b < 0x20 && b != '\t'.ord
            error!("invalid control character in multi-line literal string")
          end
          advance
        end
      end
      error!("unterminated multi-line literal string", start_line, start_column)
    end

    private def count_apostrophe_run : Int32
      i = 0
      while !eof? && @bytes[@pos + i]? == '\''.ord.to_u8
        i += 1
        break if i >= 5
      end
      i
    end

    # --- atoms (bare keys or value atoms) ----------------------------

    private def consume_atom(start_line, start_column, start_pos) : Token
      while !eof? && atom_char?(current_byte)
        advance
      end
      raw = slice(start_pos)
      if raw.empty?
        # Unrecognised character — bubble up a clear error.
        error!("unexpected character #{current_byte.unsafe_chr.inspect}", start_line, start_column)
      end
      Token.new(TokenKind::BareKeyOrAtom, raw, start_line, start_column)
    end

    private def atom_char?(b : UInt8) : Bool
      (b >= '0'.ord && b <= '9'.ord) ||
        (b >= 'A'.ord && b <= 'Z'.ord) ||
        (b >= 'a'.ord && b <= 'z'.ord) ||
        b == '_'.ord ||
        b == '-'.ord ||
        b == '+'.ord ||
        b == ':'.ord
    end
  end
end
