# Ember Team — Estado & Plano (Pyre)

> CEO/orquestrador: Claude. Início do modo-empresa: 2026-06-13.
> Base segura: branch `release/1.1.3` @ `eb21efe` (verde: analyze 0 + 1407 testes).
> Público: `main` @ `47ebac5` = Pyre **1.1.2**. NADA publica sem OK do Kuru.

## Decisões do Kuru (gate-0, 2026-06-13)
1. **Checkpoint:** SIM — commitar a leva 1.1.3 em `release/1.1.3` (feito).
2. **Ordem:** **Verificar + caçar bugs PRIMEIRO** (de-riscar a base); perf + personalização na onda seguinte.
3. **Personalização (onda 2):** vários de uma vez — tema/cores + raw-output viewer + outros.
4. **Embed botbooru:** segue em paralelo (caminho front-end), aceitando risco de refazer conforme a resposta do Izanagi.

## Onde estamos (honesto)
- 1.1.3 = leva GRANDE, recém-checkpointada, **pouco provada em runtime real**. Itens de risco:
  - Adaptador **Anthropic**: código verde, **sem teste com chave real**.
  - **Web**: avatar/galeria/streaming/download "verdes" mas o cache do service worker mascarou validação na sessão.
  - **Bug GLM/NIM (Lukachew)**: timeout connect 25s < TTFT 40-60s — diagnosticado, **NÃO corrigido**.
  - **Embed botbooru**: proxy `/bbx/` prova navegação+imagens; import/upload não construídos.

## Disciplinas inegociáveis
- Quem verifica ≠ quem produziu. Front se prova OLHANDO (screenshot do real), nunca "deveria funcionar".
- CEO lê o DIFF/código real, nunca confia no relatório do agente, e NÃO implementa.
- Quem escreve o plano ≠ quem aprova.
- Pesquise antes de assumir; TESTE, não teorize.
- Estado vital no DISCO. Enxuto > cerimônia.
- Memória é HIPÓTESE, não verdade (lição: "Gui"→Kuru, "botbooru é nosso"→terceiro).
- Sensibilidade da casa: calor/charme/criatividade linha Toriyama/Ghibli/JRPG — prior, não regra.

## Onda atual — DE-RISK (verificar + 25 bugs)
- **Caça a bugs (estática):** fan-out de finders em fatias DISJUNTAS → verificação adversária (refutar cada bug) → CEO lê o código real dos confirmados → lista de bugs reais (alvo ~25) neste mesmo diretório (`bugs-found.md`).
- **Verificação de runtime (precisa rodar o app):** Anthropic (chave do Kuru), web (Dev web + browser), embed — fica com o CEO + Dev build/computer-use; alguns dependem do Kuru.
- **Em paralelo:** thread do embed botbooru (import/upload, front-end path).

## Onda 2 (depois) — Perf + Personalização
- Perf: medir antes (não chutar) — hotspots reais.
- Personalização: tema/cores + raw viewer + outros, vários de uma vez.

## Papéis (subagentes)
- **Descoberta** (premissa/porquê/pesquisa antes de codar) · **Dev** (fatias disjuntas, back≠front, worktrees, cada um seu "done") · **Testes** (valida como usuário, pode reprovar).

---
## ENV NOTE (Chefe, 2026-06-14) — for the HQ seats
- `flutter` is NOT on PATH in seat shells. It lives at `C:\Users\Gui\flutter\bin\flutter.bat`. Prepend it in PowerShell: `$env:Path = "C:\Users\Gui\flutter\bin;" + $env:Path`. Run only ONE flutter analyze/test at a time (overlap corrupts .dart_tool).
- Headless seats CANNOT run the desktop GUI / take real-app screenshots. The visual "see the app" QA is owned by the Chefe (computer-use on the real machine) or the founder — not the headless team. The web build can be screenshotted via a headless browser if needed.
- VERIFIED GREEN @ 2026-06-14: analyze 0 + 1411 tests. Fixed so far (of 22): #1 Creator data-loss (HIGH, root-cause decompose fix), #2 sync race (HIGH), #5/#6 JSON, #3/#14 preset depth.
- WAVE 2 SHIPPED (local) @ 2026-06-14 — commit `1addc1f` on release/1.1.3 (NOT published). Kuru re-framed from deleite/UX to substance: perf + verify-new-features + Creator/real bugs + OOC. Closed ~10 more of the 22 (perf streaming flicker: avatar+lightbox decode caches; Anthropic adapter param-retry + post-history system placement; robustez: load-crash guard, lorebook import casts, PNG export transcode, 2 slider clamps, GC snapshot avatars) PLUS founder features: OOC+Scene now behave like real messages (edit/delete/branch/swipe, regen stays char-only) and mobile haptics. Verified: analyze 0 + **1495 tests** + independent verifier PASS on all 4 slices + CEO read the 2 biggest diffs. Detail in bugs-found.md FIX LOG + 2026-06-14-improvement-discovery.md.
- STILL OPEN (deferred by judgment): MEDIUM #4 /bbx unauth endpoint + LOW /bbx error leak (LAN security — handle with care, separate); LOW gallery png-mime (cosmetic); LOW regex parse path-like edge; LOW web `?import=` dead code. NOT runtime-tested on the live GUI — the hands-on visual "feel" pass (haptics/flicker/OOC) is Kuru-gated to a later turn (he said "depois").
