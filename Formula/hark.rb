class Hark < Formula
  desc "Capture and transcribe microphone and system audio on macOS"
  homepage "https://github.com/PhantomYdn/hark"
  url "https://github.com/PhantomYdn/hark/releases/download/v0.1.0/hark-0.1.0-macos-arm64.tar.gz"
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"

  # Prebuilt Apple Silicon binary; Intel users build from source (see README).
  depends_on arch: :arm64
  depends_on macos: :sonoma

  # The default `whisper` engine shells out to whisper.cpp at runtime.
  depends_on "whisper-cpp"

  def install
    bin.install "hark"
    man1.install "hark.1"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/hark --version")
  end
end
