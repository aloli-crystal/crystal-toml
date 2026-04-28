require "./node"

module TOML
  class Document
    # Returns the decoded value at the given dotted path, or `nil`
    # if the path does not exist or any intermediate segment is not
    # a table.
    #
    # The path uses `.` as a separator. Quoted segments are *not*
    # supported here — if you need a key that contains a dot, use
    # `Document#get(path : Array(String))` with an explicit array
    # of segments.
    def get?(path : String) : Type?
      get?(path.split('.'))
    end

    def get?(path : Array(String)) : Type?
      h : Type = to_h
      path.each do |segment|
        return nil unless h.is_a?(Hash(String, Type))
        h = h[segment]?
        return nil if h.nil?
      end
      h
    end

    def get(path : String) : Type
      get?(path) || raise KeyError.new("missing key #{path.inspect} in TOML document")
    end

    def has_key?(path : String) : Bool
      !get?(path).nil?
    end

    # ------------------------------------------------------------------
    # Typed accessors
    # ------------------------------------------------------------------
    #
    # Each typed accessor comes in two forms:
    #
    # * `#TYPE?(path)` — returns the value if it exists *and* matches
    #   the requested type, `nil` otherwise.
    # * `#TYPE(path)`  — same, but raises `KeyError` if missing /
    #   `TypeCastError` if the wrong type.

    def string?(path : String) : String?
      v = get?(path)
      v.is_a?(String) ? v : nil
    end

    def string(path : String) : String
      v = get(path)
      v.is_a?(String) ? v : raise TypeCastError.new("value at #{path.inspect} is #{v.class}, expected String")
    end

    def int?(path : String) : Int64?
      v = get?(path)
      v.is_a?(Int64) ? v : nil
    end

    def int(path : String) : Int64
      v = get(path)
      v.is_a?(Int64) ? v : raise TypeCastError.new("value at #{path.inspect} is #{v.class}, expected Int64")
    end

    def float?(path : String) : Float64?
      v = get?(path)
      v.is_a?(Float64) ? v : nil
    end

    def float(path : String) : Float64
      v = get(path)
      v.is_a?(Float64) ? v : raise TypeCastError.new("value at #{path.inspect} is #{v.class}, expected Float64")
    end

    def bool?(path : String) : Bool?
      v = get?(path)
      v.is_a?(Bool) ? v : nil
    end

    def bool(path : String) : Bool
      v = get(path)
      v.is_a?(Bool) ? v : raise TypeCastError.new("value at #{path.inspect} is #{v.class}, expected Bool")
    end

    def datetime?(path : String) : Time?
      v = get?(path)
      v.is_a?(Time) ? v : nil
    end

    def datetime(path : String) : Time
      v = get(path)
      v.is_a?(Time) ? v : raise TypeCastError.new("value at #{path.inspect} is #{v.class}, expected Time")
    end

    def time_of_day?(path : String) : Time::Span?
      v = get?(path)
      v.is_a?(Time::Span) ? v : nil
    end

    def time_of_day(path : String) : Time::Span
      v = get(path)
      v.is_a?(Time::Span) ? v : raise TypeCastError.new("value at #{path.inspect} is #{v.class}, expected Time::Span")
    end
  end
end
