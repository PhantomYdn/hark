# Hark

Native macOS CLI (single Swift binary) that captures microphone and system/per-app audio via Core Audio process taps (macOS 14.4+), saves recordings in transcription-friendly formats, transcribes them (whisper.cpp; more engines planned), and pipes audio through Unix-style workflows.

## Project Documents

- prd: [PRD.md](PRD.md) — product requirements (v1.0 MVP)
- plan: [PLAN.md](PLAN.md) — phased implementation plan; track progress via checkboxes
- permissions: [docs/permissions.md](docs/permissions.md) — TCC setup (mic + system audio recording), terminal attribution caveats

## Key Conventions

- Language/build: Swift, SwiftPM; modular targets `DeviceManager`, `TapEngine`, `Encoders`, `CLI`
- Build with `swift build` (or `make build`); run tests with `make test` (wraps `swift test` with CLT Testing.framework path workaround — see Makefile)
- Binary name: `hark`
- Minimum OS: macOS 14.4 (Core Audio process-tap API); Apple Silicon + Intel
- Philosophy: Unix "do one thing well" — `hark` itself is the verb (capture/transcribe/transcode via flags); only `devices`/`apps`/`info` (and planned `models`) are subcommands. stdout/stdin streaming, POSIX conventions
- Prefer the simplest viable design: before adding a command/flag, question whether it's needed at all; when a surface feels complex, redesign from the ground up rather than patching incrementally
- No third-party audio drivers (no BlackHole); no network calls by default
- System/app capture requires the macOS "System Audio Recording" TCC permission
- When a change adds/affects a user-facing surface (e.g. `hark config show`, `--help`), verify the surface actually reflects it (run the binary) — don't stop at "it compiles"

## Gotchas

- ArgumentParser: the root command owns flags AND has subcommands. A value-bearing option on the root (e.g. `-i/--input`) "floats up" and is greedily consumed even after a subcommand token, so reusing that option name in a subcommand breaks it. Don't reuse value-bearing option names across root and subcommands — give subcommands positional args instead (e.g. `hark info <file>`).
- Adding a config setting must stay in sync across five places, or builds/tests break: the `ConfigKey` enum, the `Configuration.settings` registry (its count must equal `ConfigKey.allCases`), the `Configuration` field + `CodingKeys`, `ResolvedSettings` (resolve + memberwise init), and any exhaustive `switch ConfigKey` (e.g. `ConfigurationTests.roundTripsAllKeys`).

## Workflow

- New requirements: update the PRD first (`/prd`), then reflect in the plan (`/plan`)
- Unscheduled work goes into the `Incoming` section of PLAN.md for triage
