class Colibri < Formula
  desc "Run GLM-5.2 locally with a tiny C engine"
  homepage "https://github.com/JustVugg/colibri"
  version "1.6.1"
  license "Apache-2.0"

  depends_on :macos
  depends_on arch: :arm64
  depends_on "python@3.14"

  url "https://github.com/JustVugg/colibri/releases/download/v1.6.1/colibri-v1.6.1-macos-arm64.tar.gz"
  sha256 "4a4d4d38d7b45e943170a83cff6a3d5c08f863a43d5fed945c89729114b6b6f0"

  livecheck do
    url "https://github.com/JustVugg/colibri/releases/latest"
    strategy :github_latest
  end

  def install
    libexec.install Dir["*"]
    candidate = Dir[libexec/"colibri-*-macos-arm64"].first
    mv candidate, libexec/"glm" if candidate && File.basename(candidate) != "glm"
    (bin/"coli").write <<~EOS
    #!/bin/bash
    set -euo pipefail
    exec "#{Formula["python@3.14"].opt_bin}/python3" "#{libexec}/coli" "$@"
    EOS
    chmod 0555, bin/"coli"
  end

  test do
    output = shell_output("#{bin}/coli --version 2>&1")
    assert_match "1.6.1", output
  end
end
