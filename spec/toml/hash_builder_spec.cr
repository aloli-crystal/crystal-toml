require "../spec_helper"

describe "TOML.parse_to_hash" do
  it "returns an empty hash for an empty document" do
    TOML.parse_to_hash("").should eq({} of String => TOML::Type)
  end

  it "extracts top-level key/values" do
    h = TOML.parse_to_hash(<<-TOML)
      title = "Example"
      port = 8080
      enabled = true
      TOML
    h["title"].should eq("Example")
    h["port"].should eq(8080_i64)
    h["enabled"].should eq(true)
  end

  it "drops comments and blank lines" do
    h = TOML.parse_to_hash(<<-TOML)
      # leading comment
      title = "Example"

      # another
      port = 8080
      TOML
    h.size.should eq(2)
  end

  it "builds nested tables from headers" do
    h = TOML.parse_to_hash(<<-TOML)
      [server]
      host = "0.0.0.0"
      port = 8080

      [server.tls]
      cert = "/etc/cert.pem"
      TOML
    server = h["server"].as(Hash(String, TOML::Type))
    server["host"].should eq("0.0.0.0")
    server["port"].should eq(8080_i64)
    tls = server["tls"].as(Hash(String, TOML::Type))
    tls["cert"].should eq("/etc/cert.pem")
  end

  it "handles dotted keys inside the current table" do
    h = TOML.parse_to_hash(<<-TOML)
      [server]
      tls.cert = "/etc/cert.pem"
      tls.key  = "/etc/key.pem"
      TOML
    tls = h["server"].as(Hash(String, TOML::Type))["tls"].as(Hash(String, TOML::Type))
    tls["cert"].should eq("/etc/cert.pem")
    tls["key"].should eq("/etc/key.pem")
  end

  it "builds arrays of tables" do
    h = TOML.parse_to_hash(<<-TOML)
      [[products]]
      name = "Hammer"
      sku  = 738594937

      [[products]]
      name = "Nail"
      sku  = 284758393
      TOML
    products = h["products"].as(Array(TOML::Type))
    products.size.should eq(2)
    products[0].as(Hash(String, TOML::Type))["name"].should eq("Hammer")
    products[1].as(Hash(String, TOML::Type))["name"].should eq("Nail")
  end

  it "decodes strings with escapes" do
    h = TOML.parse_to_hash(%(s = "a\\nb"))
    h["s"].should eq("a\nb")
  end

  it "decodes a complete sample document" do
    src = <<-TOML
      title = "TOML Example"

      [database]
      ports = [8001, 8001, 8002]
      enabled = true
      data = [["delta", "phi"], [3.14]]

      [servers.alpha]
      ip = "10.0.0.1"
      role = "frontend"

      [servers.beta]
      ip = "10.0.0.2"
      role = "backend"
      TOML
    h = TOML.parse_to_hash(src)
    h["title"].should eq("TOML Example")
    db = h["database"].as(Hash(String, TOML::Type))
    db["ports"].as(Array(TOML::Type)).should eq([8001_i64, 8001_i64, 8002_i64])
    db["enabled"].should eq(true)
    inner = db["data"].as(Array(TOML::Type))
    inner[0].as(Array(TOML::Type)).should eq(["delta", "phi"])
    inner[1].as(Array(TOML::Type)).should eq([3.14])

    servers = h["servers"].as(Hash(String, TOML::Type))
    servers["alpha"].as(Hash(String, TOML::Type))["ip"].should eq("10.0.0.1")
    servers["beta"].as(Hash(String, TOML::Type))["role"].should eq("backend")
  end

  it "decodes inline tables" do
    h = TOML.parse_to_hash(%(point = { x = 1, y = 2 }))
    point = h["point"].as(Hash(String, TOML::Type))
    point["x"].should eq(1_i64)
    point["y"].should eq(2_i64)
  end

  it "rejects duplicate top-level keys" do
    expect_raises(TOML::ParseError, /duplicate key/) do
      TOML.parse_to_hash("a = 1\na = 2\n")
    end
  end

  it "preserves the AST through Document#to_h" do
    doc = TOML.parse(%(title = "x"))
    doc.to_h.should eq({"title" => "x"})
    # The AST itself is unchanged.
    doc.to_toml.should eq(%(title = "x"))
  end
end
