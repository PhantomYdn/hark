# Legal, Export Classification & Responsible Use

> **This document is informational, not legal advice.** It records how Hark is
> self-classified for export-control purposes and what responsibilities fall on
> users. If you redistribute Hark commercially, bundle it into another product,
> or operate it in a regulated environment, get advice for your own situation.

Hark is a native macOS CLI that captures and transcribes audio **on-device**.
It is published as **MIT-licensed, publicly-available open source** and makes
**no network calls by default** (model downloads and any cloud engine are
explicit, opt-in). These two facts drive everything below.

## Cryptography & export classification

**Hark contains no proprietary cryptography.** It implements no cipher, key
exchange, or encryption feature of its own. Its only cryptographic use is
**ancillary** to the primary function (audio capture / transcription):

- **OS-provided TLS** via `URLSession` when you opt in to downloading a model
  (e.g. from Hugging Face) — the system's cryptography, not Hark's.
- **Apple CryptoKit** (OS-provided), used by the CoreML engine dependencies
  (WhisperKit / FluidAudio) for hashing during model download and caching —
  never as a user-facing feature.

Because the cryptographic functionality is not a primary function and is limited
to supporting download/integrity/transport, Hark falls under:

- **Note 4 to Category 5, Part 2** of the EAR / Wassenaar dual-use list — the
  **ancillary cryptography** exclusion, which removes such items from the
  encryption controls of Category 5 Part 2.
- The **publicly-available open-source** provisions of the U.S. EAR
  (§734.3(b)(3), §742.15(b), and License Exception TSU at §740.13(e)) — publicly
  available encryption source code is, in general, **not subject to the EAR** (or
  qualifies for License Exception TSU).

**Self-classification:** Hark is treated as **EAR99 / not a controlled
encryption item**. No export licence is believed necessary to publish it as open
source.

**TSU notification (deferred).** Projects that *use* encryption sometimes send a
one-time courtesy notification to BIS (`crypt@bis.doc.gov`) and the NSA
(`enc@nsa.gov`) with the repository URL. Given Hark's crypto is ancillary and the
source is publicly available, this is treated as **optional and deferred**. It
should be revisited if Hark ever adds a **non-ancillary** cryptographic
dependency (e.g. its own encryption feature) or begins **commercial / binary
import** distribution into a regulated market.

## Encryption import & registration regimes

Some jurisdictions require importers to **notify or register** encryption
products before they may be imported or sold — for example Russia (FSB
notification) or China (encryption import rules). The key points for Hark:

- These obligations generally bind the **in-country importer or distributor of
  an encryption product**, not the act of **publishing open source** on a public
  code host (which is treated as making source publicly available, not as
  importing a product).
- Hark has only **ancillary** cryptography and no proprietary cipher, so it is
  unlikely to meet the definition of a controlled "encryption product" in the
  first place.
- This analysis would change if someone **packages and imports a commercial
  build** of Hark into such a market; that party should perform its own import
  assessment.

## Surveillance / interception controls

Dual-use lists also cover **interception, "intrusion software", and covert
surveillance** technology. Hark is **not** such a tool:

- It **cannot capture anything without an explicit macOS TCC grant**
  (Microphone, System Audio Recording, or Screen Recording — see
  [permissions.md](permissions.md)). Capture is **overt and consent-gated** by
  the operating system.
- It runs **locally and on-device**, exfiltrates nothing (no network by
  default, no telemetry), and ships no mechanism to covertly install, hide, or
  remotely deploy itself.

In other words it sits in the same category as a screen recorder or a voice
recorder (OBS, QuickTime, Audacity), not interception/intrusion tooling.

## Responsible use & recording-consent law

Hark records audio; **whether a given recording is lawful is the user's
responsibility.** Recording-consent rules vary widely:

- **United States** — federal ECPA plus state law; some states require
  **all-party (two-party) consent**.
- **EU / UK** — recording and processing voice can be **personal data** under
  the GDPR / UK GDPR, with its own lawful-basis and notice obligations.
- Many other jurisdictions have their own wiretap / privacy rules.

Before recording calls, meetings, or other people, **make sure you have the
consent and legal basis required where you are and where the other parties are.**
Hark requires explicit OS permission, never captures covertly, and keeps audio
and transcripts on your machine unless you choose to send them elsewhere.

## Summary

| Concern | Hark's position |
|---|---|
| Encryption export control (EAR / Wassenaar) | Ancillary crypto only → Note 4 exclusion; publicly-available open source → EAR99 / not subject. No licence believed required. |
| BIS/NSA TSU notification | Optional, **deferred** — revisit if a non-ancillary crypto dep or commercial/import channel is added. |
| Encryption import / registration (Russia, China, …) | Binds in-country importers/distributors of encryption *products*, not OSS publication; Hark is not a proprietary encryption product. |
| Surveillance / intrusion-software controls | Not applicable — overt, TCC-consent-gated, on-device, no exfiltration. |
| Recording-consent law (wiretap, GDPR, …) | **User responsibility.** Hark requires OS permission and captures nothing covertly. |

*Informational only — not legal advice.*
