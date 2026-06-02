import 'package:flutter/material.dart';

import '../theme.dart';

/// Practical tips for using the AI Character Creator, shown by the "?"
/// icon inside the Creator itself. Kept short and actionable — the full
/// conceptual walkthrough (phases, building modes, how the build runs)
/// lives in More → Character Creator → "How the Character Creator works".
class CharacterCreatorHelpScreen extends StatelessWidget {
  const CharacterCreatorHelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Creator tips')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          _h1('Creator tips'),
          _p('Quick reference for while you\'re building. For a full '
              'explanation of how the Creator works — phases, building '
              'modes, background generation — open '
              'More → Character Creator → "How the Character Creator '
              'works".'),

          _h2('Attach buttons'),
          _p('In the input bar you have three icons before the text field:'),
          _bullet('🖼  Image — pick a reference picture. The vision '
              'model describes what the character looks like, then the '
              'assistant uses that profile as authoritative context. '
              'Requires a vision-capable provider (set one in '
              'More → API Connections).'),
          _bullet('📛  Character card — pick a chara_card_v2 PNG or JSON. '
              'The full metadata is injected into the conversation so '
              'you can edit an existing card or use it as a reference '
              '("make me a card like this one but darker").'),
          _bullet('📄  Document — pick a TXT, MD, or PDF. The full text '
              'is injected (no truncation). Useful for world lore, '
              'background docs, "here\'s the setting, build me an NPC '
              'that fits". PDFs that are scanned images won\'t work — '
              'we can\'t OCR yet.'),

          _h2('Tips that actually help'),
          _bullet('Start with a vibe, not a checklist. "broken princess, '
              'cold on the outside, soft underneath" gives the AI more '
              'to work with than "name: X, age: 18, hair: blonde".'),
          _bullet('If you have a reference image, attach it FIRST — '
              'before talking. The vision profile becomes context for '
              'every later question.'),
          _bullet('When refining, be specific. "Change her age to 22" '
              'works. "Make her older" makes the model guess.'),
          _bullet('If the assistant tries to be vanilla or dodges NSFW '
              'requests, your provider has refusal patterns. Switch to '
              'an uncensored model (DeepSeek, Venice, Soji, or any '
              'tune on Featherless/Arli/Infermatic).'),
          _bullet('The "Generate card now" button works any time. If '
              'the AI is asking too many questions, hit it whenever '
              'you\'re ready.'),
          _bullet('After the card is drafted, you can keep refining via '
              'chat — OR tap "Save and refine" to open the manual editor '
              'with all fields pre-populated, then tweak by hand.'),

          _h2('Honest section'),
          _p('Most people building cards in tools like this are doing '
              'roleplay that\'s adult, often explicit, often weird. '
              'That\'s fine — Pyre is built for that. The model you '
              'pick matters more than the prompt you write. Big-name '
              'commercial models (Claude, GPT) will dance around NSFW '
              'no matter how clever your prompt; open-weight models '
              'and uncensored hosts (DeepSeek direct, Venice, Soji, '
              'Featherless, Arli, Infermatic) just write what you ask. '
              'Pyre doesn\'t take a side here — your providers, your '
              'choice, your tokens.'),

          _h2('Troubleshooting'),
          _bullet('"No provider configured" — Open More → API Connections '
              'and add a provider first. Or set up via the onboarding '
              'wizard on fresh install.'),
          _bullet('"Image analysis failed" — your active provider doesn\'t '
              'support vision. Set a creator-specific vision provider '
              'in More → API Connections.'),
          _bullet('"The model returned something that isn\'t valid JSON" — '
              'the model wrapped the JSON in markdown fences (some models '
              'do this even when asked not to). Open the canvas — the '
              'raw output is there. Either paste it elsewhere, or ask '
              'the model to retry without the fences.'),
          _bullet('Card seems lobotomised after a small edit — your '
              'model probably ignored the "preserve every field" '
              'instruction and rewrote everything. Switch to a smarter '
              'model for edits (Claude or GPT are stricter than smaller '
              'tunes).'),
          _bullet('Generating takes forever — long card outputs can hit '
              '4-8k tokens. Increase Max Response Tokens in '
              'More → Character Creator → Generation settings.'),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  static Widget _h1(String text) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 4),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
      );

  static Widget _h2(String text) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 6),
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(
            color: EmberColors.primary,
            fontWeight: FontWeight.w700,
            fontSize: 11,
            letterSpacing: 1.2,
          ),
        ),
      );

  static Widget _p(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          text,
          style: const TextStyle(
            color: EmberColors.textHigh,
            fontSize: 13,
            height: 1.5,
          ),
        ),
      );

  static Widget _bullet(String text) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(right: 8, top: 6),
              child: Icon(Icons.circle, size: 4, color: EmberColors.textMid),
            ),
            Expanded(
              child: Text(
                text,
                style: const TextStyle(
                  color: EmberColors.textHigh,
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
            ),
          ],
        ),
      );
}
