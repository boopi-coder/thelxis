import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/core/base64url.dart';
import 'package:thelxis/core/one_time_password.dart';
import 'package:thelxis/core/password_proof.dart';
import 'package:thelxis/core/sdp_fingerprint.dart';

// Vector computed independently with Python:
//   hashlib.pbkdf2_hmac('sha256', b'k7m2p9xq', b'thelxis-pw-v1:0123456789ABCDEF', 60000, 32)
//   hmac.new(key, b'thelxis-auth-v1|bm9uY2U|sha-256 AA:BB|sha-256 CC:DD', sha256)
const _password = 'k7m2p9xq';
const _hostId = '0123456789ABCDEF';
const _nonce = 'bm9uY2U';
const _fpA = 'sha-256 AA:BB';
const _fpB = 'sha-256 CC:DD';
const _keyHex = 'baedd447847f1997dbd82b30e667f0363d4dacb8730f43f58d302975f4018f1a';
const _proofHex = 'cbc37a05cb5985e13111f802677d958fc1602685e6e1ea262bfbcf7d36602173';
const _proofB64u = 'y8N6BctZheExEfgCZ32Vj8FgJoXm4eomK_vPfTZgIXM';

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('password proof', () {
    test('PBKDF2 key matches the Python vector', () async {
      final key = await derivePasswordKeySync(_password, _hostId);
      expect(_hex(key), _keyHex);
    });

    test('PBKDF2 on a worker isolate gives the same key', () async {
      final key = await derivePasswordKey(_password, _hostId);
      expect(_hex(key), _keyHex);
    });

    test('proof matches the Python vector and is order independent', () async {
      final key = <int>[
        for (var i = 0; i < _keyHex.length; i += 2)
          int.parse(_keyHex.substring(i, i + 2), radix: 16),
      ];
      final proof = await computePasswordProof(
        key: key,
        nonce: _nonce,
        fingerprintA: _fpA,
        fingerprintB: _fpB,
      );
      expect(_hex(proof), _proofHex);
      final swapped = await computePasswordProofB64(
        key: key,
        nonce: _nonce,
        fingerprintA: _fpB,
        fingerprintB: _fpA,
      );
      expect(swapped, _proofB64u);
    });

    test('verify accepts the right proof and rejects tampering', () async {
      final key = await derivePasswordKeySync(_password, _hostId);
      expect(
        await verifyPasswordProof(
          key: key,
          nonce: _nonce,
          fingerprintA: _fpA,
          fingerprintB: _fpB,
          proof: _proofB64u,
        ),
        isTrue,
      );
      expect(
        await verifyPasswordProof(
          key: key,
          nonce: 'other',
          fingerprintA: _fpA,
          fingerprintB: _fpB,
          proof: _proofB64u,
        ),
        isFalse,
      );
      expect(
        await verifyPasswordProof(
          key: key,
          nonce: _nonce,
          fingerprintA: _fpA,
          fingerprintB: 'sha-256 EE:FF',
          proof: _proofB64u,
        ),
        isFalse,
      );
      expect(
        await verifyPasswordProof(
          key: key,
          nonce: _nonce,
          fingerprintA: _fpA,
          fingerprintB: _fpB,
          proof: '!!not-base64!!',
        ),
        isFalse,
      );
    });
  });

  group('sdp fingerprint', () {
    const sdp = 'v=0\r\n'
        'o=- 4611731400430051336 2 IN IP4 127.0.0.1\r\n'
        's=-\r\n'
        't=0 0\r\n'
        'a=group:BUNDLE 0 1\r\n'
        'm=video 9 UDP/TLS/RTP/SAVPF 96\r\n'
        'c=IN IP4 0.0.0.0\r\n'
        'a=ice-ufrag:abcd\r\n'
        'a=ice-pwd:0123456789012345678901\r\n'
        'a=fingerprint:sha-256 ab:cd:ef:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89\r\n'
        'a=setup:actpass\r\n'
        'a=mid:0\r\n'
        'a=sendonly\r\n'
        'm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n'
        'a=fingerprint:sha-256 ab:cd:ef:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89\r\n'
        'a=mid:1\r\n';

    test('extracts and normalises the sha-256 fingerprint', () {
      expect(
        extractDtlsFingerprint(sdp),
        'sha-256 AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89',
      );
    });

    test('works with LF-only line endings and prefers sha-256', () {
      final lf = 'a=fingerprint:sha-1 aa:bb\n'
          'a=fingerprint:SHA-256 cc:dd\n';
      expect(extractDtlsFingerprint(lf), 'sha-256 CC:DD');
    });

    test('returns null when absent or malformed', () {
      expect(extractDtlsFingerprint(null), isNull);
      expect(extractDtlsFingerprint(''), isNull);
      expect(extractDtlsFingerprint('v=0\r\ns=-\r\n'), isNull);
      expect(extractDtlsFingerprint('a=fingerprint:garbage\r\n'), isNull);
    });
  });

  group('one-time password', () {
    test('has the right length and alphabet', () {
      for (var i = 0; i < 200; i++) {
        final p = generateOneTimePassword();
        expect(p.length, 8);
        for (final c in p.split('')) {
          expect(kOneTimeAlphabet.contains(c), isTrue, reason: c);
        }
      }
    });

    test('alphabet excludes look-alike characters', () {
      for (final bad in ['i', 'l', 'o', '0', '1']) {
        expect(kOneTimeAlphabet.contains(bad), isFalse, reason: bad);
      }
    });

    test('two passwords differ', () {
      expect(generateOneTimePassword(), isNot(generateOneTimePassword()));
    });
  });

  group('base64url', () {
    test('round-trips without padding', () {
      for (var n = 0; n < 40; n++) {
        final bytes = List<int>.generate(n, (i) => (i * 37 + 11) & 0xff);
        final s = b64uEncode(bytes);
        expect(s.contains('='), isFalse);
        expect(b64uDecode(s), bytes);
      }
      expect(utf8.decode(b64uDecode('bm9uY2U')), 'nonce');
    });

    test('constantTimeEquals', () {
      expect(constantTimeEquals([1, 2, 3], [1, 2, 3]), isTrue);
      expect(constantTimeEquals([1, 2, 3], [1, 2, 4]), isFalse);
      expect(constantTimeEquals([1, 2], [1, 2, 3]), isFalse);
    });
  });
}
