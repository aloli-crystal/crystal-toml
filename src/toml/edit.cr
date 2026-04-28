require "./node"
require "./value"
require "./key"

module TOML
  # ------------------------------------------------------------------
  # String/value emitters used by the edit API
  # ------------------------------------------------------------------

  # :nodoc:
  module Emit
    extend self

    # Quote `s` as a TOML basic string. Picks the *literal* form if
    # the string contains no character that requires escaping (no
    # apostrophes, no control chars), otherwise emits a basic
    # string with the standard escapes.
    def quote_string(s : String) : String
      if literal_safe?(s)
        "'" + s + "'"
      else
        quote_basic(s)
      end
    end

    private def literal_safe?(s : String) : Bool
      s.each_char do |c|
        return false if c == '\'' || c == '\n' || c == '\r' || (c.ord < 0x20 && c != '\t') || c.ord == 0x7F
      end
      true
    end

    private def quote_basic(s : String) : String
      String.build do |io|
        io << '"'
        s.each_char do |c|
          case c
          when '"'  then io << "\\\""
          when '\\' then io << "\\\\"
          when '\b' then io << "\\b"
          when '\t' then io << "\\t"
          when '\n' then io << "\\n"
          when '\f' then io << "\\f"
          when '\r' then io << "\\r"
          else
            if c.ord < 0x20 || c.ord == 0x7F
              io << "\\u" << c.ord.to_s(16).rjust(4, '0').upcase
            else
              io << c
            end
          end
        end
        io << '"'
      end
    end

    def value_for(s : String) : StringValue
      raw = quote_string(s)
      kind = raw.starts_with?("'") ? StringValue::Kind::Literal : StringValue::Kind::Basic
      StringValue.new(raw, kind, s)
    end

    def value_for(i : Int) : IntegerValue
      IntegerValue.new(i.to_s, i.to_i64)
    end

    def value_for(f : Float) : FloatValue
      raw = case
            when f.nan?            then "nan"
            when f.infinite? == 1  then "inf"
            when f.infinite? == -1 then "-inf"
            else                        f.to_s
            end
      FloatValue.new(raw, f.to_f64)
    end

    def value_for(b : Bool) : BooleanValue
      BooleanValue.new(b ? "true" : "false", b)
    end
  end

  # ------------------------------------------------------------------
  # Edit API on Document (top-level keys only, for v0.1)
  # ------------------------------------------------------------------

  class Document
    # Sets a top-level key to `value`. If a top-level KeyValueLine
    # already exists for that key, only its value (and any trailing
    # comment if `comment` is given) is replaced — surrounding
    # whitespace and comments are preserved. Otherwise a new line
    # is inserted at the end of the top-level section (before the
    # first table header).
    #
    # `comment` is the trailing comment text *without* the leading
    # `#`. Pass an empty string to clear an existing trailing
    # comment, `nil` to leave it untouched on update.
    #
    # The current implementation operates on a single bare key. For
    # dotted paths or values inside `[section]` blocks, see issue
    # tracker — those are planned but not in v0.1.
    def set(key : String, value : String) : Nil
      do_set(key, Emit.value_for(value), nil)
    end

    def set(key : String, value : Int) : Nil
      do_set(key, Emit.value_for(value), nil)
    end

    def set(key : String, value : Float) : Nil
      do_set(key, Emit.value_for(value), nil)
    end

    def set(key : String, value : Bool) : Nil
      do_set(key, Emit.value_for(value), nil)
    end

    # Same as `#set` but also sets a trailing inline comment on the
    # line. The `comment` argument should *not* include the leading
    # `#`; it is added automatically with a single space prefix.
    def set_with_comment(key : String, value : String, comment : String) : Nil
      do_set(key, Emit.value_for(value), comment)
    end

    def set_with_comment(key : String, value : Int, comment : String) : Nil
      do_set(key, Emit.value_for(value), comment)
    end

    # Removes the top-level KeyValueLine with the given bare key,
    # if any. Returns `true` if a line was deleted, `false` if no
    # such top-level key existed.
    def delete(key : String) : Bool
      idx = top_level_kv_index(key)
      return false unless idx
      @nodes.delete_at(idx)
      true
    end

    # ------------------------------------------------------------------
    # Internals
    # ------------------------------------------------------------------

    private def do_set(key : String, value : Value, comment : String?) : Nil
      idx = top_level_kv_index(key)
      if idx
        line = @nodes[idx].as(KeyValueLine)
        line.value = value
        update_trailing_comment(line, comment) if comment
      else
        new_line = build_top_level_kv_line(key, value, comment)
        @nodes.insert(top_level_insertion_idx, new_line)
      end
    end

    # Where to splice a brand-new top-level KeyValueLine.
    #
    # Goal: keep top-level keys grouped together. The chosen index
    # is *one past the last `KeyValueLine` that is itself top-level*
    # (i.e. before any `[section]`). If there is no top-level
    # KeyValueLine, we fall back to the very start of the document
    # — which is still before any `[section]`.
    private def top_level_insertion_idx : Int32
      last_kv = -1
      @nodes.each_with_index do |node, i|
        case node
        when TableHeaderLine, ArrayOfTablesLine
          break
        when KeyValueLine
          last_kv = i
        end
      end
      last_kv + 1
    end

    # Index of the first top-level (i.e. before any TableHeader or
    # ArrayOfTables) `KeyValueLine` whose single-segment key
    # decodes to `key`. Nil if missing.
    private def top_level_kv_index(key : String) : Int32?
      @nodes.each_with_index do |node, i|
        case node
        when TableHeaderLine, ArrayOfTablesLine then return nil
        when KeyValueLine
          path = node.key.path
          return i if path.size == 1 && path[0] == key
        end
      end
      nil
    end

    private def build_top_level_kv_line(key : String, value : Value, comment : String?) : KeyValueLine
      key_raw = bare_or_quoted_key(key)
      key_obj = Key.new([KeyPart.new(key_raw, key)], key_raw)
      trailing = comment ? " # #{comment}\n" : "\n"
      KeyValueLine.new(
        leading_ws: "",
        key: key_obj,
        eq_prefix_ws: " ",
        eq_suffix_ws: " ",
        value: value,
        trailing_raw: trailing,
      )
    end

    private def bare_or_quoted_key(key : String) : String
      bare = !key.empty? && key.each_char.all? do |c|
        c.ascii_letter? || c.ascii_number? || c == '_' || c == '-'
      end
      bare ? key : Emit.quote_string(key)
    end

    # Replace (or insert) the trailing inline comment on `line`
    # while preserving the line terminator and any pre-comment
    # whitespace.
    private def update_trailing_comment(line : KeyValueLine, comment : String) : Nil
      terminator = line_terminator(line.trailing_raw)
      line.trailing_raw = " # #{comment}#{terminator}"
    end

    private def line_terminator(trailing_raw : String) : String
      if trailing_raw.ends_with?("\r\n")
        "\r\n"
      elsif trailing_raw.ends_with?('\n')
        "\n"
      else
        "\n"
      end
    end
  end
end
