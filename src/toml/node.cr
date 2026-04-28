require "./key"
require "./value"

module TOML
  # Top-level AST node. Each concrete subclass corresponds to one
  # logical line (or contiguous block) of the TOML source. Every
  # node carries enough verbatim text (in `raw_*` fields) to
  # re-emit itself byte-for-byte during a round-trip.
  abstract class Node
    abstract def to_toml(io : IO) : Nil

    def to_toml : String
      String.build { |io| to_toml(io) }
    end
  end

  # A line that is *only* a comment, e.g. `   # hello\n`.
  #
  # `raw` is the full line including any leading whitespace, the
  # `#` comment text, and the trailing line terminator (`\n` or
  # `\r\n`). The terminator may be empty if the comment was the
  # very last line of the file with no final newline.
  class CommentLine < Node
    property raw : String

    def initialize(@raw : String)
    end

    def to_toml(io : IO) : Nil
      io << @raw
    end
  end

  # A run of one blank line. `raw` is the line terminator (`\n` or
  # `\r\n`); the lexer collapses several consecutive blank lines
  # into one `BlankLine` per blank line, preserving the exact
  # terminators.
  class BlankLine < Node
    property raw : String

    def initialize(@raw : String)
    end

    def to_toml(io : IO) : Nil
      io << @raw
    end
  end

  # A `key = value` line, possibly with a trailing comment.
  #
  # The line is decomposed so the value can be replaced without
  # losing the surrounding formatting:
  #
  #     leading_ws   key   eq_prefix_ws "=" eq_suffix_ws   value   trailing_raw
  #
  # `trailing_raw` covers any whitespace after the value, an
  # optional inline `# comment`, and the line terminator.
  class KeyValueLine < Node
    property leading_ws : String
    property key : Key
    property eq_prefix_ws : String
    property eq_suffix_ws : String
    property value : Value
    property trailing_raw : String

    def initialize(@leading_ws : String,
                   @key : Key,
                   @eq_prefix_ws : String,
                   @eq_suffix_ws : String,
                   @value : Value,
                   @trailing_raw : String)
    end

    def to_toml(io : IO) : Nil
      io << @leading_ws
      io << @key.raw
      io << @eq_prefix_ws
      io << '='
      io << @eq_suffix_ws
      @value.to_toml(io)
      io << @trailing_raw
    end
  end

  # A `[a.b.c]` standard table header line, possibly with a
  # trailing comment.
  class TableHeaderLine < Node
    property leading_ws : String
    property key : Key
    property inner_prefix_ws : String # ws right after '['
    property inner_suffix_ws : String # ws right before ']'
    property trailing_raw : String

    def initialize(@leading_ws : String,
                   @key : Key,
                   @inner_prefix_ws : String,
                   @inner_suffix_ws : String,
                   @trailing_raw : String)
    end

    def to_toml(io : IO) : Nil
      io << @leading_ws << '[' << @inner_prefix_ws
      io << @key.raw
      io << @inner_suffix_ws << ']' << @trailing_raw
    end
  end

  # A `[[a.b.c]]` array-of-tables header line.
  class ArrayOfTablesLine < Node
    property leading_ws : String
    property key : Key
    property inner_prefix_ws : String
    property inner_suffix_ws : String
    property trailing_raw : String

    def initialize(@leading_ws : String,
                   @key : Key,
                   @inner_prefix_ws : String,
                   @inner_suffix_ws : String,
                   @trailing_raw : String)
    end

    def to_toml(io : IO) : Nil
      io << @leading_ws << "[[" << @inner_prefix_ws
      io << @key.raw
      io << @inner_suffix_ws << "]]" << @trailing_raw
    end
  end

  # The root document. Owns the ordered list of top-level nodes,
  # plus any trailing source text past the last semantic node
  # (typically a final stretch of comments and blank lines without
  # a terminating newline).
  class Document
    getter nodes : Array(Node)
    property trailing_raw : String

    def initialize(@nodes : Array(Node) = [] of Node, @trailing_raw : String = "")
    end

    # Re-serialise the document. Byte-identical to the source for
    # any unmodified document.
    def to_toml : String
      String.build { |io| to_toml(io) }
    end

    def to_toml(io : IO) : Nil
      @nodes.each &.to_toml(io)
      io << @trailing_raw
    end
  end
end
