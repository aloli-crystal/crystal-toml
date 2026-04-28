require "json"
require "./node"
require "./value"

module TOML
  # JSON encoder that mirrors the format expected by the official
  # `toml-lang/toml-test` interop suite.
  #
  # Each leaf TOML value is wrapped in a JSON object of the form
  # `{ "type": "<kind>", "value": "<text>" }` where `<text>` is
  # always a JSON string (even for integers and floats). Tables
  # become regular JSON objects, arrays become JSON arrays.
  #
  # Internal — exposed only so `bin/crystal-toml-decoder` can import
  # it. Not part of the public API.
  module TestFormat
    extend self

    # Recursive union the visitor builds before serializing as JSON.
    alias Tree = Value | Hash(String, Tree) | Array(Tree)

    def encode(doc : Document) : String
      tree = build_tree(doc)
      JSON.build(indent: "  ") do |json|
        emit(tree, json)
      end
    end

    # ------------------------------------------------------------------
    # Tree construction (mirrors HashBuilder but keeps Value types)
    # ------------------------------------------------------------------

    private def build_tree(doc : Document) : Hash(String, Tree)
      root = {} of String => Tree
      current = root

      doc.nodes.each do |node|
        case node
        when KeyValueLine
          insert_kv(current, node.key.path, value_to_tree(node.value))
        when TableHeaderLine
          current = ensure_table(root, node.key.path)
        when ArrayOfTablesLine
          current = ensure_array_of_tables(root, node.key.path)
        end
      end

      root
    end

    private def insert_kv(table : Hash(String, Tree), path : Array(String), value : Tree) : Nil
      target = table
      path[0..-2].each do |seg|
        sub = target[seg]?
        if sub.is_a?(Hash(String, Tree))
          target = sub
        else
          new_table = {} of String => Tree
          target[seg] = new_table
          target = new_table
        end
      end
      target[path[-1]] = value
    end

    private def ensure_table(root : Hash(String, Tree), path : Array(String)) : Hash(String, Tree)
      target = root
      path.each do |seg|
        sub = target[seg]?
        case sub
        when Hash(String, Tree)
          target = sub
        when Array(Tree)
          last = sub[-1]?
          if last.is_a?(Hash(String, Tree))
            target = last
          else
            new_table = {} of String => Tree
            sub << new_table
            target = new_table
          end
        else
          new_table = {} of String => Tree
          target[seg] = new_table
          target = new_table
        end
      end
      target
    end

    private def ensure_array_of_tables(root : Hash(String, Tree), path : Array(String)) : Hash(String, Tree)
      parent = root
      path[0..-2].each do |seg|
        sub = parent[seg]?
        if sub.is_a?(Hash(String, Tree))
          parent = sub
        else
          new_table = {} of String => Tree
          parent[seg] = new_table
          parent = new_table
        end
      end
      last = path[-1]
      arr = parent[last]?
      if arr.is_a?(Array(Tree))
        new_table = {} of String => Tree
        arr << new_table
        new_table
      else
        new_arr = [] of Tree
        new_table = {} of String => Tree
        new_arr << new_table
        parent[last] = new_arr
        new_table
      end
    end

    private def value_to_tree(v : Value) : Tree
      case v
      when ArrayValue
        v.items.map { |item| value_to_tree(item).as(Tree) }
      when InlineTableValue
        h = {} of String => Tree
        v.pairs.each { |(k, sub)| h[k] = value_to_tree(sub) }
        h
      else
        v
      end
    end

    # ------------------------------------------------------------------
    # JSON emission
    # ------------------------------------------------------------------

    private def emit(node : Tree, json : JSON::Builder) : Nil
      case node
      when Hash(String, Tree)
        json.object do
          node.each do |k, v|
            json.field(k) { emit(v, json) }
          end
        end
      when Array(Tree)
        json.array do
          node.each { |v| emit(v, json) }
        end
      when Value
        emit_leaf(node, json)
      end
    end

    private def emit_leaf(v : Value, json : JSON::Builder) : Nil
      json.object do
        json.field "type", json_type(v)
        json.field "value", json_value(v)
      end
    end

    private def json_type(v : Value) : String
      case v
      when StringValue         then "string"
      when IntegerValue        then "integer"
      when FloatValue          then "float"
      when BooleanValue        then "bool"
      when OffsetDateTimeValue then "datetime"
      when LocalDateTimeValue  then "datetime-local"
      when LocalDateValue      then "date-local"
      when LocalTimeValue      then "time-local"
      else                          raise "BUG: cannot encode #{v.class}"
      end
    end

    private def json_value(v : Value) : String
      case v
      when StringValue
        v.decoded
      when IntegerValue
        v.int_value.to_s
      when FloatValue
        format_float(v.float_value)
      when BooleanValue
        v.bool_value ? "true" : "false"
      when OffsetDateTimeValue
        format_offset_datetime(v.time)
      when LocalDateTimeValue
        format_local_datetime(v.time)
      when LocalDateValue
        format_local_date(v.date)
      when LocalTimeValue
        format_local_time(v.time_of_day)
      else
        raise "BUG: cannot encode #{v.class}"
      end
    end

    private def format_float(f : Float64) : String
      if f.nan?
        "nan"
      elsif f.infinite? == 1
        "inf"
      elsif f.infinite? == -1
        "-inf"
      else
        # toml-test wants a value that round-trips. Use the
        # default Float64 representation; integer-valued floats
        # still need a decimal point.
        s = f.to_s
        s.includes?('.') || s.includes?('e') || s.includes?('E') ? s : "#{s}.0"
      end
    end

    private def format_offset_datetime(time : Time) : String
      # Crystal's #to_rfc3339 produces e.g.
      # "1979-05-27T07:32:00-07:00", which is exactly what
      # toml-test expects (with optional fractional seconds).
      time.to_rfc3339(fraction_digits: fraction_digits_for(time))
    end

    private def format_local_datetime(time : Time) : String
      # Same shape as RFC 3339 minus the offset suffix.
      base = time.to_s("%Y-%m-%dT%H:%M:%S")
      append_fraction(base, time)
    end

    private def format_local_date(time : Time) : String
      time.to_s("%Y-%m-%d")
    end

    private def format_local_time(span : Time::Span) : String
      total_ns = span.total_nanoseconds.to_i64
      seconds_total = total_ns // 1_000_000_000
      ns = total_ns - seconds_total * 1_000_000_000
      h = (seconds_total // 3600).to_i32
      m = ((seconds_total % 3600) // 60).to_i32
      s = (seconds_total % 60).to_i32
      base = "%02d:%02d:%02d" % [h, m, s]
      ns == 0 ? base : "#{base}.#{format_fraction(ns)}"
    end

    private def fraction_digits_for(time : Time) : Int32
      time.nanosecond == 0 ? 0 : 6
    end

    private def append_fraction(base : String, time : Time) : String
      time.nanosecond == 0 ? base : "#{base}.#{format_fraction(time.nanosecond.to_i64)}"
    end

    private def format_fraction(ns : Int64) : String
      # Trim trailing zeros, but keep at least one digit.
      s = ns.to_s.rjust(9, '0')
      stripped = s.rstrip('0')
      stripped.empty? ? "0" : stripped
    end
  end
end
