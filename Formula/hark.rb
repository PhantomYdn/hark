class Hark < Formula
  desc "Capture and transcribe microphone and system audio on macOS"
  homepage "https://github.com/PhantomYdn/hark"
  url "https://github.com/PhantomYdn/hark/releases/download/v0.4.0/hark-0.4.0-macos-arm64.tar.gz"
  version "0.4.0"
  sha256 "f89983526e82be8eedd0e9e12d6cef74afbb0c930c1cd3d1d84a4195a0189042"
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

  # Run the remote-control agent (PRD §6.10) as a per-user LaunchAgent:
  #   brew services start hark
  # It binds loopback on the `remote-control-port` config key (default 8473);
  # set the port/working dir/engine with `hark config`. No `keep_alive` on
  # purpose — a crash or a bad start (e.g. port in use) stays down and visible
  # instead of launchd relaunching it in a throttled loop that hides the bug.
  # `--no-keep-awake` keeps the agent from holding a power assertion (the idle
  # agent never sleeps the Mac anyway); add `--keep-awake` here if you want an
  # active service recording to prevent idle sleep.
  service do
    run [opt_bin/"hark", "--remote-control", "--no-keep-awake"]
    run_type :immediate
    log_path var/"log/hark-remote.log"
    error_log_path var/"log/hark-remote.log"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/hark --version")
  end
end
