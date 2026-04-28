require "./parse_error"
require "./value"

module TOML
  # Decoders that turn raw atom/string text into typed `Value`s.
  #
  # Kept in a dedicated module so the parser stays focused on
  # structural concerns. All decoders raise `TOML::ParseError` (with
  # 1-based line/column) on invalid input.
  module ValueDecoder
    extend self

    # ------------------------------------------------------------------
    # Strings
    # ------------------------------------------------------------------

    # Decodes a `BasicString` token (raw still includes the
    # surrounding `"` quotes) into a `StringValue`.
    def decode_basic_string(raw : String, line : Int32, column : Int32) : StringValue
      body = raw[1..-2]
      decoded = decode_basic_escapes(body, line, column)
      StringValue.new(raw, StringValue::Kind::Basic, decoded)
    end

    def decode_multiline_basic_string(raw : String, line : Int32, column : Int32) : StringValue
      # Strip the """...""" delimiters. The closing run may be 3, 4
      # or 5 quotes; the opening is always 3.
      inner = raw[3...(raw.size - closing_quote_run(raw, '"'))]
      # Per spec, a single immediate newline after the opener is
      # trimmed.
      inner = strip_first_newline(inner)
      decoded = decode_basic_escapes(inner, line, column, multiline: true)
      StringValue.new(raw, StringValue::Kind::MultilineBasic, decoded)
    end

    def decode_literal_string(raw : String, _line : Int32, _column : Int32) : StringValue
      StringValue.new(raw, StringValue::Kind::Literal, raw[1..-2])
    end

    def decode_multiline_literal_string(raw : String, _line : Int32, _column : Int32) : StringValue
      inner = raw[3...(raw.size - closing_quote_run(raw, '\''))]
      inner = strip_first_newline(inner)
      StringValue.new(raw, StringValue::Kind::MultilineLiteral, inner)
    end

    private def closing_quote_run(raw : String, quote : Char) : Int32
      count = 0
      i = raw.size - 1
      while i >= 3 && raw[i] == quote && count < 5
        count += 1
        i -= 1
      end
      count
    end

    private def strip_first_newline(s : String) : String
      if s.starts_with?("\r\n")
        s[2..]
      elsif s.starts_with?('\n')
        s[1..]
      else
        s
      end
    end

    private def decode_basic_escapes(body : String, line : Int32, column : Int32, multiline = false) : String
      String.build do |io|
        i = 0
        bytes = body.to_slice
        while i < bytes.size
          b = bytes[i]
          if b == '\\'.ord
            i = decode_one_escape(bytes, i + 1, io, line, column, multiline)
          else
            io.write_byte(b)
            i += 1
          end
        end
      end
    end

    private def decode_one_escape(bytes : Bytes, i : Int32, io : IO, line : Int32, column : Int32, multiline : Bool) : Int32
      raise ParseError.new("dangling backslash", line, column) if i >= bytes.size
      esc = bytes[i]
      case esc
      when '"'.ord  then io << '"'; i + 1
      when '\\'.ord then io << '\\'; i + 1
      when 'b'.ord  then io << '\b'; i + 1
      when 't'.ord  then io << '\t'; i + 1
      when 'n'.ord  then io << '\n'; i + 1
      when 'f'.ord  then io << '\f'; i + 1
      when 'r'.ord  then io << '\r'; i + 1
      when 'u'.ord  then write_codepoint(io, hex_value(bytes, i + 1, 4, line, column)); i + 5
      when 'U'.ord  then write_codepoint(io, hex_value(bytes, i + 1, 8, line, column)); i + 9
      when ' '.ord, '\t'.ord, '\n'.ord, '\r'.ord
        # Multi-line basic strings allow `\` followed by whitespace
        # then a newline; everything up to the next non-whitespace
        # is trimmed. Single-line basic strings reject this.
        unless multiline
          raise ParseError.new("invalid escape sequence \\#{esc.unsafe_chr}", line, column)
        end
        i = skip_line_continuation(bytes, i, line, column)
        i
      else
        raise ParseError.new("invalid escape sequence \\#{esc.unsafe_chr}", line, column)
      end
    end

    private def hex_value(bytes : Bytes, start : Int32, len : Int32, line : Int32, column : Int32) : Int32
      if start + len > bytes.size
        raise ParseError.new("incomplete unicode escape", line, column)
      end
      n = 0
      len.times do |k|
        b = bytes[start + k]
        d = hex_digit_value(b)
        raise ParseError.new("invalid hex digit in unicode escape", line, column) if d < 0
        n = (n << 4) | d
      end
      n
    end

    private def hex_digit_value(b : UInt8) : Int32
      case b
      when '0'.ord..'9'.ord then (b - '0'.ord).to_i
      when 'a'.ord..'f'.ord then (b - 'a'.ord + 10).to_i
      when 'A'.ord..'F'.ord then (b - 'A'.ord + 10).to_i
      else                       -1
      end
    end

    private def write_codepoint(io : IO, cp : Int32) : Nil
      if cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)
        raise ParseError.new("invalid unicode codepoint U+#{cp.to_s(16).upcase}", 0, 0)
      end
      io << cp.unsafe_chr
    end

    private def skip_line_continuation(bytes : Bytes, i : Int32, line : Int32, column : Int32) : Int32
      # First, all the whitespace right after the backslash up to a
      # newline must be only spaces/tabs.
      j = i
      while j < bytes.size && (bytes[j] == ' '.ord || bytes[j] == '\t'.ord)
        j += 1
      end
      if j >= bytes.size || (bytes[j] != '\n'.ord && bytes[j] != '\r'.ord)
        raise ParseError.new("invalid character after \\ line continuation", line, column)
      end
      # Skip the newline and any further whitespace/newlines.
      while j < bytes.size && (bytes[j] == ' '.ord || bytes[j] == '\t'.ord || bytes[j] == '\n'.ord || bytes[j] == '\r'.ord)
        j += 1
      end
      j
    end

    # ------------------------------------------------------------------
    # Numbers (integers and floats) and booleans
    # ------------------------------------------------------------------

    # Try to decode an atom as an integer, float, boolean, or
    # special float (`inf`, `nan`, `+inf`, `-inf`, `+nan`, `-nan`).
    # Returns `nil` if `raw` is none of these so the caller can try
    # other interpretations (datetime, dotted-key segment, …).
    def try_decode_atom(raw : String) : Value?
      case raw
      when "true"  then return BooleanValue.new(raw, true)
      when "false" then return BooleanValue.new(raw, false)
      when "inf", "+inf"
        return FloatValue.new(raw, Float64::INFINITY)
      when "-inf"
        return FloatValue.new(raw, -Float64::INFINITY)
      when "nan", "+nan", "-nan"
        return FloatValue.new(raw, Float64::NAN)
      end
      decode_number(raw)
    end

    private def decode_number(raw : String) : Value?
      return nil if raw.empty?

      # Hex / oct / bin integers (no sign permitted).
      if raw.size > 2 && raw[0] == '0'
        case raw[1]
        when 'x', 'X' then return decode_int_radix(raw, 2, 16)
        when 'o', 'O' then return decode_int_radix(raw, 2, 8)
        when 'b', 'B' then return decode_int_radix(raw, 2, 2)
        end
      end

      # Decimal integer or exponential int form. Float parsing is
      # not done here — the parser handles `Atom Dot Atom` to build
      # a float string. We accept exponentials like `1e10` as
      # floats here since they are atom-only.
      cleaned = strip_underscores_strict(raw)
      return nil unless cleaned

      if cleaned.includes?('e') || cleaned.includes?('E')
        f = cleaned.to_f64?
        return f ? FloatValue.new(raw, f) : nil
      end

      # Pure integer with optional sign.
      i = cleaned.to_i64?
      return IntegerValue.new(raw, i) if i

      # Could be a leading-zero non-numeric (date components etc.)
      # — return nil so the caller can keep trying.
      nil
    end

    private def decode_int_radix(raw : String, body_start : Int32, radix : Int32) : IntegerValue?
      body = raw[body_start..]
      cleaned = strip_underscores_strict(body)
      return nil unless cleaned
      return nil if cleaned.empty?
      i = cleaned.to_i64?(radix)
      i ? IntegerValue.new(raw, i) : nil
    end

    # Strip underscores from a numeric literal, but only if every
    # underscore is between two digits (valid TOML form). Returns
    # nil otherwise so the caller can fall through.
    private def strip_underscores_strict(s : String) : String?
      return s unless s.includes?('_')
      result = String::Builder.new
      chars = s.chars
      chars.each_with_index do |c, i|
        if c == '_'
          prev = chars[i - 1]?
          nxt = chars[i + 1]?
          return nil unless prev && nxt && digit_in_radix?(prev) && digit_in_radix?(nxt)
        else
          result << c
        end
      end
      result.to_s
    end

    private def digit_in_radix?(c : Char) : Bool
      c.ascii_alphanumeric?
    end

    # Build a `FloatValue` from the textual form `int_part . frac_part`
    # or with an exponent. Used by the parser when it has reassembled
    # the parts that the lexer emitted as `Atom Dot Atom`.
    def decode_float(raw : String) : FloatValue?
      cleaned = strip_underscores_strict(raw)
      return nil unless cleaned
      # Reject anything that is not parseable as a Float64.
      f = cleaned.to_f64?
      f ? FloatValue.new(raw, f) : nil
    end
  end
end
