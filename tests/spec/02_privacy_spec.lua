local privacy = require("assistit.privacy")

T.describe("privacy guards & secret redaction", function()
  T.it("identifies sensitive filenames (.env, private keys, credentials)", function()
    T.truthy((privacy.is_sensitive_file("/project/.env")))
    T.truthy((privacy.is_sensitive_file("/project/.env.production")))
    T.truthy((privacy.is_sensitive_file("/home/dev/.ssh/id_ed25519")))
    T.truthy((privacy.is_sensitive_file("certs/server.pem")))
    T.truthy((privacy.is_sensitive_file("config/credentials.json")))
    T.falsy((privacy.is_sensitive_file("lua/assistit/init.lua")))
    T.falsy((privacy.is_sensitive_file("src/environment.ts")))
  end)

  T.it("redacts API keys, PEM blocks, JWTs, URI passwords, and secret assignments", function()
    local raw = table.concat({
      'local openai_key = "sk-proj-AbCdEfGhIjKlMnOpQrStUvWxYz123456"',
      'local gh = "ghp_1234567890abcdefghijklmnopqrstuv"',
      'local aws = "AKIAIOSFODNN7EXAMPLE"',
      'local db = "postgres://admin:s3cr3tP4ss@127.0.0.1:5432/app"',
      'local jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"',
      'local password = "MySuperSecretPassword99!"',
      "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEAtestkey\n-----END RSA PRIVATE KEY-----",
      'local normal_greeting = "hello world"',
    }, "\n")

    local sanitized, count = privacy.redact_secrets(raw)
    T.truthy(count >= 7, "Expected at least 7 redactions, got " .. tostring(count))
    T.falsy(sanitized:find("sk%-proj%-"))
    T.falsy(sanitized:find("ghp_12345"))
    T.falsy(sanitized:find("AKIAIOSFODNN7EXAMPLE"))
    T.falsy(sanitized:find("s3cr3tP4ss"))
    T.falsy(sanitized:find("MySuperSecretPassword99"))
    T.falsy(sanitized:find("MIIEpAIBAAKCAQEAtestkey"))
    -- Preserves benign code
    T.matches(sanitized, 'local normal_greeting = "hello world"')
  end)

  T.it("enforces loopback endpoint check unless remote opt-in is enabled", function()
    local ok_local = privacy.check_endpoint("http://127.0.0.1:11434/api/generate", { local_only = true })
    T.truthy(ok_local)
    local ok_localhost = privacy.check_endpoint("http://localhost:8080/infill", { local_only = true })
    T.truthy(ok_localhost)

    local ok_ext, reason = privacy.check_endpoint("https://remote.ai.example/v1", { local_only = true })
    T.falsy(ok_ext)
    T.matches(reason, "Blocked outbound request")
  end)
end)
