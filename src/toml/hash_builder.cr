require "./node"
require "./value"

module TOML
  # Recursive union of every type a TOML value can decode to.
  #
  # Mirrors the type returned by `crystal-community/TOML.cr` so a
  # consumer can drop in `crystal-toml` without rewriting their
  # call sites that pattern-match on the value.
  alias Type = Nil | String | Int64 | Float64 | Bool | Time | Time::Span |
               Array(Type) | Hash(String, Type)

  # Walks a `Document` AST and produces a plain `Hash(String, Type)`.
  #
  # All trivia (comments, blanks, formatting) is discarded; only the
  # logical structure is kept. The resulting hash is suitable for
  # `crystal-community/TOML.cr` users migrating to this shard.
  module HashBuilder
    extend self

    def build(document : Document) : Hash(String, Type)
      root = {} of String => Type
      current = root
      # Tables that have been *explicitly* declared via `[a.b]` —
      # re-declaring one is forbidden in TOML v1.0.
      explicit_tables = Set(String).new

      document.nodes.each do |node|
        case node
        when KeyValueLine
          insert_key_value(current, node.key.path, value_to_type(node.value), node.key)
        when TableHeaderLine
          path_key = node.key.path.join("\x00")
          if explicit_tables.includes?(path_key)
            raise ParseError.new("table #{node.key.raw} is defined more than once", 0, 0)
          end
          explicit_tables << path_key
          current = ensure_table(root, node.key.path)
        when ArrayOfTablesLine
          current = ensure_array_of_tables(root, node.key.path)
        end
      end

      root
    end

    # ------------------------------------------------------------------
    # Internals
    # ------------------------------------------------------------------

    private def insert_key_value(table : Hash(String, Type), path : Array(String), value : Type, key : Key) : Nil
      if path.empty?
        raise ParseError.new("empty key path", 0, 0)
      end

      target = table
      path[0..-2].each do |segment|
        existing = target[segment]?
        case existing
        when Nil
          new_table = {} of String => Type
          target[segment] = new_table
          target = new_table
        when Hash(String, Type)
          target = existing
        else
          raise ParseError.new("cannot extend non-table key #{segment.inspect}", 0, 0)
        end
      end

      last = path[-1]
      if target.has_key?(last)
        raise ParseError.new("duplicate key #{key.raw.inspect}", 0, 0)
      end
      target[last] = value
    end

    private def ensure_table(root : Hash(String, Type), path : Array(String)) : Hash(String, Type)
      target = root
      path.each do |segment|
        existing = target[segment]?
        case existing
        when Nil
          new_table = {} of String => Type
          target[segment] = new_table
          target = new_table
        when Hash(String, Type)
          target = existing
        when Array(Type)
          # An array-of-tables: walk into the *last* element.
          last_elem = existing[-1]?
          unless last_elem.is_a?(Hash(String, Type))
            raise ParseError.new("cannot define table inside non-table-array #{segment.inspect}", 0, 0)
          end
          target = last_elem
        else
          raise ParseError.new("cannot extend non-table key #{segment.inspect}", 0, 0)
        end
      end
      target
    end

    private def ensure_array_of_tables(root : Hash(String, Type), path : Array(String)) : Hash(String, Type)
      if path.empty?
        raise ParseError.new("empty array-of-tables path", 0, 0)
      end

      parent = root
      path[0..-2].each do |segment|
        existing = parent[segment]?
        case existing
        when Nil
          new_table = {} of String => Type
          parent[segment] = new_table
          parent = new_table
        when Hash(String, Type)
          parent = existing
        when Array(Type)
          last_elem = existing[-1]?
          unless last_elem.is_a?(Hash(String, Type))
            raise ParseError.new("cannot extend non-table-array #{segment.inspect}", 0, 0)
          end
          parent = last_elem
        else
          raise ParseError.new("cannot extend non-table key #{segment.inspect}", 0, 0)
        end
      end

      last = path[-1]
      array = parent[last]?
      case array
      when Nil
        new_array = [] of Type
        parent[last] = new_array
        new_table = {} of String => Type
        new_array << new_table
        new_table
      when Array(Type)
        new_table = {} of String => Type
        array << new_table
        new_table
      else
        raise ParseError.new("cannot append to non-array key #{last.inspect}", 0, 0)
      end
    end

    private def insert_path(h : Hash(String, Type), path : Array(String), value : Type) : Nil
      target = h
      path[0..-2].each do |seg|
        sub = target[seg]?
        if sub.is_a?(Hash(String, Type))
          target = sub
        else
          new_table = {} of String => Type
          target[seg] = new_table
          target = new_table
        end
      end
      target[path[-1]] = value
    end

    private def value_to_type(value : Value) : Type
      case value
      when StringValue         then value.decoded
      when IntegerValue        then value.int_value
      when FloatValue          then value.float_value
      when BooleanValue        then value.bool_value
      when LocalDateValue      then value.date
      when LocalDateTimeValue  then value.time
      when OffsetDateTimeValue then value.time
      when LocalTimeValue      then value.time_of_day
      when ArrayValue          then value.items.map { |item| value_to_type(item).as(Type) }
      when InlineTableValue
        h = {} of String => Type
        value.pairs.each { |(path, v)| insert_path(h, path, value_to_type(v)) }
        h
      else
        raise "BUG: unknown value type #{value.class}"
      end
    end
  end
end
