import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/contacts/contact_aliases.dart';
import '../../Minigo/theme/mini_theme.dart';
import '../../Minigo/widgets/mini_widgets.dart';

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
    final c = context.mini;
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: c.paperDeep,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(MiniRadius.sheet),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(22, 12, 22, 26),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 5,
                decoration: BoxDecoration(
                  color: c.sandDeep,
                  borderRadius: BorderRadius.circular(MiniRadius.pill),
                ),
              ),
            ),
            const SizedBox(height: 22),
            Text('Name this person',
                style: MiniText.title.copyWith(color: c.ink)),
            const SizedBox(height: 6),
            Text(
              'Only you see this name — it stays on this device. '
              'Their code is ${fmtCode(widget.code)}. '
              'Leave empty to remove the name.',
              style: MiniText.bodySoft.copyWith(color: c.inkSoft),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _controller,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              style: GoogleFonts.outfit(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: c.ink,
              ),
              decoration: InputDecoration(
                hintText: 'e.g. Priya, Work laptop…',
                hintStyle: GoogleFonts.outfit(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: c.inkFaint,
                ),
                filled: true,
                fillColor: c.sand,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(MiniRadius.control),
                  borderSide: BorderSide.none,
                ),
              ),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 20),
            MiniButton(label: 'Save', onPressed: _save),
          ],
        ),
      ),
    );
  }
}
