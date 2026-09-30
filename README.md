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

Projeto `sgqsriitdwmpylghrytx` (Pessoal). As quatro migrations desta pasta já estão aplicadas:

| Migration | O que faz |
|---|---|
| `esquema_inicial` | 16 tabelas, RLS em todas, gatilhos, funções `clone_program` e `import_app_backup`, visões para gráficos, permissões |
| `catalogo_exercicios` | 38 grupos musculares e 88 exercícios públicos |
| `programa_modelo` | programa de 12 semanas: fichas A–E e pescoço, agenda semanal e 24 corridas planejadas |
| `ajustes_desempenho` | índices e políticas ajustados pelo Supabase Advisor |

O banco é multiusuário: cada pessoa só enxerga os próprios registros, e o catálogo público é somente leitura.

O app ainda salva só no aparelho. A sincronização com o Supabase é o próximo passo (veja `CLAUDE.md`).
