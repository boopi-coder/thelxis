import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/session/link_stats.dart';

StatEntry _e(String id, String type, Map<String, Object?> v) => StatEntry(id, type, v);

List<StatEntry> _sample({
  required num bytes,
  required num frames,
  required num lost,
  required num packets,
  String localType = 'host',
  String remoteType = 'host',
  String localAddr = '192.168.1.5',
  String remoteAddr = '192.168.1.9',
  Object? rtt = 0.024,
}) =>
    [
      _e('RTCInboundRTPVideoStream_1', 'inbound-rtp', {
        'kind': 'video',
        'bytesReceived': bytes,
        'framesDecoded': frames,
        'packetsLost': lost,
        'packetsReceived': packets,
        'frameWidth': 1920,
        'frameHeight': 1080,
        'codecId': 'RTCCodec_VP8',
      }),
      _e('RTCCodec_VP8', 'codec', {'mimeType': 'video/VP8'}),
      _e('T01', 'transport', {'selectedCandidatePairId': 'CP1'}),
      _e('CP1', 'candidate-pair', {
        'state': 'succeeded',
        'nominated': true,
        'localCandidateId': 'L1',
        'remoteCandidateId': 'R1',
        'currentRoundTripTime': rtt,
      }),
      _e('L1', 'local-candidate', {'candidateType': localType, 'address': localAddr}),
      _e('R1', 'remote-candidate', {'candidateType': remoteType, 'address': remoteAddr}),
    ];

void main() {
  test('rates come from counter deltas between samples', () {
    final s = StatsSampler();
    final first = s.update(_sample(bytes: 1000000, frames: 100, lost: 0, packets: 1000), nowMs: 0);
    expect(first.bitrateBps, isNull, reason: 'a rate needs two samples');
    final second = s.update(_sample(bytes: 1250000, frames: 130, lost: 5, packets: 1195), nowMs: 1000);
    expect(second.bitrateBps, closeTo(2000000, 1)); // 250 kB in 1 s = 2 Mbps
    expect(second.fps, closeTo(30, 1e-9));
    expect(second.lossPercent, closeTo(5 / 200 * 100, 1e-9));
    expect(second.rttMs, closeTo(24, 1e-9));
    expect(second.width, 1920);
    expect(second.height, 1080);
    expect(second.codec, 'VP8');
  });

  test('RTT given as a string (some platforms) is parsed', () {
    final s = StatsSampler();
    final r = s.update(_sample(bytes: 1, frames: 1, lost: 0, packets: 1, rtt: '0.150'), nowMs: 0);
    expect(r.rttMs, closeTo(150, 1e-9));
  });

  group('path classification', () {
    LinkPath path({
      String lt = 'host',
      String rt = 'host',
      String la = '192.168.1.5',
      String ra = '192.168.1.9',
    }) =>
        StatsSampler()
            .update(_sample(bytes: 1, frames: 1, lost: 0, packets: 1, localType: lt, remoteType: rt, localAddr: la, remoteAddr: ra), nowMs: 0)
            .path;

    test('two private addresses are LAN', () => expect(path(), LinkPath.lan));
    test('public IPv4 is direct', () => expect(path(la: '203.0.113.5', ra: '198.51.100.7', lt: 'srflx', rt: 'srflx'), LinkPath.direct));
    test('IPv6 is labelled IPv6', () => expect(path(la: '2001:db8::1', ra: '2001:db8::2'), LinkPath.ipv6));
    test('a relay candidate on either side means via host TURN', () {
      expect(path(lt: 'relay', la: '203.0.113.5', ra: '198.51.100.7'), LinkPath.relay);
      expect(path(rt: 'relay', la: '203.0.113.5', ra: '198.51.100.7'), LinkPath.relay);
    });
    test('labels', () {
      expect(const LinkStats(path: LinkPath.relay).pathLabel, 'Via host TURN');
      expect(const LinkStats(path: LinkPath.lan).pathLabel, 'LAN');
      expect(const LinkStats().pathLabel, '—');
    });
  });

  test('falls back to outbound-rtp (host side) and remote-inbound RTT', () {
    final s = StatsSampler();
    List<StatEntry> sample(num bytes, num frames) => [
          _e('O1', 'outbound-rtp', {'kind': 'video', 'bytesSent': bytes, 'framesEncoded': frames, 'frameWidth': 2560, 'frameHeight': 1440}),
          _e('RI1', 'remote-inbound-rtp', {'roundTripTime': 0.04}),
        ];
    s.update(sample(0, 0), nowMs: 0);
    final r = s.update(sample(500000, 60), nowMs: 2000);
    expect(r.bitrateBps, closeTo(2000000, 1));
    expect(r.fps, closeTo(30, 1e-9));
    expect(r.rttMs, closeTo(40, 1e-9));
    expect(r.width, 2560);
  });

  test('empty report is harmless', () {
    final r = StatsSampler().update(const [], nowMs: 0);
    expect(r.rttMs, isNull);
    expect(r.path, LinkPath.unknown);
  });

  test('private address helper', () {
    for (final a in ['10.0.0.1', '172.16.5.5', '172.31.255.1', '192.168.0.9', '127.0.0.1', '169.254.1.1', 'fe80::1', 'fd12::1']) {
      expect(isPrivateAddress(a), isTrue, reason: a);
    }
    for (final a in ['172.32.0.1', '8.8.8.8', '203.0.113.5', '2001:db8::1', 'garbage']) {
      expect(isPrivateAddress(a), isFalse, reason: a);
    }
  });
}
