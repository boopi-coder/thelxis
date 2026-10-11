# ADR-001: Flutter + libwebrtc (flutter_webrtc) for all platforms

## Status
Accepted

## Date
2026-10-11

## Context
One product on Windows, macOS, Linux and Android, acting as both host and viewer. The things that decide whether a
remote desktop "freezes" are the capture path, the (hardware) encoder, congestion control/loss recovery and the
network path — not the UI language. The product owner asked whether C++ or assembly would be faster.

## Decision
Flutter (Dart) for UI and app logic, `flutter_webrtc` (Google libwebrtc, C++ with hand-tuned SIMD) for capture,
encoding, transport, congestion control and decoding. Per-OS input injection is native (FFI / Kotlin / Swift)
behind `lib/platform/host_platform.dart`.

## Alternatives Considered
- **Everything in C++ (Qt UI)** — same media engine at best, 5–10× more code, memory-unsafe parsers on a
  network-facing remote-access product (a prime attack target). Rejected.
- **Assembly** — compilers beat hand-written asm except in SIMD kernels, which libwebrtc/libyuv already have; would
  have to be written per CPU architecture. Rejected.
- **Rust core + Flutter UI (RustDesk model)** — own codecs/transport to maintain; RustDesk's freezes show that
  re-implementing congestion control is the hard part. Rejected for v0.x; Rust/C++ remains the option for a
  targeted hot-path module (e.g. zero-copy DXGI→NVENC on Windows) if profiling demands it.

## Consequences
- Hardware codecs, GCC congestion control, NACK/FEC, ICE restart for free; one UI codebase.
- Dependent on flutter_webrtc's platform coverage (desktop capture on Linux X11/PipeWire, Android MediaProjection).
- Dart is memory-safe → the internet-facing listener, STUN/TURN and JSON parsing are not a memory-corruption risk.
