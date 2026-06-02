// Wave BC: a minimal "BotBooru Profile" settings screen.
//
// Wave CY.18.30: expanded into a real profile with avatar + About Me.
//
// Wave CY.18.31: renamed to just "Profile" + view-then-edit pattern;
// About Me briefly moved to Character Creator.
//
// Wave CY.18.36: expanded into a proper share-worthy profile card.
//
// What lives here now:
//   - Avatar + username (existing)
//   - Custom title under the username (replaces hardcoded "BotBooru
//     creator" — free text, user picks their own subtitle)
//   - Optional pronouns chip
//   - About Me paragraph (moved back from CC screen; no longer feeds
//     the architect — it's purely identity bio)
//   - Stats row: cards created in Pyre / library size / chats started
//     / days on Pyre
//   - Featured character spotlight (user pins ONE from library)
//
// The whole thing is view-only by default — large avatar, big name,
// title, stats, featured pin. Edit button in the AppBar exposes the
// individual inputs (avatar picker, username, title, pronouns,
// about me textarea, featured picker).

import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_store.dart';
import '../theme.dart';
import '../widgets/lightbox.dart';
import 'avatar_crop_screen.dart';

class BotbooruProfileScreen extends StatefulWidget {
  const BotbooruProfileScreen({super.key});

  @override
  State<BotbooruProfileScreen> createState() => _BotbooruProfileScreenState();
}

class _BotbooruProfileScreenState extends State<BotbooruProfileScreen> {
  late final TextEditingController _usernameCtl;
  late final TextEditingController _titleCtl;
  late final TextEditingController _pronounsCtl;
  late final TextEditingController _aboutMeCtl;
  bool _editMode = false;

  @override
  void initState() {
    super.initState();
    final store = context.read<AppStore>();
    _usernameCtl = TextEditingController(text: store.botbooruUsername);
    _titleCtl = TextEditingController(text: store.botbooruTitle);
    _pronounsCtl = TextEditingController(text: store.botbooruPronouns);
    _aboutMeCtl = TextEditingController(text: store.botbooruAboutMe);
  }

  @override
  void dispose() {
    // Flush any pending text edits so a fast back-press doesn't lose
    // the tail keystrokes that bypassed onChanged commit.
    final store = context.read<AppStore>();
    if (store.botbooruUsername != _usernameCtl.text.trim()) {
      store.setBotbooruUsername(_usernameCtl.text);
    }
    if (store.botbooruTitle != _titleCtl.text) {
      store.setBotbooruTitle(_titleCtl.text);
    }
    if (store.botbooruPronouns != _pronounsCtl.text) {
      store.setBotbooruPronouns(_pronounsCtl.text);
    }
    if (store.botbooruAboutMe != _aboutMeCtl.text) {
      store.setBotbooruAboutMe(_aboutMeCtl.text);
    }
    _usernameCtl.dispose();
    _titleCtl.dispose();
    _pronounsCtl.dispose();
    _aboutMeCtl.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final bytes = result.files.single.bytes;
    if (bytes == null) return;
    if (!mounted) return;
    final cropped = await cropAvatar(context, bytes);
    if (cropped == null) return;
    if (!mounted) return;
    context.read<AppStore>().setBotbooruAvatar(
        'data:image/png;base64,${base64Encode(cropped)}');
  }

  Future<void> _recropAvatar() async {
    final url = context.read<AppStore>().botbooruAvatar;
    if (url == null || !url.startsWith('data:')) return;
    final comma = url.indexOf(',');
    if (comma < 0) return;
    try {
      final bytes = base64Decode(url.substring(comma + 1));
      if (!mounted) return;
      final cropped = await cropAvatar(context, bytes);
      if (cropped == null) return;
      if (!mounted) return;
      context.read<AppStore>().setBotbooruAvatar(
          'data:image/png;base64,${base64Encode(cropped)}');
    } catch (_) {}
  }

  void _removeAvatar() {
    context.read<AppStore>().setBotbooruAvatar(null);
  }

  void _openLightbox(String dataUrl, String fallback) {
    Lightbox.show(context, dataUrl: dataUrl, fallback: fallback);
  }

  Future<void> _pickFeaturedCharacter() async {
    final store = context.read<AppStore>();
    final chosen = await showModalBottomSheet<String?>(
      context: context,
      backgroundColor: EmberColors.bgPanel,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheet) => _FeaturedPickerSheet(
        characters: store.characters,
        currentId: store.botbooruFeaturedCharacterId,
      ),
    );
    if (chosen == null) return; // user cancelled
    if (!mounted) return;
    // Sentinel '' = explicit clear (passed by the "Remove" tile).
    context.read<AppStore>().setBotbooruFeaturedCharacter(
        chosen.isEmpty ? null : chosen);
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final avatar = store.botbooruAvatar;
    final username = store.botbooruUsername;
    final title = store.botbooruTitle.trim();
    final pronouns = store.botbooruPronouns.trim();
    final aboutMe = store.botbooruAboutMe.trim();

    // Resolve featured character (null if missing or deleted).
    Character? featured;
    final featuredId = store.botbooruFeaturedCharacterId;
    if (featuredId != null) {
      try {
        featured =
            store.characters.firstWhere((c) => c.id == featuredId);
      } catch (_) {
        featured = null;
      }
    }

    // Stats
    final cardsCreated =
        store.characters.where((c) => c.createdInPyre).length;
    final cardsImported = store.characters.where((c) => !c.createdInPyre).length;
    final libraryTotal = store.characters.length;
    final chatsStarted = store.chats.length;
    final days = _daysSince(store.installedAt);

    // Wave CY.18.95: usage roll-up — local-only, never leaves the
    // device. Walks every chat once per render; cheap at any
    // realistic library size (hundreds of chats, max few thousand
    // messages). Token math is the same ~chars/4 heuristic used by
    // token_estimate.dart elsewhere — accurate enough to be a
    // ballpark, NOT for billing. The label says "estimate" to set
    // that expectation.
    var userMessagesSent = 0;
    var assistantReplies = 0;
    var totalChars = 0;
    for (final chat in store.chats) {
      for (final msg in chat.messages) {
        // Sum the SELECTED variant only (msg.text — the same accessor
        // the chat-info sheet uses). Summing every variant over-counted
        // tokens for any message with branches/alternates, while the
        // message COUNT below is selected-variant only; keeping both on
        // the selected variant makes "tokens" reflect real usage.
        totalChars += msg.text.length;
        // Count messages by kind on the SELECTED variant only —
        // that's the canonical message-as-shipped, branches are
        // alternate framings of the same logical turn.
        switch (msg.kind) {
          case MessageKind.user:
            userMessagesSent++;
            break;
          case MessageKind.char:
            assistantReplies++;
            break;
          case MessageKind.ooc:
          case MessageKind.scene:
          case MessageKind.system:
            // Don't count — these aren't user-vs-assistant traffic.
            break;
        }
      }
    }
    final tokensApprox = (totalChars / 4).round();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        actions: [
          TextButton.icon(
            icon: Icon(
              _editMode ? Icons.check : Icons.edit_outlined,
              size: 16,
            ),
            label: Text(_editMode ? 'Done' : 'Edit'),
            style: TextButton.styleFrom(
              foregroundColor: EmberColors.primary,
            ),
            onPressed: () => setState(() => _editMode = !_editMode),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
        children: [
          _ProfileHeader(
            avatar: avatar,
            username: username,
            title: title,
            pronouns: pronouns,
            editMode: _editMode,
            onTapAvatarPicker: _pickAvatar,
            onTapAvatarLightbox: avatar == null
                ? null
                : () => _openLightbox(avatar, username),
            onRecrop: avatar == null ? null : _recropAvatar,
            onRemove: avatar == null ? null : _removeAvatar,
          ),
          const SizedBox(height: 20),

          // EDIT MODE: identity fields under the header.
          if (_editMode) ...[
            _IdentityEditCard(
              usernameCtl: _usernameCtl,
              titleCtl: _titleCtl,
              pronounsCtl: _pronounsCtl,
              onUsernameChanged: (v) =>
                  context.read<AppStore>().setBotbooruUsername(v),
              onTitleChanged: (v) =>
                  context.read<AppStore>().setBotbooruTitle(v),
              onPronounsChanged: (v) =>
                  context.read<AppStore>().setBotbooruPronouns(v),
            ),
            const SizedBox(height: 14),
          ],

          // About Me — visible in both modes (edit shows it as a
          // bigger textarea; view shows it as a paragraph card).
          _AboutMeSection(
            controller: _aboutMeCtl,
            value: aboutMe,
            editMode: _editMode,
            onChanged: (v) =>
                context.read<AppStore>().setBotbooruAboutMe(v),
          ),
          const SizedBox(height: 16),

          // Stats — HIDDEN in view mode (a clean profile by default);
          // revealed only when you tap Edit. The numbers are a "monte
          // de informações" that shouldn't greet you on open.
          if (_editMode) ...[
            _StatsCard(
              cardsCreated: cardsCreated,
              libraryTotal: libraryTotal,
              chatsStarted: chatsStarted,
              days: days,
            ),
            const SizedBox(height: 12),

            // Wave CY.18.95: deeper usage roll-up. Same look as the
            // primary stats card but with stats that need a walk over
            // every chat — kept separate so the first card stays the
            // share-worthy headline.
            _UsageStatsCard(
              userMessages: userMessagesSent,
              assistantReplies: assistantReplies,
              cardsImported: cardsImported,
              tokensApprox: tokensApprox,
            ),
            const SizedBox(height: 16),
          ],

          // Featured character — view-only display in view mode,
          // tap-to-change in edit mode.
          _FeaturedCharacterCard(
            character: featured,
            editMode: _editMode,
            onPick: _pickFeaturedCharacter,
            onTapLightbox: featured?.avatar == null
                ? null
                : () => _openLightbox(featured!.avatar!, featured.name),
          ),
        ],
      ),
    );
  }

  static int _daysSince(int? installedAtMs) {
    if (installedAtMs == null) return 0;
    final now = DateTime.now();
    final installed = DateTime.fromMillisecondsSinceEpoch(installedAtMs);
    final diff = now.difference(installed).inDays;
    return diff < 0 ? 0 : diff;
  }
}

// ---------------------------------------------------------------------------
// Header (avatar + username + custom title + pronouns)

class _ProfileHeader extends StatelessWidget {
  final String? avatar;
  final String username;
  final String title;
  final String pronouns;
  final bool editMode;
  final VoidCallback onTapAvatarPicker;
  final VoidCallback? onTapAvatarLightbox;
  final VoidCallback? onRecrop;
  final VoidCallback? onRemove;
  const _ProfileHeader({
    required this.avatar,
    required this.username,
    required this.title,
    required this.pronouns,
    required this.editMode,
    required this.onTapAvatarPicker,
    required this.onTapAvatarLightbox,
    required this.onRecrop,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final hasAvatar = avatar != null && avatar!.isNotEmpty;
    final display = username.trim().isNotEmpty
        ? username.trim()
        : (editMode ? 'No username set' : 'Anonymous creator');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        GestureDetector(
          onTap: editMode
              ? onTapAvatarPicker
              : (hasAvatar ? onTapAvatarLightbox : onTapAvatarPicker),
          child: _AvatarCircle(
            dataUrl: avatar,
            fallbackInitial:
                display.isNotEmpty ? display.characters.first : '?',
            size: editMode ? 112 : 140,
          ),
        ),
        if (editMode) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (!hasAvatar)
                _MiniAction(
                  icon: Icons.add_a_photo_outlined,
                  label: 'Add profile picture',
                  onTap: onTapAvatarPicker,
                ),
              if (hasAvatar) ...[
                _MiniAction(
                  icon: Icons.swap_horiz,
                  label: 'Change',
                  onTap: onTapAvatarPicker,
                ),
                _MiniAction(
                  icon: Icons.crop,
                  label: 'Recrop',
                  onTap: onRecrop,
                ),
                _MiniAction(
                  icon: Icons.delete_outline,
                  label: 'Remove',
                  onTap: onRemove,
                  danger: true,
                ),
              ],
            ],
          ),
        ],
        const SizedBox(height: 14),
        Text(
          display,
          style: TextStyle(
            color: EmberColors.textHigh,
            fontSize: editMode ? 17 : 22,
            fontWeight: FontWeight.w600,
            letterSpacing: editMode ? 0.0 : 0.2,
          ),
          textAlign: TextAlign.center,
        ),
        // Custom title (replaces the old hardcoded "BotBooru creator").
        if (title.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            title,
            style: const TextStyle(
              color: EmberColors.textMid,
              fontSize: 13,
              fontStyle: FontStyle.italic,
            ),
            textAlign: TextAlign.center,
          ),
        ],
        // Pronouns chip, if set. Subtle, sits below title.
        if (pronouns.isNotEmpty) ...[
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: EmberColors.bgElevated,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: EmberColors.primary.withValues(alpha: 0.3),
              ),
            ),
            child: Text(
              pronouns,
              style: const TextStyle(
                color: EmberColors.textMid,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _AvatarCircle extends StatelessWidget {
  final String? dataUrl;
  final String fallbackInitial;
  final double size;
  const _AvatarCircle({
    required this.dataUrl,
    required this.fallbackInitial,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final bytes = _decode(dataUrl);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: EmberColors.bgElevated,
        border: Border.all(
          color: EmberColors.primary.withValues(alpha: 0.45),
          width: 2,
        ),
        image: bytes != null
            ? DecorationImage(image: MemoryImage(bytes), fit: BoxFit.cover)
            : null,
      ),
      alignment: Alignment.center,
      child: bytes == null
          ? Text(
              fallbackInitial.toUpperCase(),
              style: TextStyle(
                color: EmberColors.textMid,
                fontSize: size * 0.40,
                fontWeight: FontWeight.w600,
              ),
            )
          : null,
    );
  }

  Uint8List? _decode(String? url) {
    if (url == null || !url.startsWith('data:')) return null;
    final comma = url.indexOf(',');
    if (comma < 0) return null;
    try {
      return base64Decode(url.substring(comma + 1));
    } catch (_) {
      return null;
    }
  }
}

class _MiniAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool danger;
  const _MiniAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = danger ? const Color(0xFFE57373) : EmberColors.primary;
    return TextButton.icon(
      icon: Icon(icon, size: 14, color: color),
      label: Text(label, style: TextStyle(color: color, fontSize: 12)),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        minimumSize: const Size(0, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: onTap,
    );
  }
}

// ---------------------------------------------------------------------------
// Edit-mode card: username + title + pronouns inputs

class _IdentityEditCard extends StatelessWidget {
  final TextEditingController usernameCtl;
  final TextEditingController titleCtl;
  final TextEditingController pronounsCtl;
  final ValueChanged<String> onUsernameChanged;
  final ValueChanged<String> onTitleChanged;
  final ValueChanged<String> onPronounsChanged;
  const _IdentityEditCard({
    required this.usernameCtl,
    required this.titleCtl,
    required this.pronounsCtl,
    required this.onUsernameChanged,
    required this.onTitleChanged,
    required this.onPronounsChanged,
  });

  InputDecoration _dec(String hint) => InputDecoration(
        hintText: hint,
        filled: true,
        fillColor: EmberColors.bgDeep,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: EmberColors.stroke),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: EmberColors.stroke),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(
            color: EmberColors.primary.withValues(alpha: 0.7),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: EmberColors.bgPanel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: EmberColors.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'IDENTITY',
            style: TextStyle(
              color: EmberColors.primary,
              fontWeight: FontWeight.w700,
              fontSize: 11,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Username',
            style: TextStyle(
              color: EmberColors.textMid,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          TextField(
            controller: usernameCtl,
            onChanged: onUsernameChanged,
            decoration: _dec('your_botbooru_handle'),
            style: const TextStyle(
              color: EmberColors.textHigh,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Used as your `creator` tag on cards built in the '
            'Character Creator. Case-sensitive on botbooru.com.',
            style: TextStyle(
                color: EmberColors.textDim, fontSize: 11, height: 1.4),
          ),
          const SizedBox(height: 14),
          const Text(
            'Title',
            style: TextStyle(
              color: EmberColors.textMid,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          TextField(
            controller: titleCtl,
            onChanged: onTitleChanged,
            maxLength: 60,
            decoration: _dec(
                    'e.g. "Slow-burn enthusiast", "Just here for the chaos"')
                .copyWith(counterText: ''),
            style: const TextStyle(
              color: EmberColors.textHigh,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Short subtitle that sits under your name. Empty hides it.',
            style: TextStyle(
                color: EmberColors.textDim, fontSize: 11, height: 1.4),
          ),
          const SizedBox(height: 14),
          const Text(
            'Pronouns (optional)',
            style: TextStyle(
              color: EmberColors.textMid,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          TextField(
            controller: pronounsCtl,
            onChanged: onPronounsChanged,
            maxLength: 30,
            decoration: _dec('e.g. she/her, they/them, he/him').copyWith(
              counterText: '',
            ),
            style: const TextStyle(
              color: EmberColors.textHigh,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 8),
          // Quick-pick chips so most users don't have to type.
          Wrap(
            spacing: 6,
            children: [
              for (final preset in const [
                'she/her',
                'he/him',
                'they/them',
                'she/they',
                'he/they',
              ])
                ActionChip(
                  label: Text(preset, style: const TextStyle(fontSize: 11)),
                  onPressed: () {
                    pronounsCtl.text = preset;
                    onPronounsChanged(preset);
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// About Me section (view mode → paragraph card; edit mode → textarea)

class _AboutMeSection extends StatelessWidget {
  final TextEditingController controller;
  final String value;
  final bool editMode;
  final ValueChanged<String> onChanged;
  const _AboutMeSection({
    required this.controller,
    required this.value,
    required this.editMode,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (editMode) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: EmberColors.bgPanel,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: EmberColors.stroke),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'ABOUT ME',
              style: TextStyle(
                color: EmberColors.primary,
                fontWeight: FontWeight.w700,
                fontSize: 11,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'A short bio for your profile. Whatever you want — '
              'tropes you love, favorite genres, what you\'re into.',
              style: TextStyle(
                color: EmberColors.textMid,
                fontSize: 12,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: controller,
              onChanged: onChanged,
              minLines: 4,
              maxLines: 10,
              decoration: InputDecoration(
                hintText:
                    'e.g. "Slice-of-life teacher cards with soft '
                    'NSFW. I like flawed-but-warm characters and '
                    'slow-burn pacing."',
                filled: true,
                fillColor: EmberColors.bgDeep,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: EmberColors.stroke),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: EmberColors.stroke),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                    color: EmberColors.primary.withValues(alpha: 0.7),
                  ),
                ),
              ),
              style: const TextStyle(
                color: EmberColors.textHigh,
                fontSize: 14,
                height: 1.4,
              ),
            ),
          ],
        ),
      );
    }
    // View mode — only render the card if there's content. Empty
    // About Me just collapses out of the layout.
    if (value.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: EmberColors.bgPanel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: EmberColors.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'ABOUT',
            style: TextStyle(
              color: EmberColors.primary,
              fontWeight: FontWeight.w700,
              fontSize: 11,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
              color: EmberColors.textHigh,
              fontSize: 13,
              height: 1.55,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Stats card — 4 chips in a row: cards built / library / chats / days

class _StatsCard extends StatelessWidget {
  final int cardsCreated;
  final int libraryTotal;
  final int chatsStarted;
  final int days;
  const _StatsCard({
    required this.cardsCreated,
    required this.libraryTotal,
    required this.chatsStarted,
    required this.days,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: EmberColors.bgPanel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: EmberColors.stroke),
      ),
      child: Row(
        children: [
          Expanded(child: _Stat(value: cardsCreated, label: 'cards built')),
          _Divider(),
          Expanded(
              child: _Stat(value: libraryTotal, label: 'in library')),
          _Divider(),
          Expanded(child: _Stat(value: chatsStarted, label: 'chats')),
          _Divider(),
          Expanded(child: _Stat(value: days, label: 'days')),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final int value;
  final String label;
  const _Stat({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          '$value',
          style: const TextStyle(
            color: EmberColors.textHigh,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(
            color: EmberColors.textDim,
            fontSize: 10.5,
            letterSpacing: 0.3,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 32,
        color: EmberColors.stroke,
      );
}

// ---------------------------------------------------------------------------
// Wave CY.18.95: Usage roll-up. Sits below the primary stats card.
// Same visual rhythm (4 chips in a row) but the four numbers are
// derived by walking chat history rather than reading list lengths.
//
// All numbers are LOCAL — nothing in this card ever leaves the device.
// They're a personal dashboard, not a telemetry surface.

class _UsageStatsCard extends StatelessWidget {
  final int userMessages;
  final int assistantReplies;
  final int cardsImported;
  final int tokensApprox;

  const _UsageStatsCard({
    required this.userMessages,
    required this.assistantReplies,
    required this.cardsImported,
    required this.tokensApprox,
  });

  /// Compact label for the token estimate: "1.2k", "830k", "1.4M".
  /// Keep three significant figures-ish so the number stays
  /// glanceable even when it's huge — a hundred-thousand reply
  /// session shouldn't print "100000" in a 32-px wide column.
  static String _formatTokens(int t) {
    if (t < 1000) return '$t';
    if (t < 10000) return '${(t / 1000).toStringAsFixed(1)}k';
    if (t < 1000000) return '${(t / 1000).round()}k';
    if (t < 10000000) return '${(t / 1000000).toStringAsFixed(1)}M';
    return '${(t / 1000000).round()}M';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: EmberColors.bgPanel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: EmberColors.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 2, bottom: 6),
            child: Text(
              'Usage',
              style: TextStyle(
                color: EmberColors.textDim,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: _Stat(
                    value: userMessages, label: 'messages sent'),
              ),
              _Divider(),
              Expanded(
                child: _Stat(
                    value: assistantReplies, label: 'replies'),
              ),
              _Divider(),
              Expanded(
                child: _Stat(
                    value: cardsImported, label: 'imported'),
              ),
              _Divider(),
              // Tokens use a custom label widget so we can render
              // "1.2k" instead of the raw integer.
              Expanded(
                child: _TokenStat(
                  display: _formatTokens(tokensApprox),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TokenStat extends StatelessWidget {
  final String display;
  const _TokenStat({required this.display});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          display,
          style: const TextStyle(
            color: EmberColors.textHigh,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 2),
        const Text(
          '~tokens',
          style: TextStyle(
            color: EmberColors.textDim,
            fontSize: 10.5,
            letterSpacing: 0.3,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Featured character — pinned card from the user's library

class _FeaturedCharacterCard extends StatelessWidget {
  final Character? character;
  final bool editMode;
  final VoidCallback onPick;
  final VoidCallback? onTapLightbox;
  const _FeaturedCharacterCard({
    required this.character,
    required this.editMode,
    required this.onPick,
    required this.onTapLightbox,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: EmberColors.bgPanel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: EmberColors.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'FEATURED CHARACTER',
                  style: TextStyle(
                    color: EmberColors.primary,
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              if (editMode)
                TextButton.icon(
                  icon: const Icon(Icons.swap_horiz, size: 14),
                  label: Text(character == null ? 'Pick' : 'Change'),
                  style: TextButton.styleFrom(
                    foregroundColor: EmberColors.primary,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 0),
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: onPick,
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (character == null) ...[
            // Empty state — only show pick CTA in edit mode (avoids
            // confusion in view mode where no edit affordance exists).
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.star_border,
                    color: EmberColors.textDim, size: 32),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    editMode
                        ? 'Pin one of your characters as your '
                            'featured spotlight. It\'s a pure curation '
                            'choice — no functional impact, just a way '
                            'to show off what you\'re proud of.'
                        : 'No character pinned yet. Tap Edit to '
                            'pick one to spotlight here.',
                    style: const TextStyle(
                      color: EmberColors.textDim,
                      fontSize: 12,
                      height: 1.45,
                    ),
                  ),
                ),
              ],
            ),
          ] else
            _FeaturedTile(
              character: character!,
              onTapLightbox: onTapLightbox,
            ),
        ],
      ),
    );
  }
}

class _FeaturedTile extends StatelessWidget {
  final Character character;
  final VoidCallback? onTapLightbox;
  const _FeaturedTile({required this.character, required this.onTapLightbox});

  Uint8List? _decode(String? url) {
    if (url == null || !url.startsWith('data:')) return null;
    final comma = url.indexOf(',');
    if (comma < 0) return null;
    try {
      return base64Decode(url.substring(comma + 1));
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _decode(character.avatar);
    final tagline = (character.tagline ?? '').trim();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: onTapLightbox,
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: EmberColors.bgElevated,
              border: Border.all(
                color: EmberColors.primary.withValues(alpha: 0.5),
                width: 2,
              ),
              image: bytes != null
                  ? DecorationImage(
                      image: MemoryImage(bytes), fit: BoxFit.cover)
                  : null,
            ),
            alignment: Alignment.center,
            child: bytes == null
                ? Text(
                    character.name.isNotEmpty
                        ? character.name.characters.first.toUpperCase()
                        : '?',
                    style: const TextStyle(
                      color: EmberColors.textMid,
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                    ),
                  )
                : null,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                character.name,
                style: const TextStyle(
                  color: EmberColors.textHigh,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (tagline.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  tagline,
                  style: const TextStyle(
                    color: EmberColors.textMid,
                    fontSize: 12,
                    fontStyle: FontStyle.italic,
                    height: 1.4,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Bottom sheet that lists user's characters for Featured pinning.

class _FeaturedPickerSheet extends StatelessWidget {
  final List<Character> characters;
  final String? currentId;
  const _FeaturedPickerSheet({
    required this.characters,
    required this.currentId,
  });

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * 0.7;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Pick a featured character',
                      style: TextStyle(
                        color: EmberColors.textHigh,
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            if (characters.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 16, 20, 24),
                child: Text(
                  'No characters in your library yet. Build or import '
                  'a card first, then come back to pin it here.',
                  style: TextStyle(
                    color: EmberColors.textDim,
                    fontSize: 13,
                    height: 1.45,
                  ),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: characters.length + 1, // +1 for "Remove" row
                  itemBuilder: (_, i) {
                    if (i == 0) {
                      // First row: clear the pin.
                      return ListTile(
                        leading: const Icon(Icons.star_outline,
                            color: EmberColors.textMid),
                        title: const Text('Remove featured'),
                        subtitle: const Text(
                          'Hide the featured card from your profile.',
                          style: TextStyle(fontSize: 11),
                        ),
                        // Pass empty string sentinel — caller treats
                        // it as "explicit clear" (null sentinel means
                        // the user cancelled without picking).
                        onTap: () => Navigator.of(context).pop(''),
                      );
                    }
                    final c = characters[i - 1];
                    final selected = c.id == currentId;
                    return ListTile(
                      leading: _SmallAvatar(dataUrl: c.avatar, fallback: c.name),
                      title: Text(c.name),
                      subtitle: c.tagline != null && c.tagline!.isNotEmpty
                          ? Text(
                              c.tagline!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11),
                            )
                          : null,
                      trailing: selected
                          ? const Icon(Icons.check_circle,
                              color: EmberColors.primary, size: 18)
                          : null,
                      onTap: () => Navigator.of(context).pop(c.id),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SmallAvatar extends StatelessWidget {
  final String? dataUrl;
  final String fallback;
  const _SmallAvatar({required this.dataUrl, required this.fallback});

  Uint8List? _decode(String? url) {
    if (url == null || !url.startsWith('data:')) return null;
    final comma = url.indexOf(',');
    if (comma < 0) return null;
    try {
      return base64Decode(url.substring(comma + 1));
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _decode(dataUrl);
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: EmberColors.bgElevated,
        image: bytes != null
            ? DecorationImage(image: MemoryImage(bytes), fit: BoxFit.cover)
            : null,
      ),
      alignment: Alignment.center,
      child: bytes == null
          ? Text(
              fallback.isNotEmpty
                  ? fallback.characters.first.toUpperCase()
                  : '?',
              style: const TextStyle(
                color: EmberColors.textMid,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            )
          : null,
    );
  }
}
