import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_store.dart';
import '../theme.dart';
import '../widgets/avatar.dart';

/// Visualises the FULL conversation tree — not just the currently-
/// visible thread.
///
/// Wave CY.16: rewrote the layout to do a recursive depth-first
/// traversal so every branch (active + stashed) shows up. Previously
/// only `chat.messages` (the active thread) was walked, with sibling
/// variants laid out as a row at each depth but their downstream
/// hidden behind a `+N` badge — most users took the badge to mean
/// "broken" rather than "tap here to drill in". Now every variant
/// has its full subtree rendered. Tapping a non-selected node switches
/// to that branch AND pops back to the chat so the user sees the
/// effect immediately.
class ChatTreeScreen extends StatelessWidget {
  final String chatId;
  const ChatTreeScreen({super.key, required this.chatId});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    Chat? chat;
    for (final c in store.chats) {
      if (c.id == chatId) {
        chat = c;
        break;
      }
    }
    if (chat == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Chat tree')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Text(
              'This chat was deleted.',
              style: TextStyle(color: EmberColors.textMid),
            ),
          ),
        ),
      );
    }
    final layout = _buildLayout(chat, store);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Chat tree'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: const Text(
              'Tap any node to jump to that variant in the chat. Highlighted line = active branch.',
              style: TextStyle(
                color: EmberColors.textMid,
                fontSize: 11,
                height: 1.3,
              ),
            ),
          ),
        ),
      ),
      body: layout.items.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'No messages yet — nothing to map.',
                  style: TextStyle(color: EmberColors.textMid),
                ),
              ),
            )
          // Wave CY.18.4: previously the InteractiveViewer's child was a
          // bare SizedBox sized to layout.{canvasWidth,canvasHeight}. For
          // a linear chat (no branches) that's ~128px wide. Combined with
          // `boundaryMargin: EdgeInsets.all(200)`, the boundary rect was
          // ~528px wide — narrower than a typical phone viewport. The
          // clamping logic in InteractiveViewer can only constrain
          // panning when the boundary is at least as large as the
          // viewport; below that threshold it silently gives up, letting
          // the user drag the entire tree off-screen.
          //
          // The fix: wrap in a LayoutBuilder so we know the viewport's
          // real size, then pad the canvas SizedBox up to AT LEAST the
          // viewport's dimensions. The actual tree content is centered
          // horizontally inside that padded canvas. Boundary margin
          // drops to a small breathing room (40px) so the user can pan
          // slightly past the edges but never lose the nodes.
          : LayoutBuilder(builder: (ctx, vp) {
              final viewportW = vp.maxWidth.isFinite ? vp.maxWidth : 0.0;
              final viewportH =
                  vp.maxHeight.isFinite ? vp.maxHeight : 0.0;
              final canvasW = max(layout.canvasWidth, viewportW);
              final canvasH = max(layout.canvasHeight, viewportH);
              final offsetX = canvasW > layout.canvasWidth
                  ? (canvasW - layout.canvasWidth) / 2
                  : 0.0;
              return InteractiveViewer(
                minScale: 0.4,
                maxScale: 2.5,
                constrained: false,
                boundaryMargin: const EdgeInsets.all(40),
                child: SizedBox(
                  width: canvasW,
                  height: canvasH,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned(
                        left: offsetX,
                        top: 0,
                        width: layout.canvasWidth,
                        height: layout.canvasHeight,
                        child: CustomPaint(
                          painter: _EdgePainter(layout),
                          child: Stack(
                            children: layout.items
                                .map((n) =>
                                    _NodeWidget(node: n, chatId: chatId))
                                .toList(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
    );
  }

  /// Recursive DFS layout. Each call returns the width consumed by the
  /// subtree rooted at `messages.first` (with the rest of `messages` as
  /// its downstream when its currently-selected variant is the visible
  /// one). Variant siblings sit horizontally; each variant's downstream
  /// sits vertically below it.
  _Layout _buildLayout(Chat chat, AppStore store) {
    const double nodeW = 96;
    const double nodeH = 96;
    const double hGap = 24;
    const double vGap = 36;

    final items = <_TreeNode>[];
    final edges = <_Edge>[];

    // Recursive worker. Returns (subtree width, x-center of root node).
    // `parentNode` is the variant-node that owns this subtree — used so
    // we can wire an edge from parent → root once we know our root's
    // center coordinate. `messages` is the FULL list of messages whose
    // first element is the root of this subtree; the remainder becomes
    // the downstream of root's selected variant. For stashed variants
    // (non-selected), we pass `m.downstreamByVariant[v]` instead.
    double walk(
      List<Message> messages,
      int depth,
      double leftX,
      _TreeNode? parentNode, {
      // When false, every node we add is dim (it belongs to a stashed
      // branch the user navigated away from). The active branch line
      // is bright.
      required bool inActiveBranch,
    }) {
      if (messages.isEmpty) return 0;
      final m = messages.first;
      final downstreamForSelected =
          messages.length > 1 ? messages.sublist(1) : <Message>[];
      final variantCount = m.variants.length;
      double cursor = leftX;
      double mySubtreeMaxRight = leftX;
      for (var v = 0; v < variantCount; v++) {
        final isSelectedVariant = v == m.selectedVariant;
        // Pick the right downstream for this variant.
        final downstream = isSelectedVariant
            ? downstreamForSelected
            : (m.downstreamByVariant[v] ?? const <Message>[]);
        // First, recursively figure out where THIS variant's subtree
        // should sit. The subtree starts at `cursor`. The variant node
        // itself centers above the subtree.
        final character = m.characterId == null
            ? null
            : (chat.characterSnapshots[m.characterId!] ??
                store.characterById(m.characterId!));
        // Reserve a placeholder so we can compute subtree extent first
        // and then centre the node above it. We add the node AFTER
        // recursing so we know its centre.
        final subtreeStart = cursor;
        final isThisActive = inActiveBranch && isSelectedVariant;
        // Recurse into the variant's downstream first (top-down).
        // The child layout will accumulate from `subtreeStart`.
        // Build a placeholder node and let walk add its children;
        // we'll patch the node's x after we know the subtree extent.
        // Path from root: parent's path + this node's step. Root
        // nodes (no parent) start a fresh path with just themselves.
        final myPath = parentNode == null
            ? <_PathStep>[_PathStep(m.id, v)]
            : <_PathStep>[
                ...parentNode.pathFromRoot,
                _PathStep(m.id, v),
              ];
        final node = _TreeNode(
          x: 0, // patched below
          y: 16 + depth * (nodeH + vGap),
          width: nodeW,
          height: nodeH,
          message: m,
          variantIndex: v,
          isSelected: isSelectedVariant,
          inActiveBranch: isThisActive,
          character: character,
          pathFromRoot: myPath,
        );
        items.add(node);
        final childWidth = walk(
          downstream,
          depth + 1,
          subtreeStart,
          node,
          inActiveBranch: isThisActive,
        );
        final variantColumnWidth = max(nodeW, childWidth);
        // Centre this variant's node above its column.
        node.x = subtreeStart + (variantColumnWidth - nodeW) / 2;
        if (parentNode != null) {
          edges.add(_Edge(
            from: parentNode,
            to: node,
            active: isThisActive,
          ));
        }
        cursor = subtreeStart + variantColumnWidth + hGap;
        if (cursor > mySubtreeMaxRight) mySubtreeMaxRight = cursor;
      }
      // Strip the trailing hGap we added after the last variant.
      return (mySubtreeMaxRight - leftX - hGap).clamp(0, double.infinity);
    }

    if (chat.messages.isNotEmpty) {
      walk(
        chat.messages,
        0,
        16,
        null,
        inActiveBranch: true,
      );
    }

    final maxX = items.fold<double>(
        0, (acc, n) => n.x + n.width > acc ? n.x + n.width : acc);
    final maxY = items.fold<double>(
        0, (acc, n) => n.y + n.height > acc ? n.y + n.height : acc);

    return _Layout(
      items: items,
      edges: edges,
      canvasWidth: maxX + 16,
      canvasHeight: maxY + 16,
    );
  }
}

class _Layout {
  final List<_TreeNode> items;
  final List<_Edge> edges;
  final double canvasWidth;
  final double canvasHeight;
  _Layout({
    required this.items,
    required this.edges,
    required this.canvasWidth,
    required this.canvasHeight,
  });
}

class _Edge {
  final _TreeNode from;
  final _TreeNode to;
  final bool active;
  _Edge({required this.from, required this.to, required this.active});
}

class _TreeNode {
  double x;
  final double y;
  final double width;
  final double height;
  final Message message;
  final int variantIndex;
  final bool isSelected;
  final bool inActiveBranch;
  final Character? character;
  /// Wave CY.18.5: full path of (messageId, variantIndex) from the
  /// chat root down to AND including this node. Replaying these in
  /// order via [AppStore.selectVariant] guarantees every ancestor
  /// gets restored from its stashed snapshot before we try to select
  /// the next descendant — so deep nodes in branches the user hasn't
  /// visited yet still navigate correctly.
  final List<_PathStep> pathFromRoot;
  _TreeNode({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.message,
    required this.variantIndex,
    required this.isSelected,
    required this.inActiveBranch,
    required this.character,
    required this.pathFromRoot,
  });

  Offset get center => Offset(x + width / 2, y + height / 2);
}

class _PathStep {
  final String messageId;
  final int variantIndex;
  const _PathStep(this.messageId, this.variantIndex);
}

class _NodeWidget extends StatelessWidget {
  final _TreeNode node;
  final String chatId;
  const _NodeWidget({required this.node, required this.chatId});

  @override
  Widget build(BuildContext context) {
    final isUser = node.message.kind == MessageKind.user;
    final isAux = node.message.kind == MessageKind.ooc ||
        node.message.kind == MessageKind.scene ||
        node.message.kind == MessageKind.system;
    // Dim nodes that aren't on the active branch so the user's "you
    // are here" trail is unambiguous.
    final dimAlpha = node.inActiveBranch ? 1.0 : 0.55;
    final color = isUser
        ? EmberColors.primary.withValues(alpha: 0.20 * dimAlpha)
        : EmberColors.bgPanel.withValues(alpha: dimAlpha);
    return Positioned(
      left: node.x,
      top: node.y,
      child: GestureDetector(
        // Wave CY.18.33 (Bug #2): tap now shows a preview/confirm
        // dialog before navigating. Pre-Wave, an accidental tap on a
        // node (panning/zooming the tree, fat-fingering) would
        // immediately switch the branch and jump the chat, potentially
        // losing the user's position in a long conversation.
        onTap: () async {
          final go = await _confirmJumpToNode(context, node);
          if (!go) return;
          // Wave CY.18.5: tapping a node now means "jump to THIS exact
          // message in the chat", not just "swap the branch at this
          // node's depth". We walk the path from the root applying
          // selectVariant at each step — this restores any stashed
          // ancestors so the target message lands in chat.messages —
          // then pop the tree screen with the message id as the
          // result. The chat screen scrolls to that id on resume.
          //
          // Wave CY.18.24: short-circuit on the first step where the
          // target message isn't found in chat.messages.
          if (!context.mounted) return;
          final store = context.read<AppStore>();
          String? deepestReached;
          for (final step in node.pathFromRoot) {
            final chat = store.chats.firstWhere(
              (c) => c.id == chatId,
              orElse: () => store.chats.isEmpty
                  ? throw StateError('no chats')
                  : store.chats.first,
            );
            final inChat =
                chat.messages.any((m) => m.id == step.messageId);
            if (!inChat) break;
            store.selectVariant(
                chatId, step.messageId, step.variantIndex);
            deepestReached = step.messageId;
          }
          // Prefer the user's tapped target when we actually reached
          // it; fall back to the deepest message we DID surface (so
          // the chat at least scrolls partway). Worst case (we
          // couldn't even reach the first step) just pop the tree.
          if (!context.mounted) return;
          final reachedTarget = deepestReached == node.message.id;
          Navigator.of(context)
              .pop<String>(reachedTarget ? node.message.id : deepestReached);
        },
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Opacity(
              opacity: dimAlpha,
              child: Container(
                width: node.width,
                height: node.height,
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: node.isSelected
                        ? EmberColors.primary
                        : EmberColors.stroke,
                    width: node.isSelected ? 2 : 1,
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (isAux)
                      const Icon(Icons.chat_outlined,
                          size: 18, color: EmberColors.textMid)
                    else
                      AvatarBubble(
                        dataUrl: isUser ? null : node.character?.avatar,
                        fallback:
                            isUser ? 'U' : (node.character?.name ?? '?'),
                        radius: 14,
                      ),
                    const SizedBox(height: 4),
                    Text(
                      node.message.variants.length > node.variantIndex
                          ? node.message.variants[node.variantIndex]
                          : '',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 10,
                        color: EmberColors.textHigh,
                        height: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Wave CY.18.33 (Bug #2): confirm dialog shown before a tree node tap
/// navigates the chat. Bottom-sheet shape because the tree is usually
/// mid-zoom/pan and the user's thumb is around the bottom of the
/// screen — modal dialogs would be a longer thumb travel. Shows a
/// preview of the message content (first ~280 chars) plus an
/// indication of role (User vs Character) and the path depth so the
/// user can sanity-check they tapped what they meant to.
Future<bool> _confirmJumpToNode(
    BuildContext context, _TreeNode node) async {
  final m = node.message;
  final isUser = m.kind == MessageKind.user;
  final preview = m.text.trim();
  final shortPreview = preview.length > 280
      ? '${preview.substring(0, 280)}…'
      : preview;
  final depth = node.pathFromRoot.length;
  final result = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: EmberColors.bgPanel,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheet) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    isUser ? Icons.person_outline : Icons.smart_toy_outlined,
                    size: 18,
                    color: isUser
                        ? EmberColors.primary
                        : EmberColors.textMid,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    isUser ? 'User message' : 'Character message',
                    style: const TextStyle(
                      color: EmberColors.textHigh,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    'Depth $depth',
                    style: const TextStyle(
                      color: EmberColors.textDim,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 220),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: EmberColors.bgDeep,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: EmberColors.stroke),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    shortPreview.isEmpty
                        ? '(empty message)'
                        : shortPreview,
                    style: const TextStyle(
                      color: EmberColors.textHigh,
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Jumping switches the active branch to land on this '
                'message and scrolls the chat to it. Anything currently '
                'visible after another branch point gets swapped out '
                '(it\'s not deleted — switching back restores it).',
                style: TextStyle(
                  color: EmberColors.textMid,
                  fontSize: 11.5,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(sheet).pop(false),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.north_east, size: 16),
                      label: const Text('Jump here'),
                      onPressed: () => Navigator.of(sheet).pop(true),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
  return result == true;
}

class _EdgePainter extends CustomPainter {
  final _Layout layout;
  _EdgePainter(this.layout);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = EmberColors.stroke
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final paintActive = Paint()
      ..color = EmberColors.primary.withValues(alpha: 0.7)
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke;

    for (final e in layout.edges) {
      final p0 = Offset(e.from.center.dx, e.from.y + e.from.height);
      final p3 = Offset(e.to.center.dx, e.to.y);
      final mid = (p0.dy + p3.dy) / 2;
      final p1 = Offset(p0.dx, mid);
      final p2 = Offset(p3.dx, mid);
      final path = Path()
        ..moveTo(p0.dx, p0.dy)
        ..cubicTo(p1.dx, p1.dy, p2.dx, p2.dy, p3.dx, p3.dy);
      canvas.drawPath(path, e.active ? paintActive : paint);
    }
  }

  @override
  bool shouldRepaint(covariant _EdgePainter oldDelegate) =>
      oldDelegate.layout != layout;
}
