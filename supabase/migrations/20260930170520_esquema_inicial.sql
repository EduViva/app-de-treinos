-- =====================================================================
-- Ficha: esquema inicial (Supabase / Postgres 15+)
-- Multiusuário desde o início: cada linha pertence a um usuário
-- (user_id / owner_id) e o RLS garante que ninguém vê o que é de outro.
-- Linhas com owner_id NULL são o catálogo público (exercícios e
-- programas-modelo), só de leitura para os usuários.
--
-- Convenções
--   * ids uuid podem ser gerados no aparelho (offline) e enviados prontos.
--   * created_at / updated_at / deleted_at em tudo que sincroniza:
--     updated_at resolve conflitos, deleted_at apaga sem perder o
--     histórico de sincronização.
--   * Datas de treino são guardadas como data local do usuário
--     (local_date), nunca derivadas de um timestamp em UTC.
--   * Tipos enumerados como text + check: mais fácil de evoluir.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- Utilitário: atualiza updated_at em todo UPDATE
-- ---------------------------------------------------------------------
create or replace function public.tg_set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- Perfis (1 por usuário do Supabase Auth)
-- ---------------------------------------------------------------------
create table public.profiles (
  id            uuid primary key references auth.users (id) on delete cascade,
  display_name  text,
  timezone      text not null default 'America/Sao_Paulo',
  height_cm     numeric(5,1) check (height_cm between 50 and 250),
  unit_weight   text not null default 'kg'  check (unit_weight in ('kg','lb')),
  unit_distance text not null default 'km'  check (unit_distance in ('km','mi')),
  settings      jsonb not null default '{}'::jsonb,   -- ex.: {"rest_beep": true}
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
comment on column public.profiles.timezone is 'Fuso do usuário. Define o que é "hoje" para os registros.';

-- cria o perfil automaticamente quando alguém se cadastra
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'name', split_part(new.email, '@', 1)))
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------
-- Grupos musculares (catálogo fixo, hierárquico: grupo > subgrupo)
-- ---------------------------------------------------------------------
create table public.muscle_groups (
  id        uuid primary key default gen_random_uuid(),
  slug      text not null unique,
  name      text not null,
  parent_id uuid references public.muscle_groups (id) on delete restrict,
  position  smallint not null default 0
);

-- ---------------------------------------------------------------------
-- Exercícios: catálogo público (owner_id null) + exercícios do usuário
-- ---------------------------------------------------------------------
create table public.exercises (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid references auth.users (id) on delete cascade,  -- null = catálogo
  slug         text not null,
  name         text not null,
  measure      text not null default 'weight_reps'
               check (measure in ('weight_reps','reps','time','distance')),
  category     text not null default 'strength'
               check (category in ('strength','mobility','isometric','cardio')),
  equipment    text,          -- barra, halteres, polia, máquina, elástico, peso corporal...
  unilateral   boolean not null default false,
  instructions text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  deleted_at   timestamptz
);
create unique index exercises_catalog_slug_uq on public.exercises (slug) where owner_id is null;
create unique index exercises_owner_slug_uq   on public.exercises (owner_id, slug) where owner_id is not null;
create index exercises_owner_idx on public.exercises (owner_id);

create table public.exercise_muscles (
  exercise_id     uuid not null references public.exercises (id) on delete cascade,
  muscle_group_id uuid not null references public.muscle_groups (id) on delete restrict,
  is_primary      boolean not null default true,
  primary key (exercise_id, muscle_group_id)
);
create index exercise_muscles_muscle_idx on public.exercise_muscles (muscle_group_id);

-- ---------------------------------------------------------------------
-- Programas (plano de N semanas) e fichas (treino A, B, C...)
-- ---------------------------------------------------------------------
create table public.programs (
  id            uuid primary key default gen_random_uuid(),
  owner_id      uuid references auth.users (id) on delete cascade,  -- null = modelo público
  slug          text,
  name          text not null,
  description   text,
  weeks         smallint not null default 12 check (weeks between 1 and 104),
  deload_week   smallint check (deload_week between 1 and 104),
  deload_factor numeric(3,2) not null default 0.60 check (deload_factor > 0 and deload_factor <= 1),
  visibility    text not null default 'private' check (visibility in ('private','unlisted','public')),
  source_program_id uuid references public.programs (id) on delete set null,  -- de qual modelo foi copiado
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  deleted_at    timestamptz
);
create unique index programs_catalog_slug_uq on public.programs (slug) where owner_id is null and slug is not null;
create index programs_owner_idx on public.programs (owner_id);

create table public.workout_templates (
  id          uuid primary key default gen_random_uuid(),
  program_id  uuid not null references public.programs (id) on delete cascade,
  owner_id    uuid references auth.users (id) on delete cascade,  -- igual ao do programa
  code        text not null,             -- 'A', 'B', ... 'P'
  name        text not null,
  focus       text,
  kind        text not null default 'strength' check (kind in ('strength','mobility')),
  color       text,                      -- cor da cartolina, ex.: '#F3D65C'
  est_minutes smallint,
  position    smallint not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  deleted_at  timestamptz,
  unique (program_id, code)
);
create index workout_templates_owner_idx on public.workout_templates (owner_id);

create table public.template_blocks (
  id           uuid primary key default gen_random_uuid(),
  template_id  uuid not null references public.workout_templates (id) on delete cascade,
  owner_id     uuid references auth.users (id) on delete cascade,
  position     smallint not null,
  block_type   text not null check (block_type in ('single','superset','triset','circuit')),
  rest_seconds smallint not null default 60 check (rest_seconds between 0 and 900),
  optional     boolean not null default false,
  note         text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  deleted_at   timestamptz,
  unique (template_id, position)
);
create index template_blocks_owner_idx on public.template_blocks (owner_id);

create table public.template_items (
  id            uuid primary key default gen_random_uuid(),
  block_id      uuid not null references public.template_blocks (id) on delete cascade,
  owner_id      uuid references auth.users (id) on delete cascade,
  position      smallint not null,
  exercise_id   uuid not null references public.exercises (id) on delete restrict,
  sets          smallint not null check (sets between 1 and 20),
  rep_min       smallint check (rep_min between 0 and 500),
  rep_max       smallint check (rep_max between 0 and 500),
  target_text   text not null,           -- como aparece na ficha: '8–12', '30 s cada lado'
  rir           text,
  intensity_note text,
  side_label    text,                    -- 'cada lado', 'cada direção'
  deload_exempt boolean not null default false,
  legacy_code   text,                    -- id da versão local do app (ex.: 'sa1'), usado na importação
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  deleted_at    timestamptz,
  unique (block_id, position),
  check (rep_max is null or rep_min is null or rep_max >= rep_min)
);
create index template_items_owner_idx on public.template_items (owner_id);
create index template_items_exercise_idx on public.template_items (exercise_id);

-- alternativas de cada item (a principal fica em template_items.exercise_id)
create table public.template_item_alternatives (
  item_id     uuid not null references public.template_items (id) on delete cascade,
  exercise_id uuid not null references public.exercises (id) on delete restrict,
  owner_id    uuid references auth.users (id) on delete cascade,
  position    smallint not null default 1,
  primary key (item_id, exercise_id)
);
create index template_item_alternatives_ex_idx on public.template_item_alternatives (exercise_id);

-- agenda semanal do programa: o que cai em cada dia da semana
create table public.program_schedule (
  id          uuid primary key default gen_random_uuid(),
  program_id  uuid not null references public.programs (id) on delete cascade,
  owner_id    uuid references auth.users (id) on delete cascade,
  weekday     smallint not null check (weekday between 0 and 6),   -- 0 = domingo
  activity    text not null check (activity in ('strength','mobility','run','rest')),
  template_id uuid references public.workout_templates (id) on delete set null,
  run_type    text check (run_type in ('quality','long','easy')),
  unique (program_id, weekday),
  check ((activity in ('strength','mobility')) = (template_id is not null)),
  check ((activity = 'run') = (run_type is not null))
);

-- corridas planejadas semana a semana
create table public.planned_runs (
  id           uuid primary key default gen_random_uuid(),
  program_id   uuid not null references public.programs (id) on delete cascade,
  owner_id     uuid references auth.users (id) on delete cascade,
  week_number  smallint not null check (week_number between 1 and 104),
  run_type     text not null check (run_type in ('quality','long','easy')),
  name         text not null,
  distance_km  numeric(5,2) check (distance_km > 0),
  workout_type text,           -- acel, fartlek, limiar, intervalado, leve
  purpose      text,
  feel         text,
  steps        jsonb not null default '[]'::jsonb,  -- [{"label","what","pace"}]
  easy_week    boolean not null default false,
  unique (program_id, week_number, run_type)
);

-- em qual programa o usuário está e desde quando
create table public.program_enrollments (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users (id) on delete cascade,
  program_id uuid not null references public.programs (id) on delete cascade,
  start_date date not null,
  status     text not null default 'active' check (status in ('active','paused','finished')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index program_enrollments_one_active on public.program_enrollments (user_id) where status = 'active';

-- ---------------------------------------------------------------------
-- Registros: sessões, séries, corridas, medidas
-- ---------------------------------------------------------------------
create table public.workout_sessions (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null references auth.users (id) on delete cascade,
  local_date          date not null,          -- dia do treino no calendário do usuário
  activity            text not null check (activity in ('strength','mobility','run')),
  program_id          uuid references public.programs (id) on delete set null,
  template_id         uuid references public.workout_templates (id) on delete set null,
  planned_template_id uuid references public.workout_templates (id) on delete set null,  -- o que o plano previa (para "treino trocado")
  planned_run_id      uuid references public.planned_runs (id) on delete set null,
  started_at          timestamptz,
  finished_at         timestamptz,
  notes               text,
  source_key          text,                   -- chave de importação idempotente
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  deleted_at          timestamptz,
  unique (id, user_id),
  check (finished_at is null or started_at is null or finished_at >= started_at)
);
create index workout_sessions_user_date_idx on public.workout_sessions (user_id, local_date desc);
create index workout_sessions_user_updated_idx on public.workout_sessions (user_id, updated_at);
create unique index workout_sessions_source_uq on public.workout_sessions (user_id, source_key) where source_key is not null;

create table public.session_sets (
  id               uuid primary key default gen_random_uuid(),
  session_id       uuid not null,
  user_id          uuid not null,
  template_item_id uuid references public.template_items (id) on delete set null,
  exercise_id      uuid not null references public.exercises (id) on delete restrict,  -- o que foi feito de fato
  is_alternative   boolean not null default false,
  set_index        smallint not null check (set_index between 0 and 50),
  weight_kg        numeric(6,2) check (weight_kg >= 0 and weight_kg < 1000),
  reps             smallint check (reps between 0 and 1000),
  duration_s       integer check (duration_s between 0 and 86400),
  rir              smallint check (rir between -1 and 10),
  completed_at     timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  deleted_at       timestamptz,
  -- a série pertence ao mesmo usuário da sessão
  foreign key (session_id, user_id) references public.workout_sessions (id, user_id) on delete cascade
);
create index session_sets_session_idx on public.session_sets (session_id, set_index);
create index session_sets_user_exercise_idx on public.session_sets (user_id, exercise_id, completed_at desc);
create index session_sets_user_updated_idx on public.session_sets (user_id, updated_at);
create index session_sets_item_idx on public.session_sets (template_item_id);

create table public.session_runs (
  session_id    uuid primary key,
  user_id       uuid not null,
  distance_km   numeric(6,2) not null check (distance_km > 0 and distance_km < 500),
  duration_s    integer check (duration_s > 0 and duration_s < 172800),
  pace_s_per_km numeric(7,1) generated always as (case when duration_s is null then null else round(duration_s / distance_km, 1) end) stored,
  source        text not null default 'manual' check (source in ('manual','stopwatch','watch','import')),
  notes         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  foreign key (session_id, user_id) references public.workout_sessions (id, user_id) on delete cascade
);
create index session_runs_user_idx on public.session_runs (user_id);

create table public.body_measurements (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users (id) on delete cascade,
  measured_on  date not null,
  weight_kg    numeric(5,2) check (weight_kg between 20 and 400),
  waist_cm     numeric(5,1) check (waist_cm between 30 and 250),
  arm_cm       numeric(5,1) check (arm_cm between 10 and 80),
  body_fat_pct numeric(4,1) check (body_fat_pct between 2 and 70),
  source       text not null default 'manual' check (source in ('manual','watch','scale','import')),
  notes        text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  deleted_at   timestamptz,
  unique (user_id, measured_on, source)
);
create index body_measurements_user_idx on public.body_measurements (user_id, measured_on desc);

-- ---------------------------------------------------------------------
-- updated_at automático
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['profiles','exercises','programs','workout_templates','template_blocks',
                           'template_items','program_enrollments','workout_sessions','session_sets',
                           'session_runs','body_measurements']
  loop
    execute format('create trigger set_updated_at before update on public.%I
                    for each row execute function public.tg_set_updated_at()', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------
alter table public.profiles                   enable row level security;
alter table public.muscle_groups              enable row level security;
alter table public.exercises                  enable row level security;
alter table public.exercise_muscles           enable row level security;
alter table public.programs                   enable row level security;
alter table public.workout_templates          enable row level security;
alter table public.template_blocks            enable row level security;
alter table public.template_items             enable row level security;
alter table public.template_item_alternatives enable row level security;
alter table public.program_schedule           enable row level security;
alter table public.planned_runs               enable row level security;
alter table public.program_enrollments        enable row level security;
alter table public.workout_sessions           enable row level security;
alter table public.session_sets               enable row level security;
alter table public.session_runs               enable row level security;
alter table public.body_measurements          enable row level security;

-- perfil: só o próprio
create policy profiles_select on public.profiles for select to authenticated using (id = (select auth.uid()));
create policy profiles_update on public.profiles for update to authenticated using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- catálogo de músculos: leitura para todos os logados
create policy muscle_groups_select on public.muscle_groups for select to authenticated using (true);

-- exercícios: vê o catálogo + os seus; escreve só os seus
create policy exercises_select on public.exercises for select to authenticated
  using (owner_id is null or owner_id = (select auth.uid()));
create policy exercises_insert on public.exercises for insert to authenticated
  with check (owner_id = (select auth.uid()));
create policy exercises_update on public.exercises for update to authenticated
  using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
create policy exercises_delete on public.exercises for delete to authenticated
  using (owner_id = (select auth.uid()));

create policy exercise_muscles_select on public.exercise_muscles for select to authenticated
  using (exists (select 1 from public.exercises e where e.id = exercise_id and (e.owner_id is null or e.owner_id = (select auth.uid()))));
create policy exercise_muscles_write on public.exercise_muscles for all to authenticated
  using (exists (select 1 from public.exercises e where e.id = exercise_id and e.owner_id = (select auth.uid())))
  with check (exists (select 1 from public.exercises e where e.id = exercise_id and e.owner_id = (select auth.uid())));

-- programas: vê modelos públicos (owner null ou visibility public) + os seus
create policy programs_select on public.programs for select to authenticated
  using (owner_id is null or owner_id = (select auth.uid()) or visibility = 'public');
create policy programs_insert on public.programs for insert to authenticated with check (owner_id = (select auth.uid()));
create policy programs_update on public.programs for update to authenticated
  using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
create policy programs_delete on public.programs for delete to authenticated using (owner_id = (select auth.uid()));

-- filhos do programa: mesma regra, pela coluna owner_id copiada do programa
do $$
declare t text;
begin
  foreach t in array array['workout_templates','template_blocks','template_items',
                           'template_item_alternatives','program_schedule','planned_runs']
  loop
    execute format($f$
      create policy %1$s_select on public.%1$I for select to authenticated
        using (owner_id is null or owner_id = (select auth.uid()));
      create policy %1$s_insert on public.%1$I for insert to authenticated
        with check (owner_id = (select auth.uid()));
      create policy %1$s_update on public.%1$I for update to authenticated
        using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
      create policy %1$s_delete on public.%1$I for delete to authenticated
        using (owner_id = (select auth.uid()));
    $f$, t);
  end loop;
end $$;

-- programas públicos de outros usuários: filhos visíveis quando o programa é público
create policy workout_templates_public on public.workout_templates for select to authenticated
  using (exists (select 1 from public.programs p where p.id = program_id and p.visibility = 'public'));

-- registros pessoais: só o próprio usuário, em tudo
do $$
declare t text;
begin
  foreach t in array array['program_enrollments','workout_sessions','session_sets','session_runs','body_measurements']
  loop
    execute format($f$
      create policy %1$s_own on public.%1$I for all to authenticated
        using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
    $f$, t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Copiar um programa-modelo para o usuário (cada um edita o seu)
-- ---------------------------------------------------------------------
create or replace function public.clone_program(p_program_id uuid, p_start_date date default current_date)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_new uuid;
  r_t record; r_b record; r_i record;
  v_t uuid; v_b uuid; v_i uuid;
begin
  if v_uid is null then raise exception 'É preciso estar logado.'; end if;

  insert into public.programs (owner_id, name, description, weeks, deload_week, deload_factor, visibility, source_program_id)
  select v_uid, name, description, weeks, deload_week, deload_factor, 'private', id
  from public.programs where id = p_program_id
  returning id into v_new;
  if v_new is null then raise exception 'Programa não encontrado.'; end if;

  for r_t in select * from public.workout_templates where program_id = p_program_id and deleted_at is null order by position loop
    insert into public.workout_templates (program_id, owner_id, code, name, focus, kind, color, est_minutes, position)
    values (v_new, v_uid, r_t.code, r_t.name, r_t.focus, r_t.kind, r_t.color, r_t.est_minutes, r_t.position)
    returning id into v_t;

    insert into public.program_schedule (program_id, owner_id, weekday, activity, template_id, run_type)
    select v_new, v_uid, weekday, activity, v_t, run_type
    from public.program_schedule where program_id = p_program_id and template_id = r_t.id;

    for r_b in select * from public.template_blocks where template_id = r_t.id and deleted_at is null order by position loop
      insert into public.template_blocks (template_id, owner_id, position, block_type, rest_seconds, optional, note)
      values (v_t, v_uid, r_b.position, r_b.block_type, r_b.rest_seconds, r_b.optional, r_b.note)
      returning id into v_b;

      for r_i in select * from public.template_items where block_id = r_b.id and deleted_at is null order by position loop
        insert into public.template_items (block_id, owner_id, position, exercise_id, sets, rep_min, rep_max, target_text,
                                           rir, intensity_note, side_label, deload_exempt, legacy_code)
        values (v_b, v_uid, r_i.position, r_i.exercise_id, r_i.sets, r_i.rep_min, r_i.rep_max, r_i.target_text,
                r_i.rir, r_i.intensity_note, r_i.side_label, r_i.deload_exempt, r_i.legacy_code)
        returning id into v_i;

        insert into public.template_item_alternatives (item_id, exercise_id, owner_id, position)
        select v_i, exercise_id, v_uid, position from public.template_item_alternatives where item_id = r_i.id;
      end loop;
    end loop;
  end loop;

  -- dias sem ficha (corrida, descanso)
  insert into public.program_schedule (program_id, owner_id, weekday, activity, template_id, run_type)
  select v_new, v_uid, weekday, activity, null, run_type
  from public.program_schedule where program_id = p_program_id and template_id is null;

  insert into public.planned_runs (program_id, owner_id, week_number, run_type, name, distance_km, workout_type, purpose, feel, steps, easy_week)
  select v_new, v_uid, week_number, run_type, name, distance_km, workout_type, purpose, feel, steps, easy_week
  from public.planned_runs where program_id = p_program_id;

  update public.program_enrollments set status = 'finished' where user_id = v_uid and status = 'active';
  insert into public.program_enrollments (user_id, program_id, start_date) values (v_uid, v_new, p_start_date);

  return v_new;
end;
$$;

-- ---------------------------------------------------------------------
-- Importar o backup do app atual (texto de "Copiar backup")
-- Idempotente: importar de novo substitui o que veio do backup.
-- ---------------------------------------------------------------------
create or replace function public.import_app_backup(p jsonb, p_template_slug text default 'ficha-hipertrofia-meia-12s')
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_prog uuid;
  v_start date := coalesce(nullif(p ->> 'startDate','')::date, current_date);
  d text; sess jsonb; code text; arr jsonb; x jsonb; idx int;
  v_sid uuid; v_item record; v_alt uuid; v_ex uuid; v_tpl uuid; v_act text;
  v_run jsonb; v_km numeric; v_dur int;
  n_sess int := 0; n_sets int := 0; n_runs int := 0; n_meas int := 0;
  v_key text;
begin
  if v_uid is null then raise exception 'É preciso estar logado.'; end if;

  select e.program_id into v_prog from public.program_enrollments e
   where e.user_id = v_uid and e.status = 'active' limit 1;
  if v_prog is null then
    v_prog := public.clone_program((select id from public.programs where slug = p_template_slug and owner_id is null), v_start);
  end if;

  for d, sess in select key, value from jsonb_each(coalesce(p -> 'sessions', '{}'::jsonb)) loop
    -- musculação / pescoço: agrupa as séries feitas pela ficha a que pertencem
    for v_tpl in
      select distinct b.template_id
      from jsonb_each(coalesce(sess -> 'sets','{}'::jsonb)) s(code, arr)
      join public.template_items i on i.legacy_code = s.code
      join public.template_blocks b on b.id = i.block_id
      join public.workout_templates t on t.id = b.template_id and t.program_id = v_prog
      where exists (select 1 from jsonb_array_elements(s.arr) z where (z ->> 'done')::boolean)
    loop
      select case when kind = 'mobility' then 'mobility' else 'strength' end into v_act
        from public.workout_templates where id = v_tpl;
      v_key := 'backup:' || d || ':' || v_tpl;
      delete from public.workout_sessions where user_id = v_uid and source_key = v_key;
      insert into public.workout_sessions (user_id, local_date, activity, program_id, template_id, started_at, finished_at, source_key)
      values (v_uid, d::date, v_act, v_prog, v_tpl,
              case when sess ? 'startedAt' and jsonb_typeof(sess -> 'startedAt') = 'number' then to_timestamp((sess ->> 'startedAt')::bigint / 1000.0) end,
              case when sess ? 'finishedAt' and jsonb_typeof(sess -> 'finishedAt') = 'number' then to_timestamp((sess ->> 'finishedAt')::bigint / 1000.0) end,
              v_key)
      returning id into v_sid;
      n_sess := n_sess + 1;

      for code, arr in select key, value from jsonb_each(sess -> 'sets') loop
        select i.* into v_item from public.template_items i
          join public.template_blocks b on b.id = i.block_id
         where i.legacy_code = code and b.template_id = v_tpl;
        continue when not found;
        select exercise_id into v_alt from public.template_item_alternatives where item_id = v_item.id order by position limit 1;
        idx := 0;
        for x in select value from jsonb_array_elements(arr) loop
          if coalesce((x ->> 'done')::boolean, false) then
            v_ex := case when coalesce((x ->> 'alt')::boolean, false) and v_alt is not null then v_alt else v_item.exercise_id end;
            insert into public.session_sets (session_id, user_id, template_item_id, exercise_id, is_alternative, set_index,
                                             weight_kg, reps, duration_s, completed_at)
            select v_sid, v_uid, v_item.id, v_ex, coalesce((x ->> 'alt')::boolean, false), idx,
                   nullif(replace(x ->> 'kg', ',', '.'), '')::numeric,
                   case when m.measure = 'time' then null else nullif(x ->> 'reps', '')::numeric::smallint end,
                   case when m.measure = 'time' then nullif(x ->> 'reps', '')::numeric::int end,
                   null
            from (select measure from public.exercises where id = v_item.exercise_id) m;
            n_sets := n_sets + 1;
          end if;
          idx := idx + 1;
        end loop;
      end loop;
    end loop;

    -- corrida
    v_run := sess -> 'run';
    v_km := nullif(replace(coalesce(v_run ->> 'km', ''), ',', '.'), '')::numeric;
    if v_km is not null and v_km > 0 then
      v_dur := coalesce(nullif(v_run ->> 'min', '')::numeric, 0)::int * 60 + coalesce(nullif(v_run ->> 'sec', '')::numeric, 0)::int;
      v_key := 'backup:' || d || ':run';
      delete from public.workout_sessions where user_id = v_uid and source_key = v_key;
      insert into public.workout_sessions (user_id, local_date, activity, program_id, notes, source_key)
      values (v_uid, d::date, 'run', v_prog, nullif(v_run ->> 'note', ''), v_key)
      returning id into v_sid;
      insert into public.session_runs (session_id, user_id, distance_km, duration_s, source)
      values (v_sid, v_uid, v_km, nullif(v_dur, 0), 'import');
      n_sess := n_sess + 1; n_runs := n_runs + 1;
    end if;
  end loop;

  -- peso e medidas
  insert into public.body_measurements (user_id, measured_on, weight_kg, waist_cm, arm_cm, source)
  select v_uid, (w ->> 'date')::date, (w ->> 'kg')::numeric,
         nullif(w ->> 'waist', '')::numeric, nullif(w ->> 'arm', '')::numeric, 'import'
  from jsonb_array_elements(coalesce(p -> 'weights', '[]'::jsonb)) w
  where w ->> 'date' is not null and (w ->> 'kg') is not null
  on conflict (user_id, measured_on, source) do update
    set weight_kg = excluded.weight_kg, waist_cm = excluded.waist_cm, arm_cm = excluded.arm_cm;
  get diagnostics n_meas = row_count;

  -- preferências
  update public.profiles
     set settings = settings || jsonb_build_object('rest_beep', coalesce((p -> 'prefs' ->> 'sound')::boolean, true))
   where id = v_uid;

  return jsonb_build_object('program_id', v_prog, 'sessions', n_sess, 'sets', n_sets, 'runs', n_runs, 'measurements', n_meas);
end;
$$;

-- ---------------------------------------------------------------------
-- Visões para os gráficos (respeitam o RLS de quem consulta)
-- ---------------------------------------------------------------------
create view public.v_exercise_best_sets
with (security_invoker = true) as
select distinct on (s.user_id, s.exercise_id, ws.local_date)
       s.user_id, s.exercise_id, ws.local_date, s.is_alternative,
       s.weight_kg, s.reps, s.duration_s
from public.session_sets s
join public.workout_sessions ws on ws.id = s.session_id
where s.deleted_at is null and ws.deleted_at is null
order by s.user_id, s.exercise_id, ws.local_date, s.weight_kg desc nulls last, s.reps desc nulls last;

create view public.v_weekly_volume
with (security_invoker = true) as
select ws.user_id,
       date_trunc('week', ws.local_date)::date as week_start,
       count(*)                                 as sets,
       count(distinct ws.id)                    as sessions,
       coalesce(sum(s.weight_kg * s.reps), 0)   as volume_kg
from public.session_sets s
join public.workout_sessions ws on ws.id = s.session_id
where s.deleted_at is null and ws.deleted_at is null
group by ws.user_id, date_trunc('week', ws.local_date);

create view public.v_weekly_sets_by_muscle
with (security_invoker = true) as
select ws.user_id,
       date_trunc('week', ws.local_date)::date as week_start,
       coalesce(mg.parent_id, mg.id)           as muscle_group_id,
       count(*)                                as direct_sets
from public.session_sets s
join public.workout_sessions ws on ws.id = s.session_id
join public.exercise_muscles em on em.exercise_id = s.exercise_id and em.is_primary
join public.muscle_groups mg on mg.id = em.muscle_group_id
where s.deleted_at is null and ws.deleted_at is null
group by ws.user_id, date_trunc('week', ws.local_date), coalesce(mg.parent_id, mg.id);

-- ---------------------------------------------------------------------
-- Permissões da API (o Supabase não expõe tabelas novas sem GRANT)
-- anon não recebe nada: todo acesso exige login. O RLS acima filtra as linhas.
-- ---------------------------------------------------------------------
revoke all on all tables in schema public from anon;
grant select on public.muscle_groups, public.exercise_muscles to authenticated;
grant select, insert, update, delete on
  public.profiles, public.exercises, public.exercise_muscles, public.programs, public.workout_templates,
  public.template_blocks, public.template_items, public.template_item_alternatives, public.program_schedule,
  public.planned_runs, public.program_enrollments, public.workout_sessions, public.session_sets,
  public.session_runs, public.body_measurements
  to authenticated;
revoke insert, delete on public.profiles from authenticated;   -- o perfil nasce pelo gatilho de cadastro
grant select on public.v_exercise_best_sets, public.v_weekly_volume, public.v_weekly_sets_by_muscle to authenticated;
grant all on all tables in schema public to service_role;

revoke execute on function public.handle_new_user() from public, anon, authenticated;
revoke execute on function public.clone_program(uuid, date) from public, anon;
revoke execute on function public.import_app_backup(jsonb, text) from public, anon;
grant execute on function public.clone_program(uuid, date) to authenticated;
grant execute on function public.import_app_backup(jsonb, text) to authenticated;
