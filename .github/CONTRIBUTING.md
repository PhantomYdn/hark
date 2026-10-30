# Contributing to hark

Thanks for your interest in improving **hark**! This project aims to stay small,
sharp, and Unix-y. Bug reports, docs fixes, and focused features are all welcome.

## Ground rules

- **Open an issue first** for anything non-trivial (a new flag, a new
  subcommand, a behavior change). hark deliberately keeps its surface minimal —
  see the philosophy in [AGENTS.md](../AGENTS.md) and the [PRD](../PRD.md). Small
  fixes and docs can go straight to a PR.
- **Keep it native.** No third-party audio drivers (no BlackHole) and no network
  calls by default. Everything runs on-device.
- **`hark` is the verb.** Capture/transcribe/transcode are expressed via flags on
  the root command; only `devices`/`apps`/`info`/`models`/`config` are
  subcommands. Question whether a new command or flag is needed at all before
  adding one.

## Development setup

Requires the Swift 6.2+ toolchain (Xcode 26+); the built binary runs on macOS 14.4+.

```sh
git clone https://github.com/PhantomYdn/hark.git && cd hark
make build      # swift build
make test       # swift test (with a CLT Testing.framework path workaround)
make release    # swift build -c release
```

Modular SwiftPM targets: `DeviceManager`, `TapEngine`, `Encoders`, `CLI`.

Many integration tests are gated on optional tools (whisper.cpp, a model, `say`,
Speech authorization) and skip cleanly when those are absent, so the suite stays
green on a stock machine and in CI.

## Before you open a PR

- [ ] `make build` and `make test` pass locally.
- [ ] New/changed **user-facing surfaces are verified by running the binary** —
      don't stop at "it compiles". Check `hark --help`, `hark config show`, etc.
      actually reflect the change.
- [ ] Docs updated where relevant: `README.md`, `docs/reference.md`, the man page
      (`man/hark.1`), and `CHANGELOG.md` (`Unreleased` section).
- [ ] Commits follow the existing [Conventional Commits](https://www.conventionalcommits.org/)
      style (`feat:`, `fix:`, `docs:`, `chore:`, …).

## Gotchas worth knowing

These bite people; they're documented in [AGENTS.md](../AGENTS.md) too:

- **ArgumentParser float-up.** The root command owns flags *and* has subcommands.
  A value-bearing root option (e.g. `-i/--input`) is greedily consumed even after
  a subcommand token, so don't reuse a value-bearing option name across the root
  and a subcommand — give subcommands positional args instead (e.g.
  `hark info <file>`).
- **Adding a config setting touches five places** or builds/tests break: the
  `ConfigKey` enum, the `Configuration.settings` registry (its count must equal
  `ConfigKey.allCases`), the `Configuration` field + `CodingKeys`,
  `ResolvedSettings` (resolve + memberwise init), and any exhaustive
  `switch ConfigKey` (e.g. `ConfigurationTests.roundTripsAllKeys`).

## Reporting bugs & requesting features

Use the [issue templates](https://github.com/PhantomYdn/hark/issues/new/choose).
For questions and ideas, open a
[Discussion](https://github.com/PhantomYdn/hark/discussions).

By contributing, you agree that your contributions are licensed under the
project's [MIT License](../LICENSE).
