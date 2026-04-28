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
      # Both opening and closing delimiters are exactly 3 quotes.
      # Any extra quote that appears in a `""""` run before the
      # actual end is *content* (the lexer has already absorbed up
      # to 2 such extras into `raw`).
      inner = raw[3...(raw.size - 3)]
      inner = strip_first_newline(inner)
      decoded = decode_basic_escapes(inner, line, column, multiline: true)
      StringValue.new(raw, StringValue::Kind::MultilineBasic, decoded)
    end

    def decode_literal_string(raw : String, _line : Int32, _column : Int32) : StringValue
      StringValue.new(raw, StringValue::Kind::Literal, raw[1..-2])
    end

    def decode_multiline_literal_string(raw : String, _line : Int32, _column : Int32) : StringValue
      inner = raw[3...(raw.size - 3)]
      inner = strip_first_newline(inner)
      StringValue.new(raw, StringValue::Kind::MultilineLiteral, inner)
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

      # Hex / oct / bin integers (no sign permitted, no
      # underscore directly after the prefix, lowercase prefix
      # only per TOML 1.0).
      if raw.size > 2 && raw[0] == '0'
        case raw[1]
        when 'x' then return decode_int_radix(raw, 2, 16)
        when 'o' then return decode_int_radix(raw, 2, 8)
        when 'b' then return decode_int_radix(raw, 2, 2)
        when 'X', 'O', 'B'
          # Uppercase prefix not allowed.
          return nil
        end
      end

      # Strip an optional sign for leading-zero detection.
      body_start = (raw[0] == '+' || raw[0] == '-') ? 1 : 0
      body = raw[body_start..]
      return nil if body.empty?

      # Reject leading zeros on integer-shape literals: `07`, `0_0`,
      # `+007`, `-01`. A leading `0` followed by `.`, `e` or `E` is
      # not an integer here — `decode_float` handles it below.
      if body.size > 1 && body[0] == '0' && body[1] != '.' && body[1] != 'e' && body[1] != 'E'
        return nil
      end

      # Exponential form (or float-shape): delegate to decode_float.
      if body.includes?('e') || body.includes?('E')
        return decode_float(raw)
      end

      # Underscore must not bound the body.
      return nil if body[0] == '_' || body[-1] == '_'
      cleaned = strip_underscores_decimal(body, body_start > 0 ? raw[0..0] : "")
      return nil unless cleaned
      i = cleaned.to_i64?
      i ? IntegerValue.new(raw, i) : nil
    end

    private def strip_underscores_decimal(body : String, sign : String) : String?
      # Each `_` must lie between two ASCII digits, and only digits
      # (besides `_`) are allowed in a decimal integer body.
      result = String::Builder.new
      result << sign
      chars = body.chars
      chars.each_with_index do |c, i|
        if c == '_'
          prev = i > 0 ? chars[i - 1] : nil
          nxt = i + 1 < chars.size ? chars[i + 1] : nil
          return nil unless prev && nxt && prev.ascii_number? && nxt.ascii_number?
        elsif c.ascii_number?
          result << c
        else
          return nil
        end
      end
      result.to_s
    end

    private def decode_int_radix(raw : String, body_start : Int32, radix : Int32) : IntegerValue?
      body = raw[body_start..]
      return nil if body.empty?
      # Underscore must not bound the body (`0x_DEAD`, `0xDEAD_`).
      return nil if body[0] == '_' || body[-1] == '_'
      cleaned = strip_underscores_radix(body, radix)
      return nil unless cleaned
      return nil if cleaned.empty?
      i = cleaned.to_i64?(radix)
      i ? IntegerValue.new(raw, i) : nil
    end

    # Underscores may only sit between two valid digits of the
    # given radix; any other character (including signs `-`/`+`
    # which TOML disallows after a `0x`/`0o`/`0b` prefix) makes
    # the literal invalid.
    private def strip_underscores_radix(body : String, radix : Int32) : String?
      result = String::Builder.new
      chars = body.chars
      chars.each_with_index do |c, i|
        if c == '_'
          prev = i > 0 ? chars[i - 1] : nil
          nxt = i + 1 < chars.size ? chars[i + 1] : nil
          return nil unless prev && nxt && radix_digit?(prev, radix) && radix_digit?(nxt, radix)
        elsif radix_digit?(c, radix)
          result << c
        else
          return nil
        end
      end
      result.to_s
    end

    private def radix_digit?(c : Char, radix : Int32) : Bool
      case radix
      when  2 then c == '0' || c == '1'
      when  8 then c >= '0' && c <= '7'
      when 16 then c.ascii_number? || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
      else         c.ascii_number?
      end
    end

    # Build a `FloatValue` from the textual form `int_part . frac_part`
    # or with an exponent. Used by the parser when it has reassembled
    # the parts that the lexer emitted as `Atom Dot Atom`.
    def decode_float(raw : String) : FloatValue?
      return nil if raw.empty?

      sign_offset = (raw[0] == '+' || raw[0] == '-') ? 1 : 0
      body = raw[sign_offset..]
      return nil if body.empty?

      # Body must not start or end with a structural character.
      first = body[0]
      last = body[-1]
      return nil if first == '.' || first == '_' || first == 'e' || first == 'E'
      return nil if last == '.' || last == '_' || last == 'e' || last == 'E' || last == '+' || last == '-'

      # Reject leading zero on an integer part with more than one
      # character before the `.` or `e` (rules out `07.5`, `+02.0`).
      if first == '0' && body.size > 1
        second = body[1]
        return nil if second != '.' && second != 'e' && second != 'E'
      end

      # `.` must be present at most once and bordered by digits.
      if dot_idx = body.index('.')
        return nil unless body[dot_idx - 1].ascii_number?
        return nil unless body[dot_idx + 1].ascii_number?
        return nil if body.index('.', dot_idx + 1) # two dots
      end

      # Each `_` must lie between two ASCII digits, anywhere in the
      # body. The exponent's optional sign is allowed but not
      # adjacent to an underscore.
      body.each_char_with_index do |c, i|
        next unless c == '_'
        prev = i > 0 ? body[i - 1] : nil
        nxt = i + 1 < body.size ? body[i + 1] : nil
        return nil unless prev && nxt && prev.ascii_number? && nxt.ascii_number?
      end

      cleaned = (sign_offset == 1 ? raw[0..0] + body : body).delete('_')
      f = cleaned.to_f64?
      f ? FloatValue.new(raw, f) : nil
    end

    # ------------------------------------------------------------------
    # Date and time
    # ------------------------------------------------------------------

    # Try to decode `raw` as one of the four TOML date/time variants:
    # OffsetDateTime, LocalDateTime, LocalDate, LocalTime. Returns
    # `nil` if `raw` does not match any of these shapes so the
    # caller can keep trying integer/float interpretations.
    #
    # Accepts both `T`/`t` and a literal space as the date/time
    # delimiter (per TOML 1.0). The lexer emits a space-separated
    # form as separate tokens, so this method only sees `T`/`t`
    # forms and the space variant must be reassembled by the parser.
    def try_decode_datetime(raw : String) : Value?
      bytes = raw.to_slice
      size = bytes.size

      # Full date-time: at least "yyyy-mm-ddThh:mm:ss" (19 bytes).
      if size >= 19 && date_part?(bytes, 0) && time_separator?(bytes[10]?) && time_part?(bytes, 11)
        return decode_full_datetime(raw, bytes)
      end

      # LocalDate alone: exactly "yyyy-mm-dd".
      if size == 10 && date_part?(bytes, 0)
        return decode_local_date(raw, bytes)
      end

      # LocalTime alone: at least "hh:mm:ss".
      if size >= 8 && time_part?(bytes, 0)
        return decode_local_time(raw, bytes)
      end

      nil
    end

    private def date_part?(b : Bytes, off : Int32) : Bool
      return false if off + 10 > b.size
      digit?(b[off]) && digit?(b[off + 1]) && digit?(b[off + 2]) && digit?(b[off + 3]) &&
        b[off + 4] == '-'.ord &&
        digit?(b[off + 5]) && digit?(b[off + 6]) &&
        b[off + 7] == '-'.ord &&
        digit?(b[off + 8]) && digit?(b[off + 9])
    end

    private def time_part?(b : Bytes, off : Int32) : Bool
      return false if off + 8 > b.size
      digit?(b[off]) && digit?(b[off + 1]) &&
        b[off + 2] == ':'.ord &&
        digit?(b[off + 3]) && digit?(b[off + 4]) &&
        b[off + 5] == ':'.ord &&
        digit?(b[off + 6]) && digit?(b[off + 7])
    end

    private def time_separator?(b : UInt8?) : Bool
      b == 'T'.ord || b == 't'.ord || b == ' '.ord
    end

    private def digit?(b : UInt8) : Bool
      b >= '0'.ord && b <= '9'.ord
    end

    private def decode_local_date(raw : String, b : Bytes) : LocalDateValue
      year = parse_int(b, 0, 4)
      month = parse_int(b, 5, 2)
      day = parse_int(b, 8, 2)
      time = build_time(year, month, day, 0, 0, 0, 0, "+00:00", raw, 0)
      LocalDateValue.new(raw, time)
    end

    private def decode_local_time(raw : String, b : Bytes) : LocalTimeValue
      hour = parse_int(b, 0, 2)
      minute = parse_int(b, 3, 2)
      second = parse_int(b, 6, 2)
      validate_time_fields(hour, minute, second, raw)

      ns = 0_i64
      if b.size > 8
        if b[8] != '.'.ord
          raise ParseError.new("invalid local time #{raw.inspect}", 0, 0)
        end
        ns = parse_fractional(b, 9, b.size - 9, raw)
      end

      span = Time::Span.new(
        hours: hour,
        minutes: minute,
        seconds: second,
      ) + Time::Span.new(nanoseconds: ns)
      LocalTimeValue.new(raw, span)
    end

    private def decode_full_datetime(raw : String, b : Bytes) : Value
      year = parse_int(b, 0, 4)
      month = parse_int(b, 5, 2)
      day = parse_int(b, 8, 2)
      hour = parse_int(b, 11, 2)
      minute = parse_int(b, 14, 2)
      second = parse_int(b, 17, 2)
      validate_time_fields(hour, minute, second, raw)

      offset_idx = 19
      ns = 0_i64

      # Optional fractional second.
      if offset_idx < b.size && b[offset_idx] == '.'.ord
        frac_start = offset_idx + 1
        frac_end = frac_start
        while frac_end < b.size && digit?(b[frac_end])
          frac_end += 1
        end
        if frac_end == frac_start
          raise ParseError.new("expected digits after '.' in datetime #{raw.inspect}", 0, 0)
        end
        ns = parse_fractional(b, frac_start, frac_end - frac_start, raw)
        offset_idx = frac_end
      end

      offset_str : String? = nil
      if offset_idx < b.size
        offset_str = String.new(b[offset_idx, b.size - offset_idx])
      end

      if offset_str.nil?
        time = build_time(year, month, day, hour, minute, second, ns, "+00:00", raw, 0)
        LocalDateTimeValue.new(raw, time)
      else
        normalised = normalize_offset(offset_str, raw)
        time = build_time(year, month, day, hour, minute, second, ns, normalised, raw, 0)
        OffsetDateTimeValue.new(raw, time)
      end
    end

    private def normalize_offset(s : String, raw : String) : String
      return "+00:00" if s == "Z" || s == "z"
      unless s.size == 6 && (s[0] == '+' || s[0] == '-') && s[3] == ':' &&
             s[1].ascii_number? && s[2].ascii_number? &&
             s[4].ascii_number? && s[5].ascii_number?
        raise ParseError.new("invalid timezone offset in datetime #{raw.inspect}", 0, 0)
      end
      hours = s[1..2].to_i
      minutes = s[4..5].to_i
      if hours > 23 || minutes > 59
        raise ParseError.new("timezone offset out of range in datetime #{raw.inspect}", 0, 0)
      end
      s
    end

    private def parse_int(b : Bytes, off : Int32, len : Int32) : Int32
      n = 0
      len.times do |k|
        n = n * 10 + (b[off + k] - '0'.ord).to_i
      end
      n
    end

    private def parse_fractional(b : Bytes, off : Int32, len : Int32, raw : String) : Int64
      # Convert fractional second to nanoseconds; truncate beyond
      # 9 digits per RFC 3339 / TOML guidance.
      effective = Math.min(len, 9)
      n = 0_i64
      effective.times do |k|
        unless digit?(b[off + k])
          raise ParseError.new("invalid fractional second in #{raw.inspect}", 0, 0)
        end
        n = n * 10 + (b[off + k] - '0'.ord).to_i64
      end
      # Validate any remaining (truncated) digits.
      (effective...len).each do |k|
        unless digit?(b[off + k])
          raise ParseError.new("invalid fractional second in #{raw.inspect}", 0, 0)
        end
      end
      # Pad to 9 digits (nanosecond precision).
      (9 - effective).times { n *= 10 }
      n
    end

    private def validate_time_fields(hour : Int32, minute : Int32, second : Int32, raw : String) : Nil
      if hour > 23 || minute > 59 || second > 60
        raise ParseError.new("invalid time component in #{raw.inspect}", 0, 0)
      end
    end

    private def build_time(year, month, day, hour, minute, second, nanoseconds, offset_str, raw, _line) : Time
      sign = offset_str[0] == '-' ? -1 : 1
      off_h = offset_str[1..2].to_i
      off_m = offset_str[4..5].to_i
      offset_seconds = sign * (off_h * 3600 + off_m * 60)
      location = Time::Location.fixed(offset_seconds)
      Time.local(year, month, day, hour, minute, second, nanosecond: nanoseconds.to_i32, location: location)
    rescue ex : ArgumentError
      raise ParseError.new("invalid datetime #{raw.inspect}: #{ex.message}", 0, 0)
    end
  end
end
