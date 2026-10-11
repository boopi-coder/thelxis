import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/address_book.dart';
import '../../net/connect_target.dart';
import '../../net/net_address.dart';
import '../widgets/common.dart';

/// Edit alias, tags, notes and addresses of an address-book entry.
Future<void> showEditEntryDialog(BuildContext context, AddressBook book, AddressBookEntry entry) {
  final alias = TextEditingController(text: entry.alias);
  final tags = TextEditingController(text: entry.tags.join(', '));
  final notes = TextEditingController(text: entry.notes);
  final addresses = TextEditingController(text: entry.addresses.join('\n'));
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Edit ${entry.name}'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: alias, decoration: InputDecoration(labelText: 'Display name', hintText: entry.name)),
              const SizedBox(height: 12),
              TextField(controller: tags, decoration: const InputDecoration(labelText: 'Tags (comma separated)')),
              const SizedBox(height: 12),
              TextField(
                controller: addresses,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(labelText: 'Addresses (one per line)'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: notes,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(labelText: 'Notes'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () async {
            final valid = parseAddressList(addresses.text.split(RegExp(r'[\n,]'))).map((a) => a.hostPort).toList();
            await book.update(
              entry.id,
              alias: alias.text,
              tags: tags.text.split(','),
              notes: notes.text,
              addresses: valid,
            );
            if (ctx.mounted) Navigator.of(ctx).pop();
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

/// Adds a device by pasting `ID@address` or an invite link.
Future<void> showAddDeviceDialog(BuildContext context, AddressBook book) {
  final controller = TextEditingController();
  String? error;
  return showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Add a device'),
        content: SizedBox(
          width: 440,
          child: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Invite link or ID@address',
              errorText: error,
              errorMaxLines: 3,
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final parsed = parseConnectInput(controller.text);
              final target = parsed.target;
              if (target == null || target.id == null) {
                setState(() => error = parsed.error ?? 'Add the Thelxis ID before the address: ID@address.');
                return;
              }
              await book.addManual(
                id: target.id!,
                name: target.name ?? 'New device',
                addresses: target.addresses.map((a) => a.hostPort).toList(),
              );
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: const Text('Add'),
          ),
        ],
      ),
    ),
  );
}

/// Shows the address book as JSON to copy or save.
Future<void> showExportDialog(BuildContext context, AddressBook book) {
  final json = book.exportJson();
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Export address book'),
      content: SizedBox(
        width: 520,
        height: 320,
        child: SingleChildScrollView(
          child: SelectableText(json, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Close')),
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: json));
            if (ctx.mounted) showMessage(ctx, 'Copied to clipboard');
          },
          child: const Text('Copy'),
        ),
        FilledButton(
          onPressed: () async {
            final messenger = ScaffoldMessenger.of(context);
            try {
              final dir = await getApplicationDocumentsDirectory();
              final file = File('${dir.path}${Platform.pathSeparator}thelxis-address-book.json');
              await file.writeAsString(json);
              messenger.showSnackBar(SnackBar(content: Text('Saved to ${file.path}')));
              if (ctx.mounted) Navigator.of(ctx).pop();
            } on Object {
              messenger.showSnackBar(const SnackBar(content: Text('Could not save the file. Use Copy instead.')));
            }
          },
          child: const Text('Save to Documents'),
        ),
      ],
    ),
  );
}

/// Imports an address-book export pasted as text.
Future<void> showImportDialog(BuildContext context, AddressBook book) {
  final controller = TextEditingController();
  String? error;
  return showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Import address book'),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: controller,
            minLines: 8,
            maxLines: 12,
            decoration: InputDecoration(
              labelText: 'Paste the exported JSON',
              errorText: error,
              alignLabelWithHint: true,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              final data = await Clipboard.getData(Clipboard.kTextPlain);
              if (data?.text != null) setState(() => controller.text = data!.text!);
            },
            child: const Text('Paste'),
          ),
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              try {
                final n = await book.importJson(controller.text);
                if (ctx.mounted) {
                  Navigator.of(ctx).pop();
                  showMessage(context, 'Imported $n device${n == 1 ? '' : 's'}');
                }
              } on FormatException catch (e) {
                setState(() => error = e.message);
              }
            },
            child: const Text('Import'),
          ),
        ],
      ),
    ),
  );
}
