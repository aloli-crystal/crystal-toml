require "../spec_helper"

describe "TOML::Document edit API" do
  describe "#set on existing top-level key" do
    it "replaces the value while preserving surrounding formatting" do
      doc = TOML.parse(%(  name   =   "Tom"   # original
))
      doc.set("name", "Alice")
      doc.to_toml.should eq(%(  name   =   'Alice'   # original
))
      doc.string("name").should eq("Alice")
    end

    it "preserves a basic-string-needing value's escapes" do
      doc = TOML.parse(%(s = "old"
))
      doc.set("s", "with\nnewline")
      doc.to_toml.should eq(%(s = "with\\nnewline"
))
      doc.string("s").should eq("with\nnewline")
    end

    it "replaces an integer value" do
      doc = TOML.parse(%(port = 8080
))
      doc.set("port", 9090)
      doc.to_toml.should eq(%(port = 9090
))
      doc.int("port").should eq(9090_i64)
    end

    it "replaces with a float, bool" do
      doc = TOML.parse(%(a = 1
b = false
))
      doc.set("a", 2.5)
      doc.set("b", true)
      doc.float("a").should eq(2.5)
      doc.bool("b").should be_true
    end
  end

  describe "#set on missing top-level key" do
    it "appends a new line to an empty document" do
      doc = TOML.parse("")
      doc.set("name", "Alice")
      doc.to_toml.should eq(%(name = 'Alice'
))
    end

    it "appends to a doc with only top-level keys" do
      doc = TOML.parse(%(a = 1
))
      doc.set("b", 2)
      doc.to_toml.should eq(%(a = 1
b = 2
))
    end

    it "inserts before the first table header" do
      doc = TOML.parse(%(a = 1

[server]
host = "x"
))
      doc.set("b", 2)
      doc.to_toml.should eq(%(a = 1
b = 2

[server]
host = "x"
))
    end
  end

  describe "#set_with_comment" do
    it "adds an inline comment to a new line" do
      doc = TOML.parse("")
      doc.set_with_comment("API_KEY", "ak_xxx", "rotated 2026-04-28")
      doc.to_toml.should eq(%(API_KEY = 'ak_xxx' # rotated 2026-04-28
))
    end

    it "replaces an existing trailing comment" do
      doc = TOML.parse(%(a = 1 # old
))
      doc.set_with_comment("a", 2, "new")
      doc.to_toml.should eq(%(a = 2 # new
))
    end
  end

  describe "#delete" do
    it "returns true and removes an existing top-level key" do
      doc = TOML.parse(%(a = 1
b = 2
))
      doc.delete("a").should be_true
      doc.to_toml.should eq(%(b = 2
))
    end

    it "returns false for a missing key without changing the doc" do
      src = %(a = 1
)
      doc = TOML.parse(src)
      doc.delete("zzz").should be_false
      doc.to_toml.should eq(src)
    end

    it "ignores keys that are inside [section] (top-level only)" do
      src = %(top = 1
[s]
nested = 2
)
      doc = TOML.parse(src)
      doc.delete("nested").should be_false
      doc.to_toml.should eq(src)
    end
  end
end
