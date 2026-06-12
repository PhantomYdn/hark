# Aural

Native macOS CLI (single Swift binary) that captures microphone and system/per-app audio via Core Audio process taps (macOS 14.4+), saves recordings in transcription-friendly formats, and pipes audio through Unix-style workflows.

## Project Documents

- prd: [PRD.md](PRD.md) — product requirements (v1.0 MVP)
- plan: [PLAN.md](PLAN.md) — phased implementation plan; track progress via checkboxes

## Key Conventions

- Language/build: Swift, SwiftPM; modular targets `DeviceManager`, `TapEngine`, `Encoders`, `CLI`
- Build with `swift build` (or `make build`); run tests with `make test` (wraps `swift test` with CLT Testing.framework path workaround — see Makefile)
- Binary name: `aural`
- Minimum OS: macOS 14.4 (Core Audio process-tap API); Apple Silicon + Intel
- Philosophy: Unix "do one thing well" — composable subcommands, stdout/stdin streaming, POSIX conventions
- No third-party audio drivers (no BlackHole); no network calls by default
- System/app capture requires the macOS "System Audio Recording" TCC permission

## Workflow

- New requirements: update the PRD first (`/prd`), then reflect in the plan (`/plan`)
- Unscheduled work goes into the `Incoming` section of PLAN.md for triage
