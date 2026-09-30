# Contexto para o Claude Code

## Projeto
App pessoal de treino do Eduardo (25 anos, treina na Champion Body Gravataí). Hipertrofia em 30–40 min por sessão, 4 fichas por semana, e corrida rumo à meia maratona. Todo o texto da interface é em português do Brasil. Fale com o usuário em português.

## Front-end (`index.html`)
- Arquivo único, sem build e sem dependências. A única coisa externa é a fonte Archivo (Google Fonts, eixo de largura 62–125).
- Dados em `localStorage`:
  - `treino-eduardo-v2`: `{v:2, startDate, weights:[{date,kg,waist,arm}], sessions:{'AAAA-MM-DD':{sets:{exId:[{kg,reps,done,alt}]}, run:{km,min,sec,note,sw}, startedAt, finishedAt, plan}}, prefs:{sound}, activeDate, runDate}`
  - `treino-eduardo-v2-ui`: preferências de tela.
- Telas: `ficha`, `corrida`, `comida`, `progresso` (abas) e `config` (Configurações, aberta pela engrenagem do Progresso; conta, bloco de 12 semanas, bipe, backup). Configuração nova vai em `vConfig()`, não em Progresso.
- Login: e-mail e senha (`pwLogin`, `pwSignup`, `pwSave`) e link por e-mail (`sendLink`, limitado a poucos e-mails por hora no Supabase). `redirect_to` vai na URL do `/auth/v1/otp` e do `/auth/v1/signup`, nunca no corpo.
- Objetos principais:
  - `S`: fichas `infA`, `supA`, `infB`, `supB`, `treinoE`, `pescoco`. Os ids dos exercícios (`ia1`, `sa1`, …, `pc8`) são iguais a `template_items.legacy_code` no banco.
  - `RUN`: as 12 semanas de corrida.
  - `planFor(data)`: o que cai em cada dia, respeitando trocas e treinos movidos (`session.plan`).
- Visual:
  - Conceito de "ficha de treino" (cartolina colorida por treino).
  - Cores em tokens CSS no `:root`, com tema escuro.
  - Gráficos em SVG feito à mão; cores das séries em `--s1` e `--s2`.
- Uso real é no celular, com uma mão, entre séries. Botões grandes, pouco texto, nada que dependa de hover.

## Banco (Supabase)
- Projeto `sgqsriitdwmpylghrytx`, URL `https://sgqsriitdwmpylghrytx.supabase.co`.
- As migrations em `supabase/migrations/` já estão aplicadas. Mudanças novas entram como uma migration nova; não edite as antigas.
- Regras que valem para todas as tabelas:
  - Multiusuário com RLS em todas. `owner_id` nulo marca o catálogo público, somente leitura.
  - Registros pessoais usam `user_id = auth.uid()`.
  - O usuário anônimo (`anon`) não tem acesso a nada: todo acesso exige login.
- Sincronização:
  - Os ids são uuid gerados no aparelho.
  - `updated_at` resolve conflitos; `deleted_at` apaga sem perder o histórico.
  - `workout_sessions.local_date` é a data do calendário do usuário, nunca derivada de um horário UTC.
- Funções:
  - `sync_app(jsonb)` sincroniza nos dois sentidos (ver Próximos passos). `app_sync_meta` guarda versão, tombstone e plano de cada dia/peso/configuração.
  - `export_app_backup()` devolve os registros do usuário logado no formato do `localStorage` (inverso do import).
  - `clone_program(program_id, start_date)` copia o programa-modelo para o usuário e o inscreve nele.
  - `import_app_backup(jsonb)` importa o texto de "Copiar backup" do app (caminho antigo; o app não o chama mais). É idempotente pelo `source_key`.
- Visões para gráficos: `v_exercise_best_sets`, `v_weekly_volume`, `v_weekly_sets_by_muscle`.
- Na tela, a chave publicável (publishable key) pode ficar no código, porque o RLS protege os dados. A service role nunca vai para o front-end.

## Próximos passos
1. Publicar no GitHub Pages (instruções no README).
2. ~~Login com link mágico~~ feito (fetch direto ao GoTrue, sessão em `treino-eduardo-v2-auth`).
3. ~~Sincronização bidirecional~~ feita. `syncNow()` chama `sync_app` (envia o que mudou e recebe o que mudou desde `sy.cursor`). O app detecta mudanças por impressão digital de cada dia/peso (`detectChanges`), então troca de treino (`plan`), mover registro e apagar entram sem tratamento próprio; apagar vira tombstone e o banco preenche `deleted_at`. Estado da sincronização em `treino-eduardo-v2-sync`. Conflito: versão mais recente por dia (`v` = relógio do aparelho); `seq` do servidor entrega só o que mudou. Falta configurar Site URL/Redirect URLs no Supabase Auth (já feito para o GitHub Pages do Eduardo).
4. Se mexer no formato de um dia (`canonDay` no app, `app_day_doc`/`app_apply_day` no banco), mantenha os dois lados iguais.
5. Depois: gráficos lendo as visões do banco e telas para criar exercícios e fichas próprias.
