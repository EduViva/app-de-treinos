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

## Comida

A aba **Comida** tem quatro partes:

- **Cardápio:** seis refeições com calorias e macros (P proteína, C carboidrato, G gordura) e o total do dia contra a meta. Toque numa refeição para escolher entre 3 opções, ver a tabela nutricional dela e os alimentos, mudar a quantidade ou trocar um alimento por outro do mesmo grupo (a quantidade é calculada para dar a mesma proteína, carboidrato ou gordura).
- **Buscar:** cerca de 100 alimentos com calorias e macros por porção usual ou por 100 g, filtro por grupo e ordem por proteína, carboidrato, gordura ou calorias. Cada alimento abre uma balança: digite ou ajuste a quantidade e a tabela nutricional acompanha. O que não estiver na lista dá para cadastrar pelo rótulo da embalagem.
- **Metas** e **Dicas:** a meta do dia e as orientações de sempre.

As escolhas do cardápio e os alimentos cadastrados ficam só neste aparelho (não vão para a conta). Os valores dos alimentos são médias arredondadas de tabelas de referência (TACO, USDA) e rótulos comuns; para produtos industrializados vale mais o rótulo.

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

A engrenagem no topo de **Progresso** abre as **Configurações**: conta, início do bloco de 12 semanas, bipe do cronômetro e backup.

**Entrar:** e-mail e senha (não envia e-mail, então não esbarra no limite de e-mails por hora do Supabase). **Criar conta** faz o cadastro pela mesma tela. Quem entrou pelo link por e-mail pode definir uma senha na própria tela de Conta. O link por e-mail continua disponível ("Receber link por e-mail"), mas o Supabase deixa o projeto enviar poucos e-mails por hora.

Depois do login, tudo o que você faz no app (séries, corridas, peso, troca do treino do dia, mover um registro, apagar) sobe para o Supabase e volta para os outros aparelhos.

- **Offline primeiro:** tudo é salvo no `localStorage` antes; o envio acontece cerca de 8 segundos depois de cada alteração, quando a rede volta e quando você reabre o app.
- **Exclusões:** apagar no app marca `deleted_at` no banco (o histórico fica) e apaga nos outros aparelhos.
- **Conflitos:** vale a alteração mais recente de cada dia (pelo relógio do aparelho). Se dois aparelhos editam o mesmo dia sem rede, o que foi salvo por último vence o dia inteiro.
- **Primeiro login de um aparelho:** baixa o que está na conta; se o aparelho já tinha dados de um dia, os dele vencem.
- **Gráficos:** o conteúdo fica nas tabelas de sempre, então as visões `v_*` já refletem tudo.

**Configuração no Supabase.** Para o cadastro não depender de e-mail, desligue *Confirm email* em Authentication > Providers > Email. Para o link por e-mail voltar ao app, em Authentication > URL Configuration: coloque o endereço do app, com a barra final (`https://eduviva.github.io/app-de-treinos/`), em *Site URL* e em *Redirect URLs*. O app pede ao Supabase que o link do e-mail volte para esse endereço (parâmetro `redirect_to`); se ele não estiver na lista de *Redirect URLs*, o Supabase ignora o pedido e manda para o *Site URL*. Se o link chegar sem `/app-de-treinos/`, é sinal de que o endereço não está na lista ou de que o *Site URL* está sem o caminho.

Limite: o cronômetro em andamento e o dia aberto na tela não sincronizam; o resto sim.
