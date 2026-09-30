# Ficha do Eduardo

App de treino para usar na academia pelo celular: fichas A–E de musculação (30–40 min), rotina de pescoço em casa, plano de corrida de 12 semanas rumo à meia maratona, cronômetros e gráficos de progresso.

## Estrutura

```
index.html                 o app inteiro (HTML, CSS e JS num arquivo só)
supabase/migrations/       banco de dados (Postgres no Supabase), na ordem em que foi aplicado
CLAUDE.md                  contexto para o Claude Code trabalhar no projeto
```

## Rodar no computador

Abra o `index.html` no navegador. Não precisa instalar nada.

## Publicar no celular (GitHub Pages)

1. No GitHub, abra o repositório e vá em **Settings > Pages**.
2. Em **Build and deployment**, escolha **Deploy from a branch**, branch `main`, pasta `/ (root)`, e salve.
3. Em um ou dois minutos o app fica em `https://SEU-USUARIO.github.io/NOME-DO-REPO/`.
4. No celular, abra esse endereço e use **Adicionar à tela de início**.

O endereço novo guarda os dados separado do artefato do Claude. Para levar o histórico, use **Copiar backup** no app antigo e **Restaurar** no novo.

## Banco de dados (Supabase)

Projeto `sgqsriitdwmpylghrytx` (Pessoal). As seis migrations desta pasta já estão aplicadas:

| Migration | O que faz |
|---|---|
| `esquema_inicial` | 16 tabelas, RLS em todas, gatilhos, funções `clone_program` e `import_app_backup`, visões para gráficos, permissões |
| `catalogo_exercicios` | 38 grupos musculares e 88 exercícios públicos |
| `programa_modelo` | programa de 12 semanas: fichas A–E e pescoço, agenda semanal e 24 corridas planejadas |
| `ajustes_desempenho` | índices e políticas ajustados pelo Supabase Advisor |
| `sincronizacao_bidirecional` | tabela `app_sync_meta` e funções `sync_app`, `app_apply_day`, `app_day_doc`: sincronização nos dois sentidos, com exclusões e troca de dia |
| `exportar_backup` | função `export_app_backup()`, o inverso de `import_app_backup`: devolve os registros do usuário no formato do app |

O banco é multiusuário: cada pessoa só enxerga os próprios registros, e o catálogo público é somente leitura.

## Conta e sincronização

Em **Progresso > Corpo > Conta** o app pede o e-mail e manda um link mágico (sem senha). Depois do login, tudo o que você faz no app (séries, corridas, peso, troca do treino do dia, mover um registro, apagar) sobe para o Supabase e volta para os outros aparelhos.

- **Offline primeiro:** tudo é salvo no `localStorage` antes; o envio acontece cerca de 8 segundos depois de cada alteração, quando a rede volta e quando você reabre o app.
- **Exclusões:** apagar no app marca `deleted_at` no banco (o histórico fica) e apaga nos outros aparelhos.
- **Conflitos:** vale a alteração mais recente de cada dia (pelo relógio do aparelho). Se dois aparelhos editam o mesmo dia sem rede, o que foi salvo por último vence o dia inteiro.
- **Primeiro login de um aparelho:** baixa o que está na conta; se o aparelho já tinha dados de um dia, os dele vencem.
- **Gráficos:** o conteúdo fica nas tabelas de sempre, então as visões `v_*` já refletem tudo.

**Configuração única no Supabase** (Authentication > URL Configuration): coloque o endereço do app, com a barra final (`https://eduviva.github.io/app-de-treinos/`), em *Site URL* e em *Redirect URLs*. O app pede ao Supabase que o link do e-mail volte para esse endereço (parâmetro `redirect_to`); se ele não estiver na lista de *Redirect URLs*, o Supabase ignora o pedido e manda para o *Site URL*. Se o link chegar sem `/app-de-treinos/`, é sinal de que o endereço não está na lista ou de que o *Site URL* está sem o caminho.

Limite: o cronômetro em andamento e o dia aberto na tela não sincronizam; o resto sim.
