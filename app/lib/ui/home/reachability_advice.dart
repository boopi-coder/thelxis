import '../../l10n/strings.dart';
import '../../net/connectivity/connectivity.dart';
import '../widgets/common.dart';

/// The situations the reachability advice distinguishes, best to worst.
enum ReachKind {
  /// Incoming connections are switched off in Settings.
  off,

  /// The signaling port could not be opened (port in use / firewall).
  portInUse,

  /// A public address that is on this machine itself (VPS, bridged modem).
  direct,

  /// A router mapping from UPnP / NAT-PMP / PCP.
  mapped,

  /// The user forwarded the ports by hand.
  manual,

  /// Only a global IPv6 address.
  ipv6,

  /// The router's own address is a shared provider address (carrier-grade NAT).
  cgnat,

  /// The router's WAN address is private: another router sits in front of it.
  doubleNat,

  /// A UPnP/NAT-PMP/PCP router answered but no mapping exists.
  mappingFailed,

  /// Automatic port mapping is switched off in Settings.
  mappingOff,

  /// Only the local network: no router that can open ports was found.
  noRouter,
}

/// What the user can do about it, as buttons next to the advice.
enum AdviceAction { enableIncoming, enableMapping, manualForwarding, reverseConnection, rescan }

/// Plain-language status for the current [ReachabilityReport] and the next
/// steps for the user. Texts are short on purpose: a title, one sentence,
/// at most three steps.
class ReachAdvice {
  const ReachAdvice(this.kind, {this.method});

  final ReachKind kind;

  /// "UPnP" / "NAT-PMP" / "PCP" for [ReachKind.mapped].
  final String? method;

  /// A peer on the internet can most likely connect.
  bool get reachable => switch (kind) {
        ReachKind.direct || ReachKind.mapped || ReachKind.manual || ReachKind.ipv6 => true,
        _ => false,
      };

  PillTone get tone => switch (kind) {
        ReachKind.off => PillTone.neutral,
        ReachKind.portInUse => PillTone.bad,
        _ => reachable ? PillTone.good : PillTone.warn,
      };

  List<AdviceAction> get actions => switch (kind) {
        ReachKind.off => const [AdviceAction.enableIncoming],
        ReachKind.portInUse => const [AdviceAction.rescan],
        ReachKind.cgnat => const [AdviceAction.reverseConnection],
        ReachKind.doubleNat => const [AdviceAction.manualForwarding, AdviceAction.reverseConnection],
        ReachKind.mappingFailed => const [AdviceAction.manualForwarding, AdviceAction.rescan],
        ReachKind.mappingOff => const [AdviceAction.enableMapping, AdviceAction.manualForwarding],
        ReachKind.noRouter => const [
            AdviceAction.manualForwarding,
            AdviceAction.reverseConnection,
            AdviceAction.rescan,
          ],
        _ => const [],
      };

  /// Pill text on Home.
  String label(S s) => switch (kind) {
        ReachKind.off => s.t('reach.off'),
        ReachKind.portInUse => s.t('reach.noListener'),
        ReachKind.direct || ReachKind.mapped || ReachKind.manual || ReachKind.ipv6 => s.t('reach.internet'),
        _ => s.t('reach.lan'),
      };

  String title(S s) => switch (kind) {
        ReachKind.off => s.t('reach.off.title'),
        ReachKind.portInUse => s.t('reach.portInUse.title'),
        ReachKind.direct => s.t('reach.direct.title'),
        ReachKind.mapped => s.t('reach.mapped.title', {'method': method ?? 'UPnP'}),
        ReachKind.manual => s.t('reach.manual.title'),
        ReachKind.ipv6 => s.t('reach.ipv6.title'),
        ReachKind.cgnat => s.t('reach.cgnat.title'),
        ReachKind.doubleNat => s.t('reach.doubleNat.title'),
        ReachKind.mappingFailed => s.t('reach.mappingFailed.title'),
        ReachKind.mappingOff => s.t('reach.mappingOff.title'),
        ReachKind.noRouter => s.t('reach.noRouter.title'),
      };

  /// One friendly sentence.
  String body(S s) => switch (kind) {
        ReachKind.off => s.t('reach.off.body'),
        ReachKind.portInUse => s.t('reach.portInUse.body'),
        ReachKind.direct => s.t('reach.direct.body'),
        ReachKind.mapped => s.t('reach.mapped.body'),
        ReachKind.manual => s.t('reach.manual.body'),
        ReachKind.ipv6 => s.t('reach.ipv6.body'),
        ReachKind.cgnat => s.t('reach.cgnat.body'),
        ReachKind.doubleNat => s.t('reach.doubleNat.body'),
        ReachKind.mappingFailed => s.t('reach.mappingFailed.body'),
        ReachKind.mappingOff => s.t('reach.mappingOff.body'),
        ReachKind.noRouter => s.t('reach.noRouter.body'),
      };

  /// Concrete things to try, one per entry (empty when nothing is wrong).
  List<String> steps(S s) {
    final raw = switch (kind) {
      ReachKind.portInUse => s.t('reach.portInUse.steps'),
      ReachKind.cgnat => s.t('reach.cgnat.steps'),
      ReachKind.doubleNat => s.t('reach.doubleNat.steps'),
      ReachKind.mappingFailed => s.t('reach.mappingFailed.steps'),
      ReachKind.mappingOff => s.t('reach.mappingOff.steps'),
      ReachKind.noRouter => s.t('reach.noRouter.steps'),
      ReachKind.ipv6 => s.t('reach.ipv6.steps'),
      ReachKind.manual => s.t('reach.manual.steps'),
      _ => '',
    };
    return raw.isEmpty ? const [] : raw.split('\n');
  }

  /// The one-line hint under the pill on Home; null when nothing needs doing.
  String? hint(S s) => switch (kind) {
        ReachKind.portInUse => s.t('reach.portInUse.hint'),
        ReachKind.cgnat => s.t('reach.cgnat.hint'),
        ReachKind.doubleNat => s.t('reach.doubleNat.hint'),
        ReachKind.mappingFailed => s.t('reach.mappingFailed.hint'),
        ReachKind.mappingOff => s.t('reach.mappingOff.hint'),
        ReachKind.noRouter => s.t('reach.noRouter.hint'),
        _ => null,
      };
}

/// Picks the situation. [upnpEnabled] is the "Automatic port mapping" setting.
ReachAdvice adviseReachability({
  required bool allowIncoming,
  required ReachabilityReport report,
  bool upnpEnabled = true,
}) {
  if (!allowIncoming) return const ReachAdvice(ReachKind.off);
  if (!report.listening) return const ReachAdvice(ReachKind.portInUse);
  if (report.manualForwarding) return const ReachAdvice(ReachKind.manual);
  if (report.reachableIPv4) {
    if (report.externalIsDirect) return const ReachAdvice(ReachKind.direct);
    return ReachAdvice(ReachKind.mapped, method: _methodName(report.mappingMethod));
  }
  if (report.reachableIPv6) return const ReachAdvice(ReachKind.ipv6);
  if (report.cgnat) {
    return ReachAdvice(_isPrivateRfc1918(report.externalIPv4) ? ReachKind.doubleNat : ReachKind.cgnat);
  }
  if (report.gatewayFound) return const ReachAdvice(ReachKind.mappingFailed);
  if (!upnpEnabled) return const ReachAdvice(ReachKind.mappingOff);
  return const ReachAdvice(ReachKind.noRouter);
}

String? _methodName(MappingMethod? m) => switch (m) {
      MappingMethod.upnp => 'UPnP',
      MappingMethod.natPmp => 'NAT-PMP',
      MappingMethod.pcp => 'PCP',
      null => null,
    };

/// 10/8, 172.16/12, 192.168/16: a router behind another router. The shared
/// 100.64/10 range (and an unknown address) is the provider's CGNAT instead.
bool _isPrivateRfc1918(String? ip) {
  if (ip == null) return false;
  final p = ip.split('.');
  if (p.length != 4) return false;
  final a = int.tryParse(p[0]);
  final b = int.tryParse(p[1]);
  if (a == null || b == null) return false;
  return a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168);
}
