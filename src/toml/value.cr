require "./parse_error"

module TOML
  # Typed TOML value. Every concrete value remembers its original
  # `raw` source text so the serializer can re-emit it byte-for-byte
  # for unmodified documents.
  #
  # Concrete subclasses expose the decoded value through a typed
  # accessor (`StringValue#decoded`, `IntegerValue#int_value`, …).
  abstract class Value
    getter raw : String

    def initialize(@raw : String)
    end

    def to_toml(io : IO) : Nil
      io << @raw
    end
  end

  # `"basic"`, `"""multi"""`, `'literal'` or `'''multi'''`. The
  # `kind` tells which flavour and `decoded` returns the string
  # with escapes processed and surrounding quotes stripped.
  class StringValue < Value
    enum Kind
      Basic
      MultilineBasic
      Literal
      MultilineLiteral
    end

    getter kind : Kind
    getter decoded : String

    def initialize(raw : String, @kind : Kind, @decoded : String)
      super(raw)
    end
  end

  # `42`, `0xDEAD_BEEF`, `0o755`, `0b1010`, with optional sign and
  # `_` digit separators. `int_value` is the decoded `Int64`.
  class IntegerValue < Value
    getter int_value : Int64

    def initialize(raw : String, @int_value : Int64)
      super(raw)
    end
  end

  # `3.14`, `1e10`, `inf`, `-inf`, `nan`, etc.
  class FloatValue < Value
    getter float_value : Float64

    def initialize(raw : String, @float_value : Float64)
      super(raw)
    end
  end

  class BooleanValue < Value
    getter bool_value : Bool

    def initialize(raw : String, @bool_value : Bool)
      super(raw)
    end
  end

  # RFC 3339 datetime *with* timezone offset, e.g.
  # `1979-05-27T07:32:00-07:00`.
  class OffsetDateTimeValue < Value
    getter time : Time

    def initialize(raw : String, @time : Time)
      super(raw)
    end
  end

  # RFC 3339 datetime *without* timezone offset, e.g.
  # `1979-05-27T07:32:00`. Stored as a `Time` in UTC for arithmetic
  # but the absence of a real offset is conveyed by the type.
  class LocalDateTimeValue < Value
    getter time : Time

    def initialize(raw : String, @time : Time)
      super(raw)
    end
  end

  # `1979-05-27`. Stored as a `Time` at midnight UTC.
  class LocalDateValue < Value
    getter date : Time

    def initialize(raw : String, @date : Time)
      super(raw)
    end
  end

  # `07:32:00.999`. Stored as a `Time::Span` from midnight.
  class LocalTimeValue < Value
    getter time_of_day : Time::Span

    def initialize(raw : String, @time_of_day : Time::Span)
      super(raw)
    end
  end

  # `[1, 2, 3]` (homogeneous or heterogeneous, possibly multi-line).
  # Items keep their original raw formatting; the array re-serialises
  # by concatenating raw items with the original separators.
  class ArrayValue < Value
    getter items : Array(Value)

    def initialize(raw : String, @items : Array(Value))
      super(raw)
    end
  end

  # `{ key = "val", key2 = 42 }`. Inline tables are by spec
  # immutable once written — modification would require deletion and
  # re-insertion. We store them as a parallel list of (path, value)
  # entries where `path` is the array of decoded key segments
  # (length > 1 for dotted keys like `a.b = 1`), to preserve both
  # declaration order and the dotted structure.
  class InlineTableValue < Value
    getter pairs : Array({Array(String), Value})

    def initialize(raw : String, @pairs : Array({Array(String), Value}))
      super(raw)
    end
  end
end
