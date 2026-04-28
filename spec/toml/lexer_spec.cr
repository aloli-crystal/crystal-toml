require "../spec_helper"

private def tokens(source : String) : Array(TOML::Token)
  lexer = TOML::Lexer.new(source)
  result = [] of TOML::Token
  loop do
    tok = lexer.next_token
    result << tok
    break if tok.kind == TOML::TokenKind::EOF
  end
  result
end

private def kinds(source : String) : Array(TOML::TokenKind)
  tokens(source).map(&.kind)
end

describe TOML::Lexer do
  # ------------------------------------------------------------------
  # Trivia
  # ------------------------------------------------------------------

  describe "trivia" do
    it "yields just EOF on empty input" do
      kinds("").should eq([TOML::TokenKind::EOF])
    end

    it "tokenises a run of spaces and tabs as a single Whitespace" do
      toks = tokens("   \t  ")
      toks.size.should eq(2)
      toks[0].kind.should eq(TOML::TokenKind::Whitespace)
      toks[0].raw.should eq("   \t  ")
      toks[1].kind.should eq(TOML::TokenKind::EOF)
    end

    it "splits Whitespace at newline boundaries" do
      kinds("  \n  ").should eq([
        TOML::TokenKind::Whitespace,
        TOML::TokenKind::Newline,
        TOML::TokenKind::Whitespace,
        TOML::TokenKind::EOF,
      ])
    end

    it "recognises \\n and \\r\\n as newlines" do
      tokens("\n").first.raw.should eq("\n")
      tokens("\r\n").first.raw.should eq("\r\n")
    end

    it "rejects a bare \\r (no \\n following)" do
      expect_raises(TOML::ParseError, /carriage return/) do
        tokens("\rabc")
      end
    end

    it "tokenises a comment up to (but not including) the newline" do
      toks = tokens("# hello world\n")
      toks[0].kind.should eq(TOML::TokenKind::Comment)
      toks[0].raw.should eq("# hello world")
      toks[1].kind.should eq(TOML::TokenKind::Newline)
    end

    it "rejects control characters in a comment" do
      expect_raises(TOML::ParseError, /control character/) do
        tokens("# bad\x01char")
      end
    end

    it "allows tabs inside a comment" do
      tokens("# with\ttab").first.raw.should eq("# with\ttab")
    end
  end

  # ------------------------------------------------------------------
  # Structural punctuation
  # ------------------------------------------------------------------

  describe "structural punctuation" do
    it "tokenises = . , { } as single chars" do
      kinds("=.,{ }").should eq([
        TOML::TokenKind::Equal,
        TOML::TokenKind::Dot,
        TOML::TokenKind::Comma,
        TOML::TokenKind::LBrace,
        TOML::TokenKind::Whitespace,
        TOML::TokenKind::RBrace,
        TOML::TokenKind::EOF,
      ])
    end

    it "always emits one LBracket per [, even when adjacent" do
      kinds("[[x]]").should eq([
        TOML::TokenKind::LBracket,
        TOML::TokenKind::LBracket,
        TOML::TokenKind::BareKeyOrAtom,
        TOML::TokenKind::RBracket,
        TOML::TokenKind::RBracket,
        TOML::TokenKind::EOF,
      ])
    end

    it "treats [ [ (with whitespace) as two LBracket" do
      kinds("[ [").should eq([
        TOML::TokenKind::LBracket,
        TOML::TokenKind::Whitespace,
        TOML::TokenKind::LBracket,
        TOML::TokenKind::EOF,
      ])
    end
  end

  # ------------------------------------------------------------------
  # Strings
  # ------------------------------------------------------------------

  describe "basic strings" do
    it "tokenises a simple basic string with delimiters" do
      tok = tokens(%("hello")).first
      tok.kind.should eq(TOML::TokenKind::BasicString)
      tok.raw.should eq(%("hello"))
    end

    it "preserves escape sequences in the raw text" do
      tok = tokens(%("a\\nb\\t\\u00e9")).first
      tok.kind.should eq(TOML::TokenKind::BasicString)
      tok.raw.should eq(%("a\\nb\\t\\u00e9"))
    end

    it "rejects an unterminated basic string" do
      expect_raises(TOML::ParseError, /unterminated basic string/) do
        tokens(%("nope))
      end
    end

    it "rejects a newline inside a basic string" do
      expect_raises(TOML::ParseError, /unterminated basic string/) do
        tokens("\"a\nb\"")
      end
    end

    it "rejects an invalid escape sequence" do
      expect_raises(TOML::ParseError, /invalid escape sequence/) do
        tokens(%("bad \\q escape"))
      end
    end

    it "rejects a short \\u escape" do
      expect_raises(TOML::ParseError, /hex digits/) do
        tokens(%("\\u12"))
      end
    end
  end

  describe "multi-line basic strings" do
    it "tokenises a triple-quoted block including embedded newlines" do
      src = %("""line1\nline2""")
      tok = tokens(src).first
      tok.kind.should eq(TOML::TokenKind::MultilineBasicString)
      tok.raw.should eq(src)
    end

    it "allows up to two extra closing quotes (e.g. \"\"\"ab\"\"\"\"\")" do
      # 3 opening quotes + content "ab" + 5 closing quotes (3 terminator + 2 extras absorbed as content "\"\"")
      src = %("""ab""""")
      tok = tokens(src).first
      tok.kind.should eq(TOML::TokenKind::MultilineBasicString)
      tok.raw.should eq(src)
    end

    it "swallows a single immediate-following newline after the opener" do
      src = "\"\"\"\nbody\"\"\""
      tok = tokens(src).first
      tok.kind.should eq(TOML::TokenKind::MultilineBasicString)
      tok.raw.should eq(src)
    end

    it "supports the \\<newline> line-continuation" do
      src = "\"\"\"a \\\n   b\"\"\""
      tok = tokens(src).first
      tok.kind.should eq(TOML::TokenKind::MultilineBasicString)
      tok.raw.should eq(src)
    end
  end

  describe "literal strings" do
    it "tokenises a single-quoted literal" do
      tok = tokens(%('C:\\path')).first
      tok.kind.should eq(TOML::TokenKind::LiteralString)
      tok.raw.should eq(%('C:\\path'))
    end

    it "rejects an unterminated literal string" do
      expect_raises(TOML::ParseError, /unterminated literal string/) do
        tokens(%('nope))
      end
    end

    it "rejects a newline inside a single-line literal string" do
      expect_raises(TOML::ParseError, /unterminated literal string/) do
        tokens("'a\nb'")
      end
    end
  end

  describe "multi-line literal strings" do
    it "tokenises a triple-quoted literal block" do
      src = "'''line1\nline2'''"
      tok = tokens(src).first
      tok.kind.should eq(TOML::TokenKind::MultilineLiteralString)
      tok.raw.should eq(src)
    end

    it "swallows a single immediate-following newline after the opener" do
      src = "'''\nbody'''"
      tok = tokens(src).first
      tok.kind.should eq(TOML::TokenKind::MultilineLiteralString)
      tok.raw.should eq(src)
    end
  end

  # ------------------------------------------------------------------
  # Atoms (bare keys / value atoms)
  # ------------------------------------------------------------------

  describe "atoms" do
    it "tokenises a bare key as one BareKeyOrAtom" do
      toks = tokens("server_1")
      toks[0].kind.should eq(TOML::TokenKind::BareKeyOrAtom)
      toks[0].raw.should eq("server_1")
    end

    it "tokenises a dotted key as Atom Dot Atom" do
      kinds("physical.shape").should eq([
        TOML::TokenKind::BareKeyOrAtom,
        TOML::TokenKind::Dot,
        TOML::TokenKind::BareKeyOrAtom,
        TOML::TokenKind::EOF,
      ])
    end

    it "tokenises a float as Atom Dot Atom (parser reassembles)" do
      toks = tokens("3.14")
      toks.size.should eq(4) # atom, dot, atom, eof
      toks[0].raw.should eq("3")
      toks[1].kind.should eq(TOML::TokenKind::Dot)
      toks[2].raw.should eq("14")
    end

    it "tokenises a datetime with offset as a single atom (no dot inside)" do
      toks = tokens("1979-05-27T07:32:00-07:00")
      toks.size.should eq(2)
      toks[0].kind.should eq(TOML::TokenKind::BareKeyOrAtom)
      toks[0].raw.should eq("1979-05-27T07:32:00-07:00")
    end

    it "splits a fractional datetime at the dot" do
      kinds("1979-05-27T07:32:00.999-07:00").should eq([
        TOML::TokenKind::BareKeyOrAtom,
        TOML::TokenKind::Dot,
        TOML::TokenKind::BareKeyOrAtom,
        TOML::TokenKind::EOF,
      ])
    end

    it "tokenises a hex integer as a single atom" do
      toks = tokens("0xDEAD_BEEF")
      toks.size.should eq(2)
      toks[0].raw.should eq("0xDEAD_BEEF")
    end

    it "tokenises true / false / inf / nan as atoms" do
      ["true", "false", "inf", "+inf", "-inf", "nan", "+nan", "-nan"].each do |src|
        toks = tokens(src)
        toks.size.should eq(2), "expected 2 tokens for #{src.inspect}"
        toks[0].raw.should eq(src)
      end
    end
  end

  # ------------------------------------------------------------------
  # Realistic snippets
  # ------------------------------------------------------------------

  describe "realistic snippets" do
    it "tokenises a key/value pair" do
      kinds(%(name = "Tom")).should eq([
        TOML::TokenKind::BareKeyOrAtom,
        TOML::TokenKind::Whitespace,
        TOML::TokenKind::Equal,
        TOML::TokenKind::Whitespace,
        TOML::TokenKind::BasicString,
        TOML::TokenKind::EOF,
      ])
    end

    it "tokenises a table header followed by a key/value" do
      src = "[server]\nport = 8080\n"
      kinds(src).should eq([
        TOML::TokenKind::LBracket,
        TOML::TokenKind::BareKeyOrAtom,
        TOML::TokenKind::RBracket,
        TOML::TokenKind::Newline,
        TOML::TokenKind::BareKeyOrAtom,
        TOML::TokenKind::Whitespace,
        TOML::TokenKind::Equal,
        TOML::TokenKind::Whitespace,
        TOML::TokenKind::BareKeyOrAtom,
        TOML::TokenKind::Newline,
        TOML::TokenKind::EOF,
      ])
    end

    it "tokenises an array-of-tables header as two LBracket / two RBracket" do
      kinds("[[products]]").should eq([
        TOML::TokenKind::LBracket,
        TOML::TokenKind::LBracket,
        TOML::TokenKind::BareKeyOrAtom,
        TOML::TokenKind::RBracket,
        TOML::TokenKind::RBracket,
        TOML::TokenKind::EOF,
      ])
    end

    it "tracks line and column for error messages" do
      lex = TOML::Lexer.new("a = 1\nb = 2")
      tok1 = lex.next_token
      tok1.line.should eq(1)
      tok1.column.should eq(1)
      # Skip whitespace, =, whitespace, atom, newline.
      4.times { lex.next_token }
      newline = lex.next_token
      newline.kind.should eq(TOML::TokenKind::Newline)
      b_token = lex.next_token
      b_token.line.should eq(2)
      b_token.column.should eq(1)
    end
  end
end
