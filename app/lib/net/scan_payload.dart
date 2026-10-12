import 'connect_code.dart';
import 'connect_target.dart';

/// What a scanned QR code holds, as far as Thelxis is concerned.
enum ScanKind {
  /// `thelxis://connect?...` invite link (PROTOCOL.md section 3).
  invite,

  /// `TX1.` offer code of "connect by code" (PROTOCOL.md section 12).
  offer,

  /// `TX2.` answer code of "connect by code".
  answer,

  /// Anything else: a foreign QR code or a broken Thelxis one.
  unknown,
}

/// Classifies a scanned QR payload. Only well-formed payloads count, so a
/// random QR code (or a truncated scan) never reaches a connect flow; the
/// flows still do their own full checks (signatures, expiry, identity).
ScanKind classifyScan(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return ScanKind.unknown;
  if (text.toLowerCase().startsWith('thelxis:')) {
    return parseConnectInput(text).isOk ? ScanKind.invite : ScanKind.unknown;
  }
  if (text.startsWith(kOfferPrefix)) {
    return isDecodableCode(text, kOfferPrefix) ? ScanKind.offer : ScanKind.unknown;
  }
  if (text.startsWith(kAnswerPrefix)) {
    return isDecodableCode(text, kAnswerPrefix) ? ScanKind.answer : ScanKind.unknown;
  }
  return ScanKind.unknown;
}
