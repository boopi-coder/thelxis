import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/address_book.dart';
import '../../net/connect_target.dart';
import '../../net/net_address.dart';
import '../widgets/common.dart';
import '../../l10n/strings.dart';

/// Edit alias, tags, notes and addresses of an address-book entry.
Future<void> showEditEntryDialog(BuildContext context, AddressBook book, AddressBookEntry entry) {
  return showDialog<void>(
    context: context,
    builder: (_) => _EditEntryDialog(book: book, entry: entry),
  );
}

class _EditEntryDialog extends StatefulWidget {
  const _EditEntryDialog({required this.book, required this.entry});

  final AddressBook book;
  final AddressBookEntry entry;

  @override
  State<_EditEntryDialog> createState() => _EditEntryDialogState();
}

class _EditEntryDialogState extends State<_EditEntryDialog> {
  late final alias = TextEditingController(text: widget.entry.alias);
  late final tags = TextEditingController(text: widget.entry.tags.join(', '));
  late final notes = TextEditingController(text: widget.entry.notes);
  late final addresses = TextEditingController(text: widget.entry.addresses.join('\n'));

  @override
  void dispose() {
    alias.dispose();
    tags.dispose();
    notes.dispose();
    addresses.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return AlertDialog(
      title: Text(s.t('edit.title', {'name': widget.entry.name})),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: alias,
                decoration: InputDecoration(labelText: s.t('edit.alias'), hintText: widget.entry.name),
              ),
              const SizedBox(height: 12),
              TextField(controller: tags, decoration: InputDecoration(labelText: s.t('edit.tags'))),
              const SizedBox(height: 12),
              TextField(
                controller: addresses,
                minLines: 2,
                maxLines: 4,
                decoration: InputDecoration(labelText: s.t('edit.addresses')),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: notes,
                minLines: 2,
                maxLines: 5,
                decoration: InputDecoration(labelText: s.t('edit.notes')),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(s.t('common.cancel'))),
        FilledButton(
          onPressed: () async {
            final valid = parseAddressList(addresses.text.split(RegExp(r'[\n,]'))).map((a) => a.hostPort).toList();
            await widget.book.update(
              widget.entry.id,
              alias: alias.text,
              tags: tags.text.split(','),
              notes: notes.text,
              addresses: valid,
            );
            if (context.mounted) Navigator.of(context).pop();
          },
          child: Text(s.t('common.save')),
        ),
      ],
    );
  }
}

/// Adds a device by pasting `ID@address` or an invite link.
Future<void> showAddDeviceDialog(BuildContext context, AddressBook book) {
  return showDialog<void>(
    context: context,
    builder: (_) => _AddDeviceDialog(book: book),
  );
}

class _AddDeviceDialog extends StatefulWidget {
  const _AddDeviceDialog({required this.book});

  final AddressBook book;

  @override
  State<_AddDeviceDialog> createState() => _AddDeviceDialogState();
}

class _AddDeviceDialogState extends State<_AddDeviceDialog> {
  final controller = TextEditingController();
  String? error;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return AlertDialog(
      title: Text(s.t('add.title')),
      content: SizedBox(
        width: 440,
        child: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: s.t('add.label'), errorText: error, errorMaxLines: 3),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(s.t('common.cancel'))),
        FilledButton(
          onPressed: () async {
            final parsed = parseConnectInput(controller.text);
            final target = parsed.target;
            if (target == null || target.id == null) {
              setState(() => error = parsed.error ?? s.t('add.needId'));
              return;
            }
            await widget.book.addManual(
              id: target.id!,
              name: target.name ?? s.t('add.defaultName'),
              addresses: target.addresses.map((a) => a.hostPort).toList(),
            );
            if (context.mounted) Navigator.of(context).pop();
          },
          child: Text(s.t('add.button')),
        ),
      ],
    );
  }
}

/// Shows the address book as JSON to copy or save.
Future<void> showExportDialog(BuildContext context, AddressBook book) {
  final s = context.s;
  final json = book.exportJson();
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(s.t('export.title')),
      content: SizedBox(
        width: 520,
        height: 320,
        child: SingleChildScrollView(
          child: SelectableText(json, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(s.t('common.close'))),
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: json));
            if (ctx.mounted) showMessage(ctx, s.t('export.copied'));
          },
          child: Text(s.t('common.copy')),
        ),
        FilledButton(
          onPressed: () async {
            final messenger = ScaffoldMessenger.of(context);
            try {
              final dir = await getApplicationDocumentsDirectory();
              final file = File('${dir.path}${Platform.pathSeparator}thelxis-address-book.json');
              await file.writeAsString(json);
              messenger.showSnackBar(SnackBar(content: Text(s.t('export.saved', {'path': file.path}))));
              if (ctx.mounted) Navigator.of(ctx).pop();
            } on Object {
              messenger.showSnackBar(SnackBar(content: Text(s.t('export.failed'))));
            }
          },
          child: Text(s.t('export.save')),
        ),
      ],
    ),
  );
}

/// Imports an address-book export pasted as text.
Future<void> showImportDialog(BuildContext context, AddressBook book) {
  return showDialog<void>(
    context: context,
    builder: (_) => _ImportDialog(book: book, parentContext: context),
  );
}

class _ImportDialog extends StatefulWidget {
  const _ImportDialog({required this.book, required this.parentContext});

  final AddressBook book;
  final BuildContext parentContext;

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  final controller = TextEditingController();
  String? error;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return AlertDialog(
      title: Text(s.t('import.title')),
      content: SizedBox(
        width: 520,
        child: TextField(
          controller: controller,
          minLines: 8,
          maxLines: 12,
          decoration: InputDecoration(labelText: s.t('import.label'), errorText: error, alignLabelWithHint: true),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            final data = await Clipboard.getData(Clipboard.kTextPlain);
            if (data?.text != null) setState(() => controller.text = data!.text!);
          },
          child: Text(s.t('connect.paste')),
        ),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(s.t('common.cancel'))),
        FilledButton(
          onPressed: () async {
            try {
              final n = await widget.book.importJson(controller.text);
              if (context.mounted) {
                Navigator.of(context).pop();
                if (widget.parentContext.mounted) {
                  showMessage(widget.parentContext, s.plural('import.done', n));
                }
              }
            } on FormatException {
              setState(() => error = s.t('import.invalid'));
            }
          },
          child: Text(s.t('import.button')),
        ),
      ],
    );
  }
}
