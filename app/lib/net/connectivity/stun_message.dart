// STUN (RFC 5389) message codec with the TURN (RFC 5766) attributes the
// embedded relay needs. Pure bytes-in / bytes-out; no sockets.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../core/base64url.dart' show constantTimeEquals;
import 'interfaces.dart';
import 'stun_crypto.dart';

const int stunMagicCookie = 0x2112A442;
const int stunHeaderLength = 20;
const int stunIntegrityLength = 24; // header (4) + HMAC-SHA1 (20)
const int stunFingerprintLength = 8; // header (4) + CRC-32 (4)

abstract final class StunClass {
  static const int request = 0;
  static const int indication = 1;
  static const int success = 2;
  static const int error = 3;
}

abstract final class StunMethod {
  static const int binding = 0x001;
  static const int allocate = 0x003;
  static const int refresh = 0x004;
  static const int send = 0x006;
  static const int data = 0x007;
  static const int createPermission = 0x008;
  static const int channelBind = 0x009;
}

abstract final class StunAttr {
  static const int mappedAddress = 0x0001;
  static const int username = 0x0006;
  static const int messageIntegrity = 0x0008;
  static const int errorCode = 0x0009;
  static const int unknownAttributes = 0x000A;
  static const int channelNumber = 0x000C;
  static const int lifetime = 0x000D;
  static const int xorPeerAddress = 0x0012;
  static const int data = 0x0013;
  static const int realm = 0x0014;
  static const int nonce = 0x0015;
  static const int xorRelayedAddress = 0x0016;
  static const int requestedAddressFamily = 0x0017;
  static const int evenPort = 0x0018;
  static const int requestedTransport = 0x0019;
  static const int dontFragment = 0x001A;
  static const int xorMappedAddress = 0x0020;
  static const int reservationToken = 0x0022;
  static const int software = 0x8022;
  static const int fingerprint = 0x8028;
}

abstract final class StunError {
  static const int badRequest = 400;
  static const int unauthorized = 401;
  static const int forbidden = 403;
  static const int allocationMismatch = 437;
  static const int staleNonce = 438;
  static const int addressFamilyNotSupported = 440;
  static const int wrongCredentials = 441;
  static const int unsupportedTransport = 442;
  static const int peerAddressFamilyMismatch = 443;
  static const int allocationQuotaReached = 486;
  static const int insufficientCapacity = 508;
}

/// One TLV attribute (value is unpadded).
class StunAttribute {
  const StunAttribute(this.type, this.value);

  factory StunAttribute.string(int type, String text) =>
      StunAttribute(type, Uint8List.fromList(utf8.encode(text)));

  factory StunAttribute.uint32(int type, int value) {
    final v = Uint8List(4);
    ByteData.sublistView(v).setUint32(0, value);
    return StunAttribute(type, v);
  }

  factory StunAttribute.errorCode(int code, String reason) {
    final reasonBytes = utf8.encode(reason);
    final v = Uint8List(4 + reasonBytes.length);
    v[2] = code ~/ 100;
    v[3] = code % 100;
    v.setRange(4, v.length, reasonBytes);
    return StunAttribute(StunAttr.errorCode, v);
  }

  factory StunAttribute.xorAddress(
    int type,
    InternetAddress address,
    int port,
    Uint8List transactionId,
  ) {
    final raw = unmapIpv4(address).rawAddress;
    final v = Uint8List(4 + raw.length);
    v[1] = raw.length == 4 ? 0x01 : 0x02;
    ByteData.sublistView(v).setUint16(2, port ^ (stunMagicCookie >>> 16));
    final mask = _xorMask(transactionId);
    for (var i = 0; i < raw.length; i++) {
      v[4 + i] = raw[i] ^ mask[i];
    }
    return StunAttribute(type, v);
  }

  final int type;
  final Uint8List value;
}

class StunAddress {
  const StunAddress(this.address, this.port);

  final InternetAddress address;
  final int port;
}

/// The 16-byte XOR pad: magic cookie, then the transaction id (RFC 5389 §15.2).
Uint8List _xorMask(Uint8List transactionId) {
  final mask = Uint8List(16);
  ByteData.sublistView(mask).setUint32(0, stunMagicCookie);
  mask.setRange(4, 16, transactionId);
  return mask;
}

final Random _rng = Random.secure();

Uint8List randomTransactionId() =>
    Uint8List.fromList(List.generate(12, (_) => _rng.nextInt(256)));

/// Message type field (RFC 5389 §6): 14 bits interleaving method and class.
int stunMessageType(int method, int messageClass) =>
    (method & 0x000F) |
    ((messageClass & 0x1) << 4) |
    ((method & 0x0070) << 1) |
    ((messageClass & 0x2) << 7) |
    ((method & 0x0F80) << 2);

class StunMessage {
  StunMessage({
    required this.method,
    required this.messageClass,
    required this.transactionId,
    List<StunAttribute>? attributes,
  }) : attributes = attributes ?? [];

  final int method;
  final int messageClass;
  final Uint8List transactionId;
  final List<StunAttribute> attributes;

  Uint8List? _raw;
  int _integrityOffset = -1;
  int _fingerprintOffset = -1;

  int get type => stunMessageType(method, messageClass);

  bool get isRequest => messageClass == StunClass.request;
  bool get isIndication => messageClass == StunClass.indication;

  bool get hasIntegrity => _integrityOffset >= 0;
  bool get hasFingerprint => _fingerprintOffset >= 0;

  /// True for datagrams that look like STUN (first two bits zero, magic
  /// cookie present). Used to demultiplex from ChannelData (first bits 01).
  static bool looksLikeStun(Uint8List data) =>
      data.length >= stunHeaderLength &&
      (data[0] & 0xC0) == 0 &&
      ByteData.sublistView(data).getUint32(4) == stunMagicCookie;

  /// Parses one message; null when malformed.
  static StunMessage? parse(Uint8List data) {
    if (!looksLikeStun(data)) return null;
    final view = ByteData.sublistView(data);
    final length = view.getUint16(2);
    if (length % 4 != 0 || stunHeaderLength + length > data.length) return null;
    final end = stunHeaderLength + length;

    final type = view.getUint16(0);
    final messageClass = ((type & 0x0100) >> 7) | ((type & 0x0010) >> 4);
    final method =
        (type & 0x000F) | ((type & 0x00E0) >> 1) | ((type & 0x3E00) >> 2);

    final message = StunMessage(
      method: method,
      messageClass: messageClass,
      transactionId: Uint8List.fromList(data.sublist(8, 20)),
    );
    message._raw = Uint8List.fromList(data.sublist(0, end));

    var offset = stunHeaderLength;
    while (offset < end) {
      if (offset + 4 > end) return null;
      final attrType = view.getUint16(offset);
      final attrLength = view.getUint16(offset + 2);
      final valueStart = offset + 4;
      final valueEnd = valueStart + attrLength;
      final next = valueStart + ((attrLength + 3) & ~3);
      if (valueEnd > end || next > end) return null;
      if (attrType == StunAttr.messageIntegrity && message._integrityOffset < 0) {
        if (attrLength != 20) return null;
        message._integrityOffset = offset;
      } else if (attrType == StunAttr.fingerprint &&
          message._fingerprintOffset < 0) {
        if (attrLength != 4) return null;
        message._fingerprintOffset = offset;
      }
      message.attributes.add(StunAttribute(
        attrType,
        Uint8List.fromList(data.sublist(valueStart, valueEnd)),
      ));
      offset = next;
    }
    return message;
  }

  StunAttribute? attribute(int type) {
    for (final a in attributes) {
      if (a.type == type) return a;
    }
    return null;
  }

  Iterable<StunAttribute> attributesOf(int type) =>
      attributes.where((a) => a.type == type);

  String? stringAttribute(int type) {
    final a = attribute(type);
    return a == null ? null : utf8.decode(a.value, allowMalformed: true);
  }

  int? uint32Attribute(int type) {
    final a = attribute(type);
    if (a == null || a.value.length != 4) return null;
    return ByteData.sublistView(a.value).getUint32(0);
  }

  StunAddress? xorAddress(int type) {
    final a = attribute(type);
    return a == null ? null : decodeXorAddress(a.value, transactionId);
  }

  /// (code, reason) of an ERROR-CODE attribute.
  ({int code, String reason})? get errorCode {
    final a = attribute(StunAttr.errorCode);
    if (a == null || a.value.length < 4) return null;
    return (
      code: (a.value[2] & 0x07) * 100 + a.value[3],
      reason: utf8.decode(a.value.sublist(4), allowMalformed: true),
    );
  }

  /// Checks MESSAGE-INTEGRITY with [key] (RFC 5389 §15.4): HMAC-SHA1 over the
  /// message up to the attribute, with the header length rewritten as if the
  /// attribute were the last one (FINGERPRINT, if any, is excluded).
  bool verifyIntegrity(List<int> key) {
    final raw = _raw;
    if (raw == null || _integrityOffset < 0) return false;
    final covered = Uint8List.fromList(raw.sublist(0, _integrityOffset));
    ByteData.sublistView(covered)
        .setUint16(2, _integrityOffset + stunIntegrityLength - stunHeaderLength);
    final expected = hmacSha1(key, covered);
    final actual = raw.sublist(_integrityOffset + 4, _integrityOffset + 24);
    return constantTimeEquals(expected, actual);
  }

  /// Checks FINGERPRINT (RFC 5389 §15.5).
  bool verifyFingerprint() {
    final raw = _raw;
    if (raw == null || _fingerprintOffset < 0) return false;
    final expected = stunFingerprint(raw, _fingerprintOffset);
    final actual = ByteData.sublistView(raw).getUint32(_fingerprintOffset + 4);
    return expected == actual;
  }

  /// Serialises the message. Any MESSAGE-INTEGRITY / FINGERPRINT already in
  /// [attributes] is dropped; pass [integrityKey] / [fingerprint] to append
  /// freshly computed ones (integrity first, fingerprint last).
  Uint8List encode({List<int>? integrityKey, bool fingerprint = false}) {
    var size = stunHeaderLength;
    final body = <StunAttribute>[
      for (final a in attributes)
        if (a.type != StunAttr.messageIntegrity && a.type != StunAttr.fingerprint)
          a,
    ];
    for (final a in body) {
      size += 4 + ((a.value.length + 3) & ~3);
    }
    final total = size +
        (integrityKey != null ? stunIntegrityLength : 0) +
        (fingerprint ? stunFingerprintLength : 0);

    final out = Uint8List(total);
    final view = ByteData.sublistView(out);
    view.setUint16(0, type);
    view.setUint32(4, stunMagicCookie);
    out.setRange(8, 20, transactionId);

    var offset = stunHeaderLength;
    for (final a in body) {
      view.setUint16(offset, a.type);
      view.setUint16(offset + 2, a.value.length);
      out.setRange(offset + 4, offset + 4 + a.value.length, a.value);
      offset += 4 + ((a.value.length + 3) & ~3);
    }

    if (integrityKey != null) {
      view.setUint16(2, offset + stunIntegrityLength - stunHeaderLength);
      final mac = hmacSha1(integrityKey, Uint8List.sublistView(out, 0, offset));
      view.setUint16(offset, StunAttr.messageIntegrity);
      view.setUint16(offset + 2, 20);
      out.setRange(offset + 4, offset + 24, mac);
      offset += stunIntegrityLength;
    }

    if (fingerprint) {
      view.setUint16(2, offset + stunFingerprintLength - stunHeaderLength);
      view.setUint16(offset, StunAttr.fingerprint);
      view.setUint16(offset + 2, 4);
      view.setUint32(offset + 4, stunFingerprint(out, offset));
      offset += stunFingerprintLength;
    }

    view.setUint16(2, offset - stunHeaderLength);
    return out;
  }
}

StunAddress? decodeXorAddress(Uint8List value, Uint8List transactionId) {
  if (value.length < 8) return null;
  final family = value[1];
  final length = family == 0x01
      ? 4
      : family == 0x02
          ? 16
          : -1;
  if (length < 0 || value.length < 4 + length) return null;
  final port =
      ByteData.sublistView(value).getUint16(2) ^ (stunMagicCookie >>> 16);
  final mask = _xorMask(transactionId);
  final raw = Uint8List(length);
  for (var i = 0; i < length; i++) {
    raw[i] = value[4 + i] ^ mask[i];
  }
  return StunAddress(
    InternetAddress.fromRawAddress(
      raw,
      type: length == 4 ? InternetAddressType.IPv4 : InternetAddressType.IPv6,
    ),
    port,
  );
}

/// ChannelData framing (RFC 5766 §11.4): channel numbers 0x4000-0x7FFF.
abstract final class ChannelData {
  static const int minChannel = 0x4000;
  static const int maxChannel = 0x7FFE;

  static bool looksLikeChannelData(Uint8List data) =>
      data.length >= 4 && (data[0] & 0xC0) == 0x40;

  static Uint8List encode(int channel, Uint8List payload, {bool pad = false}) {
    final padded = pad ? (payload.length + 3) & ~3 : payload.length;
    final out = Uint8List(4 + padded);
    final view = ByteData.sublistView(out);
    view.setUint16(0, channel);
    view.setUint16(2, payload.length);
    out.setRange(4, 4 + payload.length, payload);
    return out;
  }

  /// (channel, payload) or null when truncated.
  static ({int channel, Uint8List payload})? parse(Uint8List data) {
    if (!looksLikeChannelData(data)) return null;
    final view = ByteData.sublistView(data);
    final length = view.getUint16(2);
    if (4 + length > data.length) return null;
    return (
      channel: view.getUint16(0),
      payload: Uint8List.sublistView(data, 4, 4 + length),
    );
  }
}
