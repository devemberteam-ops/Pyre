# Bug Status Matrix - 2026-06-14

This matrix does not claim live re-verification. Current environment lacks `flutter` and `dart` on PATH, so all unfixed items are marked pending fallback test/live retest unless there is an existing fix already visible in the worktree or fix log.

| ID | Severity | Area | Bug | 2026-06-14 status | Evidence / next proof |
| --- | --- | --- | --- | --- | --- |
| HIGH-1 | High | creator | Character/persona edit drops prose paragraph when later paragraph starts with `Word:` | Pending retest; documented as remaining | Run `test/creator_render_test.dart` and `test/creator_edit_preserve_test.dart`; then live Creator edit flow screenshot/log. |
| HIGH-2 | High | sync-server | `fullResync()` no-ops when a periodic tick is in flight | Fixed on disk, not re-run here | Worktree diff in `lib/services/sync_engine.dart` waits for `_tickInFlight` before zeroing; run `test/sync_watermark_test.dart` and key-sync live pair flow. |
| HIGH-3 | High | presets-memory | Editing modular preset strips block injection depth | Fixed per fix log and worktree | `lib/screens/presets_screen.dart` copies `depth: b.depth`; run prompt block/depth tests. |
| MED-1 | Medium | chat-runtime | Native Anthropic paths skip unsupported-param retry and `safeBodyFor` | Pending retest; documented as remaining | Run `test/chat_api_param_retry_test.dart` and real Anthropic call with rejected extra param. |
| MED-2 | Medium | creator | JSON trailing-comma cleanup corrupts string values containing `,}` / `,]` | Pending retest; documented as remaining | Run/add focused case in `test/creator_json_test.dart`. |
| MED-3 | Medium | creator | JSON continuation seam corrupts stitch when model re-emits object after outside-string partial | Pending retest; documented as remaining | Run/add focused case in `test/creator_build_pipeline_test.dart`. |
| MED-4 | Medium | sync-server | `/bbx/` reverse proxy is unauthenticated outbound fetch endpoint | Pending live retest; documented as remaining | Start LAN server, request `/bbx/` without bearer from LAN/client, expect auth denial after fix. |
| MED-5 | Medium | import-export | Lorebook import TypeError on off-spec field types aborts import | Pending retest; documented as remaining | Run/add focused case in `test/lorebook_import_test.dart`. |
| MED-6 | Medium | import-export | Export as PNG card fails when avatar is JPEG/WEBP/GIF | Pending retest; documented as remaining | Run PNG export tests and live export from gallery JPEG/WEBP avatar. |
| MED-7 | Medium | state-models | Attachment GC reaps blobs referenced only by per-chat character snapshots | Pending retest; documented as remaining | Run/add attachment GC snapshot retention test. |
| LOW-1 | Low | chat-runtime | Anthropic adapter hoists all system turns into top `system` field | Pending retest; documented as remaining | Run/add `test/anthropic_format_test.dart` case preserving intended ordering or explicitly documenting limitation. |
| LOW-2 | Low | sync-server | `_proxyBotbooru` leaks raw upstream/internal exception text in 500 bodies | Pending retest; documented as remaining | Unit/integration probe against `/bbx/` failure path. |
| LOW-3 | Low | import-export | Lightbox Save and gallery card-export write non-PNG bytes under `.png` mime/name | Pending retest; documented as remaining | Run live gallery save/export with JPEG/WEBP source. |
| LOW-4 | Low | presets-memory | Copy editable loses injection depth when cloning modular preset | Fixed per fix log and worktree | `lib/screens/presets_screen.dart` copies `depth: b.depth`; run depth clone test. |
| LOW-5 | Low | presets-memory | Out-of-range memoryLimit/autoEvery crashes Checkpoints slider | Pending retest; documented as remaining | Run/add slider clamp case for `long_term_memory_screen.dart`. |
| LOW-6 | Low | presets-memory | `parseRegexLiteral` mis-splits path-like pattern ending in slash+letters | Pending retest; documented as remaining | Run/update `test/regex_rules_test.dart`; current documented behavior may be codified by existing test. |
| LOW-7 | Low | state-models | Wrong-typed scalar in state blob throws out of `AppStore.load()` | Pending retest; documented as remaining | Run/add state load salvage test with wrong-typed scalar. |
| LOW-8 | Low | web-paths | Web `?import=` bookmarklet handoff unreachable | Pending live/web retest; documented as remaining | Launch web thin client and visit `?import=` URL; unit trace caller after fix. |
| LOW-9 | Low | web-paths | AvatarBubble negative-decode cache branch unreachable | Pending retest; duplicate of LOW-12 mechanism | Run/add avatar decode negative-cache test. |
| LOW-10 | Low | ui-widgets | Customize Chat `_SliderRow` feeds unclamped values to `Slider` | Pending retest; documented as remaining | Run/add widget test with out-of-range `ChatSettings`. |
| LOW-11 | Low | ui-widgets | `_BackdropImage` re-decodes raw-base64 backdrops every rebuild | Pending perf/visual retest; documented as remaining | Add decode-cache test or profile streaming rebuild with raw-base64 backdrop. |
| LOW-12 | Low | ui-widgets | `_decodeAvatar` cached-failure branch dead; malformed data avatars decode every rebuild | Pending retest; duplicate of LOW-9 mechanism | Run/add avatar decode negative-cache test and streaming rebuild visual check. |

## Already Fixed Count

The project brief says three documented bugs are already fixed:

- HIGH-2 sync fullResync race.
- HIGH-3 preset edit drops depth.
- LOW-4 preset Copy editable drops depth.

Those fixes are visible in the current dirty worktree but were not executed by this slice because Flutter/Dart is unavailable in the shell.

