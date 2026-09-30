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

Projeto `sgqsriitdwmpylghrytx` (Pessoal). As cinco migrations desta pasta já estão aplicadas:

| Migration | O que faz |
|---|---|
| `esquema_inicial` | 16 tabelas, RLS em todas, gatilhos, funções `clone_program` e `import_app_backup`, visões para gráficos, permissões |
| `catalogo_exercicios` | 38 grupos musculares e 88 exercícios públicos |
| `programa_modelo` | programa de 12 semanas: fichas A–E e pescoço, agenda semanal e 24 corridas planejadas |
| `ajustes_desempenho` | índices e políticas ajustados pelo Supabase Advisor |
| `exportar_backup` | função `export_app_backup()`, o inverso de `import_app_backup`: devolve os registros do usuário no formato do app |

O banco é multiusuário: cada pessoa só enxerga os próprios registros, e o catálogo público é somente leitura.

## Conta e sincronização

Em **Progresso > Corpo > Conta** o app pede o e-mail e manda um link mágico (sem senha). Depois do login, os registros do aparelho são enviados ao Supabase com `import_app_backup` (idempotente), de forma automática alguns segundos depois de cada alteração e quando a rede volta. Tudo continua salvo no `localStorage` primeiro.

**Configuração única no Supabase** (Authentication > URL Configuration): coloque o endereço do app no GitHub Pages em *Site URL* e em *Redirect URLs*. Sem isso o link do e-mail não volta para o app.

**Caminho de volta.** No primeiro login de cada aparelho, o app baixa os registros da conta (`export_app_backup`) e junta com o que já existe, antes de enviar. O que está no aparelho nunca é sobrescrito: só entram dias, exercícios, corridas e pesos que faltam aqui. O botão **Baixar do banco** repete isso quando quiser.

Limites: a troca ou mudança de dia de um treino e o cronômetro em andamento não são guardados no banco, então não voltam. Apagar um registro no aparelho não apaga no banco, e ele pode voltar no próximo download.
