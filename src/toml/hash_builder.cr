require "./node"
require "./value"

module TOML
  # Recursive union of every type a TOML value can decode to.
  #
  # Mirrors the type returned by `crystal-community/TOML.cr` so a
  # consumer can drop in `toml` without rewriting their
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
      current_path = [] of String
      # Paths declared via `[a.b]` — re-declaring one is forbidden.
      explicit_tables = Set(String).new
      # Paths declared via `[[a.b]]` — `[a.b]` on the same path is
      # forbidden, but a further `[[a.b]]` opens another slot.
      aot_paths = Set(String).new
      # Paths implicitly created as tables by dotted keys (e.g.
      # `a.b.c = 1` creates `a` and `a.b`). A subsequent `[a.b]`
      # would re-declare `a.b` and is rejected.
      dotted_implicit = Set(String).new
      # Paths whose value was an inline table or a static array.
      # Once closed, any further extension (header or KV) is
      # rejected — checked by prefix.
      inline_closed = Set(String).new

      document.nodes.each do |node|
        case node
        when KeyValueLine
          full_path = current_path + node.key.path
          ensure_not_inside_inline!(inline_closed, full_path, node.key.raw)
          ensure_dotted_key_not_into_explicit!(explicit_tables, current_path.size, full_path)
          insert_key_value(current, node.key.path, value_to_type(node.value), node.key)
          register_dotted_implicits(dotted_implicit, current_path.size, full_path)
          mark_inline_paths(inline_closed, full_path, node.value)
        when TableHeaderLine
          ensure_not_inside_inline!(inline_closed, node.key.path, node.key.raw)
          path_key = node.key.path.join("\x00")
          if explicit_tables.includes?(path_key) ||
             dotted_implicit.includes?(path_key) ||
             aot_paths.includes?(path_key)
            raise ParseError.new("table #{node.key.raw} is defined more than once", 0, 0)
          end
          explicit_tables << path_key
          current = ensure_table(root, node.key.path)
          current_path = node.key.path.dup
        when ArrayOfTablesLine
          ensure_not_inside_inline!(inline_closed, node.key.path, node.key.raw)
          path_key = node.key.path.join("\x00")
          if explicit_tables.includes?(path_key) ||
             dotted_implicit.includes?(path_key)
            raise ParseError.new("cannot redefine #{node.key.raw} as array of tables", 0, 0)
          end
          aot_paths << path_key
          # Each `[[arr]]` opens a fresh slot. All bookkeeping
          # entries that lived strictly *under* the array's path
          # belonged to the previous slot and must be cleared, so
          # that the new slot is unconstrained.
          drop_under(inline_closed, node.key.path)
          drop_under(explicit_tables, node.key.path)
          drop_under(aot_paths, node.key.path)
          drop_under(dotted_implicit, node.key.path)
          current = ensure_array_of_tables(root, node.key.path)
          current_path = node.key.path.dup
        end
      end

      root
    end

    # Rejects a dotted-key KV whose path traverses a table that
    # was *explicitly* declared in some earlier section. TOML 1.0
    # forbids extending an explicit table from another section
    # via a dotted key — see toml-lang/toml issue #846.
    private def ensure_dotted_key_not_into_explicit!(explicit : Set(String), section_size : Int32, full_path : Array(String)) : Nil
      first = section_size + 1
      last = full_path.size - 1
      return if first > last
      (first..last).each do |len|
        prefix = full_path[0...len].join("\x00")
        if explicit.includes?(prefix)
          path_str = full_path[0...len].join('.')
          raise ParseError.new("cannot extend explicitly-declared table [#{path_str}] from a dotted key", 0, 0)
        end
      end
    end

    # Adds every intermediate path produced by a dotted key (the
    # part of the full path that lies *between* the section path
    # and the leaf) to `set`. `section_size` is the length of the
    # current section's path.
    private def register_dotted_implicits(set : Set(String), section_size : Int32, full_path : Array(String)) : Nil
      first_intermediate = section_size + 1
      last_intermediate = full_path.size - 1
      return if first_intermediate > last_intermediate
      (first_intermediate..last_intermediate).each do |len|
        set << full_path[0...len].join("\x00")
      end
    end

    # Raise if any prefix of `path` (or `path` itself) was closed
    # by a previous inline-table assignment.
    private def ensure_not_inside_inline!(closed : Set(String), path : Array(String), raw : String) : Nil
      (1..path.size).each do |len|
        prefix_key = path[0...len].join("\x00")
        if closed.includes?(prefix_key)
          raise ParseError.new("cannot extend inline-defined table at #{raw}", 0, 0)
        end
      end
    end

    private def drop_under(set : Set(String), path : Array(String)) : Nil
      prefix = path.join("\x00") + "\x00"
      set.select(&.starts_with?(prefix)).each { |p| set.delete(p) }
    end

    # Walks `value` and marks paths that close their key for any
    # further extension. Two cases:
    #
    # * Inline tables : the key path that holds an inline-table
    #   value can not be reopened with `[a.b]` or `a.b.x = ...`.
    # * Static arrays : a key whose value is `[...]` (an inline
    #   array) similarly closes the key — `[[a]]` after `a = [...]`
    #   is rejected because `a` is already a static array.
    #
    # The prefix check in `ensure_not_inside_inline!` then
    # transitively forbids any nested extension. The recursion
    # walks into arrays of inline tables.
    private def mark_inline_paths(closed : Set(String), base : Array(String), value : Value) : Nil
      case value
      when InlineTableValue
        closed << base.join("\x00")
        value.pairs.each do |(path, sub)|
          mark_inline_paths(closed, base + path, sub)
        end
      when ArrayValue
        closed << base.join("\x00")
        value.items.each_with_index do |item, idx|
          mark_inline_paths(closed, base + [idx.to_s], item)
        end
      end
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
        case sub
        when Hash(String, Type)
          target = sub
        when Nil
          new_table = {} of String => Type
          target[seg] = new_table
          target = new_table
        else
          raise ParseError.new("cannot extend non-table key #{seg.inspect}", 0, 0)
        end
      end
      last = path[-1]
      if target.has_key?(last)
        raise ParseError.new("duplicate key #{last.inspect}", 0, 0)
      end
      target[last] = value
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
        # Inline-table-local closure: a key whose value is itself
        # an inline table (or a static array) is closed for any
        # further extension among the *same* inline table's pairs.
        local_closed = Set(String).new
        value.pairs.each do |(path, v)|
          (1..path.size).each do |len|
            prefix = path[0...len].join("\x00")
            if local_closed.includes?(prefix)
              raise ParseError.new("cannot extend inline-defined key in inline table", 0, 0)
            end
          end
          insert_path(h, path, value_to_type(v))
          if v.is_a?(InlineTableValue) || v.is_a?(ArrayValue)
            local_closed << path.join("\x00")
          end
        end
        h
      else
        raise "BUG: unknown value type #{value.class}"
      end
    end
  end
end
