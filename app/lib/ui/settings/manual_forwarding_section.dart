import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/settings.dart';
import '../../l10n/strings.dart';
import '../../net/connectivity/connectivity.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/rows.dart';

/// The router instructions for the current manual forwarding settings:
/// "On the router, forward TCP p1 -> ip:47100, UDP p2 -> ip:47100, TCP p3 ->
/// ip:47101." [lanIp] is this computer's LAN address, or null when unknown.
String manualForwardingInstructions(S s, AppSettings settings, String? lanIp) {
  return s.t('settings.manual.instructions', {
    'p1': '${settings.manualSignalingPort}',
    'p2': '${settings.manualTurnUdpPort}',
    'p3': '${settings.manualTurnTcpPort}',
    'ip': lanIp ?? s.t('settings.manual.lanIp'),
  });
}

/// Settings -> Connectivity: manual port forwarding for routers without UPnP
/// (toggle, optional public host, the three router ports, copyable
/// instructions). The values reach `Connectivity.setManualForwarding` through
/// the session manager whenever they change.
class ManualForwardingSection extends StatelessWidget {
  const ManualForwardingSection({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final st = context.watch<AppSettings>();
    final connectivity = context.read<Connectivity>();
    return Column(
      children: [
        SwitchRow(
          key: const ValueKey('manual-fwd-switch'),
          icon: Icons.alt_route_rounded,
          title: s.t('settings.manual'),
          subtitle: s.t('settings.manual.hint'),
          value: st.manualForwardingEnabled,
          onChanged: st.setManualForwardingEnabled,
        ),
        if (st.manualForwardingEnabled)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.l),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _CommitField(
                  key: const ValueKey('manual-fwd-host'),
                  label: s.t('settings.manual.host'),
                  helper: s.t('settings.manual.host.hint'),
                  initial: st.manualForwardHost,
                  keyboardType: TextInputType.url,
                  validate: (v) =>
                      v.isEmpty || AppSettings.isValidForwardHost(v) ? null : s.t('settings.manual.badHost'),
                  onCommit: (v) => st.setManualForwardingDetails(host: v),
                ),
                const SizedBox(height: Gap.m),
                Wrap(
                  spacing: Gap.m,
                  runSpacing: Gap.m,
                  children: [
                    _portField(
                      s,
                      'manual-fwd-tcp',
                      s.t('settings.manual.portSignaling'),
                      st.manualSignalingPort,
                      (p) => st.setManualForwardingDetails(signalingTcp: p),
                    ),
                    _portField(
                      s,
                      'manual-fwd-udp',
                      s.t('settings.manual.portUdp'),
                      st.manualTurnUdpPort,
                      (p) => st.setManualForwardingDetails(turnUdp: p),
                    ),
                    _portField(
                      s,
                      'manual-fwd-turn-tcp',
                      s.t('settings.manual.portTcp'),
                      st.manualTurnTcpPort,
                      (p) => st.setManualForwardingDetails(turnTcp: p),
                    ),
                  ],
                ),
                const SizedBox(height: Gap.l),
                ValueListenableBuilder<ReachabilityReport>(
                  valueListenable: connectivity.report,
                  builder: (context, report, _) {
                    final text = manualForwardingInstructions(
                      s,
                      st,
                      report.lanIPv4.isEmpty ? null : report.lanIPv4.first,
                    );
                    return Container(
                      padding: const EdgeInsets.fromLTRB(Gap.m, Gap.s, Gap.xs, Gap.s),
                      decoration: BoxDecoration(
                        color: context.c.inset,
                        borderRadius: BorderRadius.circular(Radii.control),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(top: Gap.xs),
                              child: SelectableText(text, key: const ValueKey('manual-fwd-instructions')),
                            ),
                          ),
                          IconButton(
                            key: const ValueKey('manual-fwd-copy'),
                            tooltip: s.t('settings.manual.copy'),
                            icon: const Icon(Icons.copy_rounded),
                            onPressed: () => copyToClipboard(context, text, s.t('settings.manual.noun')),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _portField(S s, String key, String label, int value, Future<void> Function(int) save) {
    return SizedBox(
      width: 200,
      child: _CommitField(
        key: ValueKey(key),
        label: label,
        initial: '$value',
        keyboardType: TextInputType.number,
        digitsOnly: true,
        validate: (v) => AppSettings.isValidPort(int.tryParse(v)) ? null : s.t('settings.manual.badPort'),
        onCommit: (v) => save(int.parse(v)),
      ),
    );
  }
}

/// A text field that saves when it loses focus or Enter is pressed (and only
/// when the value is valid), so half-typed ports never reach the router
/// settings.
class _CommitField extends StatefulWidget {
  const _CommitField({
    super.key,
    required this.label,
    required this.initial,
    required this.validate,
    required this.onCommit,
    this.helper,
    this.keyboardType,
    this.digitsOnly = false,
  });

  final String label;
  final String? helper;
  final String initial;
  final TextInputType? keyboardType;
  final bool digitsOnly;

  /// Returns an error text, or null when the value is acceptable.
  final String? Function(String value) validate;
  final void Function(String value) onCommit;

  @override
  State<_CommitField> createState() => _CommitFieldState();
}

class _CommitFieldState extends State<_CommitField> {
  late final TextEditingController _controller = TextEditingController(text: widget.initial);
  late final FocusNode _focus = FocusNode()..addListener(_onFocus);
  String? _error;

  void _onFocus() {
    if (!_focus.hasFocus) _commit();
  }

  void _commit() {
    final v = _controller.text.trim();
    final err = widget.validate(v);
    setState(() => _error = err);
    if (err == null) widget.onCommit(v);
  }

  @override
  void didUpdateWidget(_CommitField old) {
    super.didUpdateWidget(old);
    if (old.initial != widget.initial && !_focus.hasFocus && _controller.text.trim() != widget.initial) {
      _controller.text = widget.initial;
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: _focus,
      keyboardType: widget.keyboardType,
      inputFormatters: [
        if (widget.digitsOnly) FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(widget.digitsOnly ? 5 : 253),
      ],
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: widget.label,
        helperText: widget.helper,
        helperMaxLines: 2,
        errorText: _error,
      ),
      onSubmitted: (_) => _commit(),
    );
  }
}
