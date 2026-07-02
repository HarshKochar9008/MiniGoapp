import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/contacts/contact_aliases.dart';
import '../../zensend/theme/zen_theme.dart';
import '../../zensend/widgets/zen_widgets.dart';

/// Bottom sheet to name (or rename/unname) another user locally.
/// Returns true if the alias was changed.
class ContactAliasSheet extends StatefulWidget {
  final String userId;
  final String code;
  const ContactAliasSheet({
    super.key,
    required this.userId,
    required this.code,
  });

  static Future<bool?> show(
    BuildContext context, {
    required String userId,
    required String code,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ContactAliasSheet(userId: userId, code: code),
    );
  }

  @override
  State<ContactAliasSheet> createState() => _ContactAliasSheetState();
}

class _ContactAliasSheetState extends State<ContactAliasSheet> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: ContactAliases.aliasFor(widget.userId) ?? '',
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await ContactAliases.setAlias(widget.userId, _controller.text);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.zen;
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: c.paper,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: c.divider,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text('Name this person',
                style: ZenText.title.copyWith(color: c.ink)),
            const SizedBox(height: 4),
            Text(
              'Only you see this name — it stays on this device. '
              'Their code is ${fmtCode(widget.code)}. '
              'Leave empty to remove the name.',
              style: ZenText.small,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              style: GoogleFonts.outfit(fontSize: 16, color: c.ink),
              decoration: InputDecoration(
                hintText: 'e.g. Priya, Work laptop…',
                hintStyle:
                    GoogleFonts.outfit(fontSize: 16, color: c.inkFaint),
                filled: true,
                fillColor: c.paperDeep,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 16),
            ZenButton(label: 'Save', onPressed: _save),
          ],
        ),
      ),
    );
  }
}
