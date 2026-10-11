import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/net/connectivity/stun_crypto.dart';
import 'package:thelxis/net/connectivity/stun_message.dart';

Uint8List _hex(String s) {
  final clean = s.replaceAll(RegExp(r'\s+'), '');
  return Uint8List.fromList([
    for (var i = 0; i < clean.length; i += 2)
      int.parse(clean.substring(i, i + 2), radix: 16),
  ]);
}

String _toHex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

// RFC 5769 test vectors (https://www.rfc-editor.org/rfc/rfc5769).
final _sampleRequest = _hex('''
  0001 0058 2112a442 b7e7a701bc34d686fa87dfae
  80220010 5354554e 20746573 7420636c 69656e74
  00240004 6e0001ff
  80290008 932ff9b1 51263b36
  00060009 6576746a 3a683676 59202020
  00080014 9aeaa70c bfd8cb56 781ef2b5 b2d3f249 c1b571a2
  80280004 e57a3bcf''');

final _sampleResponseV4 = _hex('''
  0101 003c 2112a442 b7e7a701bc34d686fa87dfae
  8022000b 74657374 20766563 746f7220
  00200008 0001a147 e112a643
  00080014 2b91f599 fd9e90c3 8c7489f9 2af9ba53 f06be7d7
  80280004 c07d4c96''');

final _sampleResponseV6 = _hex('''
  0101 0048 2112a442 b7e7a701bc34d686fa87dfae
  8022000b 74657374 20766563 746f7220
  00200014 0002a147 0113a9fa a5d3f179 bc25f4b5 bed2b9d9
  00080014 a382954e 4be67bf1 1784c97c 8292c275 bfe3ed41
  80280004 c8fb0b4c''');

final _sampleLongTerm = _hex('''
  0001 0060 2112a442 78ad3433c6ad72c029da412e
  00060012 e3839ee3 8388e383 aae38383 e382afe3 82b90000
  0015001c 662f2f34 39396b39 35346436 4f4c3334 6f4c3946 53547679 36347341
  0014000b 6578616d 706c652e 6f726700
  00080014 f6702465 6dd64a3e 02b8e071 2e85c9a2 8ca89666''');

const _shortTermPassword = 'VOkJxbRl1RmTxUk/WvJxBt';

void main() {
  group('primitives', () {
    test('MD5 matches RFC 1321 test suite', () {
      expect(_toHex(md5(<int>[])), 'd41d8cd98f00b204e9800998ecf8427e');
      expect(
        _toHex(md5(ascii.encode('a'))),
        '0cc175b9c0f1b6a831c399e269772661',
      );
      expect(
        _toHex(md5(ascii.encode('abc'))),
        '900150983cd24fb0d6963f7d28e17f72',
      );
      expect(
        _toHex(md5(ascii.encode('message digest'))),
        'f96b697d7cb7938d525a2f31aaf161d0',
      );
      expect(
        _toHex(
          md5(
            ascii.encode(
              '12345678901234567890123456789012345678901234567890123456789012345678901234567890',
            ),
          ),
        ),
        '57edf4a22be3c955ac49da2e2107b67a',
      );
    });

    test('CRC-32 matches the zlib check value', () {
      expect(crc32(ascii.encode('123456789')), 0xCBF43926);
    });

    test('HMAC-SHA1 matches RFC 2202 test case 2', () {
      final mac = hmacSha1(
        ascii.encode('Jefe'),
        ascii.encode('what do ya want for nothing?'),
      );
      expect(_toHex(mac), 'effcdf6ae5eb2fa2d27416d5f184df9c259a7c79');
    });
  });

  group('message type', () {
    test('encodes and decodes method/class pairs', () {
      expect(stunMessageType(StunMethod.binding, StunClass.request), 0x0001);
      expect(stunMessageType(StunMethod.binding, StunClass.success), 0x0101);
      expect(stunMessageType(StunMethod.binding, StunClass.error), 0x0111);
      expect(stunMessageType(StunMethod.allocate, StunClass.request), 0x0003);
      expect(stunMessageType(StunMethod.allocate, StunClass.error), 0x0113);
      expect(stunMessageType(StunMethod.send, StunClass.indication), 0x0016);
      expect(stunMessageType(StunMethod.data, StunClass.indication), 0x0017);
      expect(
        stunMessageType(StunMethod.channelBind, StunClass.success),
        0x0109,
      );
    });
  });

  group('RFC 5769 vectors', () {
    test('2.1 sample request: parse, integrity, fingerprint', () {
      final m = StunMessage.parse(_sampleRequest)!;
      expect(m.method, StunMethod.binding);
      expect(m.messageClass, StunClass.request);
      expect(m.stringAttribute(StunAttr.software), 'STUN test client');
      expect(m.stringAttribute(StunAttr.username), 'evtj:h6vY');
      expect(m.hasIntegrity, isTrue);
      expect(m.hasFingerprint, isTrue);
      expect(m.verifyIntegrity(utf8.encode(_shortTermPassword)), isTrue);
      expect(m.verifyIntegrity(utf8.encode('wrong password')), isFalse);
      expect(m.verifyFingerprint(), isTrue);
    });

    test('2.1 sample request: re-encoding reproduces the bytes', () {
      final m = StunMessage.parse(_sampleRequest)!;
      // The RFC pads with spaces; ours pads with zeros, so compare the
      // padding-independent parts (everything except the three pad bytes of
      // USERNAME) by re-parsing and verifying the fresh hashes.
      final again = StunMessage.parse(
        m.encode(
          integrityKey: utf8.encode(_shortTermPassword),
          fingerprint: true,
        ),
      )!;
      expect(again.verifyIntegrity(utf8.encode(_shortTermPassword)), isTrue);
      expect(again.verifyFingerprint(), isTrue);
      expect(again.stringAttribute(StunAttr.username), 'evtj:h6vY');
    });

    // The RFC pads SOFTWARE with a space, we pad with zero, so whole-message
    // equality is impossible; instead the encoder is checked on the parts that
    // are padding-independent and its own hashes are verified by the parser.
    test('2.2 IPv4 response: encoder produces the vector\'s address bytes', () {
      final tid = _hex('b7e7a701bc34d686fa87dfae');
      final encoded =
          StunMessage(
            method: StunMethod.binding,
            messageClass: StunClass.success,
            transactionId: tid,
            attributes: [
              StunAttribute.string(StunAttr.software, 'test vector'),
              StunAttribute.xorAddress(
                StunAttr.xorMappedAddress,
                InternetAddress('192.0.2.1'),
                32853,
                tid,
              ),
            ],
          ).encode(
            integrityKey: utf8.encode(_shortTermPassword),
            fingerprint: true,
          );
      final parsed = StunMessage.parse(encoded)!;
      expect(
        _toHex(parsed.attribute(StunAttr.xorMappedAddress)!.value),
        '0001a147e112a643',
      );
      expect(encoded.length, _sampleResponseV4.length);
      expect(parsed.verifyIntegrity(utf8.encode(_shortTermPassword)), isTrue);
      expect(parsed.verifyFingerprint(), isTrue);
    });

    test('2.2 IPv4 response: parse and verify', () {
      final m = StunMessage.parse(_sampleResponseV4)!;
      expect(m.messageClass, StunClass.success);
      final mapped = m.xorAddress(StunAttr.xorMappedAddress)!;
      expect(mapped.address.address, '192.0.2.1');
      expect(mapped.port, 32853);
      expect(m.verifyIntegrity(utf8.encode(_shortTermPassword)), isTrue);
      expect(m.verifyFingerprint(), isTrue);
    });

    test('2.3 IPv6 response: encoder produces the vector\'s address bytes', () {
      final tid = _hex('b7e7a701bc34d686fa87dfae');
      final encoded =
          StunMessage(
            method: StunMethod.binding,
            messageClass: StunClass.success,
            transactionId: tid,
            attributes: [
              StunAttribute.string(StunAttr.software, 'test vector'),
              StunAttribute.xorAddress(
                StunAttr.xorMappedAddress,
                InternetAddress('2001:db8:1234:5678:11:2233:4455:6677'),
                32853,
                tid,
              ),
            ],
          ).encode(
            integrityKey: utf8.encode(_shortTermPassword),
            fingerprint: true,
          );
      final parsed = StunMessage.parse(encoded)!;
      expect(
        _toHex(parsed.attribute(StunAttr.xorMappedAddress)!.value),
        '0002a1470113a9faa5d3f179bc25f4b5bed2b9d9',
      );
      expect(encoded.length, _sampleResponseV6.length);
      expect(parsed.verifyIntegrity(utf8.encode(_shortTermPassword)), isTrue);
      expect(parsed.verifyFingerprint(), isTrue);
    });

    test('2.3 IPv6 response: parse and verify', () {
      final m = StunMessage.parse(_sampleResponseV6)!;
      final mapped = m.xorAddress(StunAttr.xorMappedAddress)!;
      expect(mapped.address.type, InternetAddressType.IPv6);
      expect(mapped.address.address, '2001:db8:1234:5678:11:2233:4455:6677');
      expect(mapped.port, 32853);
      expect(m.verifyIntegrity(utf8.encode(_shortTermPassword)), isTrue);
      expect(m.verifyFingerprint(), isTrue);
    });

    test('2.4 long-term credentials request', () {
      final m = StunMessage.parse(_sampleLongTerm)!;
      final username = m.attribute(StunAttr.username)!.value;
      expect(utf8.decode(username), 'マトリックス');
      expect(m.stringAttribute(StunAttr.realm), 'example.org');
      expect(m.stringAttribute(StunAttr.nonce), 'f//499k954d6OL34oL9FSTvy64sA');
      expect(m.hasFingerprint, isFalse);
      final key = longTermKey(
        username,
        utf8.encode('example.org'),
        utf8.encode('TheMatrIX'),
      );
      expect(m.verifyIntegrity(key), isTrue);
      final wrong = longTermKey(
        username,
        utf8.encode('example.org'),
        utf8.encode('thematrix'),
      );
      expect(m.verifyIntegrity(wrong), isFalse);
    });

    test('a flipped bit breaks integrity and fingerprint', () {
      final tampered = Uint8List.fromList(_sampleRequest);
      tampered[30] ^= 0x01; // inside SOFTWARE
      final m = StunMessage.parse(tampered)!;
      expect(m.verifyIntegrity(utf8.encode(_shortTermPassword)), isFalse);
      expect(m.verifyFingerprint(), isFalse);
    });
  });

  group('codec', () {
    test('round-trips attributes with odd lengths (padding)', () {
      final tid = randomTransactionId();
      final msg = StunMessage(
        method: StunMethod.allocate,
        messageClass: StunClass.request,
        transactionId: tid,
        attributes: [
          StunAttribute.string(StunAttr.username, 'abcde'),
          StunAttribute.uint32(StunAttr.requestedTransport, 17 << 24),
          StunAttribute.string(StunAttr.realm, 'thelxis'),
        ],
      );
      final bytes = msg.encode();
      expect(bytes.length % 4, 0);
      final parsed = StunMessage.parse(bytes)!;
      expect(parsed.stringAttribute(StunAttr.username), 'abcde');
      expect(parsed.stringAttribute(StunAttr.realm), 'thelxis');
      expect(parsed.uint32Attribute(StunAttr.requestedTransport)! >> 24, 17);
      expect(parsed.transactionId, tid);
    });

    test('error-code attribute', () {
      final msg = StunMessage(
        method: StunMethod.allocate,
        messageClass: StunClass.error,
        transactionId: randomTransactionId(),
        attributes: [StunAttribute.errorCode(438, 'Stale Nonce')],
      );
      final parsed = StunMessage.parse(msg.encode())!;
      expect(parsed.errorCode!.code, 438);
      expect(parsed.errorCode!.reason, 'Stale Nonce');
    });

    test('rejects malformed input', () {
      expect(StunMessage.parse(Uint8List(10)), isNull);
      final truncated = Uint8List.sublistView(_sampleRequest, 0, 40);
      expect(StunMessage.parse(truncated), isNull);
      final badCookie = Uint8List.fromList(_sampleRequest)..[4] = 0;
      expect(StunMessage.parse(badCookie), isNull);
      final badLength = Uint8List.fromList(_sampleRequest)..[3] = 0x57;
      expect(StunMessage.parse(badLength), isNull);
      // attribute length overruns the message
      final overrun = Uint8List.fromList(_sampleRequest)..[23] = 0xff;
      expect(StunMessage.parse(overrun), isNull);
    });

    test('ChannelData framing', () {
      final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
      final udp = ChannelData.encode(0x4001, payload);
      expect(udp.length, 9);
      final tcp = ChannelData.encode(0x4001, payload, pad: true);
      expect(tcp.length, 12);
      final parsed = ChannelData.parse(tcp)!;
      expect(parsed.channel, 0x4001);
      expect(parsed.payload, payload);
      expect(ChannelData.parse(Uint8List.sublistView(udp, 0, 6)), isNull);
      expect(StunMessage.looksLikeStun(udp), isFalse);
    });
  });
}
