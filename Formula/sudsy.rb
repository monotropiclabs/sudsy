class Sudsy < Formula
  desc "Keep encrypted environment secrets alongside your code"
  homepage "https://github.com/monotropiclabs/sudsy"
  url "https://github.com/monotropiclabs/sudsy/releases/download/v0.2.0/sudsy"
  version "0.2.0"
  sha256 "e4fc2c96b5c4259687d122bdce6860de16460ace84adec280f239c7a84a9595e"
  license "MIT"

  depends_on "age"
  depends_on "sops"

  def install
    bin.install "sudsy"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/sudsy version")
  end
end
