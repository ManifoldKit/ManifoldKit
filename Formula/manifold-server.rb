# typed: false
# frozen_string_literal: true

# ManifoldKit OpenAI-compatible inference server.
#
# The `Server` trait activates the Hummingbird-based HTTP server and its
# dependencies. Without it the executable compiles to a stub that prints a
# "trait not enabled" message; passing `--traits Server` at build time is
# therefore mandatory.
#
# Build-time note: ManifoldKit pins llama.cpp as a ~563 MB prebuilt
# xcframework. SwiftPM resolves *all* declared packages regardless of trait
# selection, so the xcframework is downloaded even in a Server-only build. On
# a cold machine with no local SwiftPM cache expect 10–20 minutes for
# dependency download + compilation. Subsequent installs reuse the cache.
class ManifoldServer < Formula
  desc "OpenAI-compatible local inference server powered by ManifoldKit"
  homepage "https://github.com/ManifoldKit/ManifoldKit"
  url "https://github.com/ManifoldKit/ManifoldKit/archive/refs/tags/v0.46.0.tar.gz"
  sha256 "ea3d4d1100bf14e2c901a7a734e4c8e59208f006e3bc16991e2478b20dd94999"
  license "MIT"
  head "https://github.com/ManifoldKit/ManifoldKit.git", branch: "main"

  # ManifoldKit requires a Swift 6.1+ toolchain. Xcode 16.3+ ships Swift 6.1;
  # Xcode 16+ ships Swift 6.0 which is insufficient.
  depends_on xcode: ["16.3", :build]
  depends_on macos: :sequoia

  def install
    # SwiftPM's sandbox restricts network access. Pass --disable-sandbox so
    # the resolver can fetch packages that were not pre-cached by `brew fetch`.
    # This mirrors the pattern used by swiftlint, swift-format, and other
    # SwiftPM formulae (e.g. nicklockwood/SwiftFormat).
    system "swift", "build",
      "--configuration", "release",
      "--product", "ManifoldServer",
      "--traits", "Server",
      "--disable-sandbox"

    bin.install ".build/release/ManifoldServer" => "manifold-server"
  end

  def caveats
    <<~EOS
      manifold-server binds to 127.0.0.1:8080 by default.

      Start with a specific backend (example — Ollama must be running):
        manifold-server --backend ollama --model llama3.2

      Secure the server with an API key:
        manifold-server --api-key sk-my-secret --backend ollama --model llama3.2

      Configure Cursor / Continue to use manifold-server:
        base URL : http://127.0.0.1:8080/v1
        API key  : (the value you passed to --api-key, or leave blank)
        model    : (the model you specified with --model)

      For all flags:
        manifold-server --help

      For full documentation see:
        #{homepage}/blob/main/docs/QUICKSTART-SERVER.md

      Gatekeeper note: pre-built binaries downloaded via the GitHub release
      (non-formula) are unsigned. If macOS quarantines the binary, run:
        xattr -dr com.apple.quarantine $(which manifold-server)
    EOS
  end

  test do
    # Verify the binary runs and responds to --help (ArgumentParser exit 0).
    system bin/"manifold-server", "--help"
  end
end
