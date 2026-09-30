-- =====================================================================
-- Sincronização bidirecional do app (inclui exclusões e troca de dia)
--
-- Modelo
--   * O conteúdo continua nas tabelas normalizadas (workout_sessions,
--     session_sets, session_runs, body_measurements), que alimentam as
--     visões dos gráficos. Apagar = preencher deleted_at, nunca DELETE.
--   * app_sync_meta guarda, por dia / peso / configuração do app, a versão
--     (relógio do aparelho, em ms), se foi apagado e o que não cabe nas
--     tabelas (plano do dia = treino trocado, horários, modo).
--   * Conflito: vale a versão mais recente (version_ms) de cada dia.
--   * Entrega de mudanças: seq (sequência do servidor) permite ao aparelho
--     pedir só o que mudou desde a última vez, sem depender de relógios.
--   * sync_app(p) envia as mudanças do aparelho e devolve as do servidor.
-- =====================================================================

-- cada série ocupa uma posição única dentro da sessão (permite upsert)
create unique index session_sets_slot_uq
  on public.session_sets (session_id, template_item_id, set_index);

create sequence public.app_sync_seq;

create table public.app_sync_meta (
  user_id    uuid not null references auth.users (id) on delete cascade,
  kind       text not null check (kind in ('day','weight','setting')),
  key        text not null,                 -- 'AAAA-MM-DD' (day, weight) ou nome da configuração
  version_ms bigint not null,
  deleted    boolean not null default false,
  data       jsonb not null default '{}'::jsonb,
  seq        bigint not null default nextval('public.app_sync_seq'),
  updated_at timestamptz not null default now(),
  primary key (user_id, kind, key)
);
create index app_sync_meta_user_seq_idx on public.app_sync_meta (user_id, seq);

alter table public.app_sync_meta enable row level security;
create policy app_sync_meta_own on public.app_sync_meta for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

revoke all on public.app_sync_meta from anon, public;
grant select, insert, update, delete on public.app_sync_meta to authenticated;
revoke all on sequence public.app_sync_seq from anon, public;
grant usage on sequence public.app_sync_seq to authenticated;

-- ---------------------------------------------------------------------
-- Conteúdo de um dia ({sets, run}) no formato do app
-- ---------------------------------------------------------------------
create or replace function public.app_day_doc(p_date date)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  with sets as (
    select ti.legacy_code code, ss.set_index, ss.is_alternative alt,
           ss.weight_kg, coalesce(ss.reps, ss.duration_s) reps
    from public.session_sets ss
    join public.workout_sessions ws on ws.id = ss.session_id and ws.deleted_at is null
         and ws.local_date = p_date and ws.user_id = (select auth.uid())
    join public.template_items ti on ti.id = ss.template_item_id and ti.legacy_code is not null
    where ss.user_id = (select auth.uid()) and ss.deleted_at is null
  ),
  codes as (select code, max(set_index) mx from sets group by code),
  arr as (
    select c.code,
           jsonb_agg(
             case when s.set_index is null then jsonb_build_object('kg','','reps','','done',false)
                  else jsonb_build_object(
                         'kg', coalesce(replace(trim_scale(s.weight_kg)::text, '.', ','), ''),
                         'reps', coalesce(s.reps::text, ''),
                         'done', true,
                         'alt', s.alt) end
             order by g) a
    from codes c
    cross join lateral generate_series(0, c.mx) g
    left join sets s on s.code = c.code and s.set_index = g
    group by c.code
  )
  select jsonb_build_object(
    'sets', coalesce((select jsonb_object_agg(code, a) from arr), '{}'::jsonb),
    'run', coalesce((
      select jsonb_strip_nulls(jsonb_build_object(
               'km', replace(trim_scale(r.distance_km)::text, '.', ','),
               'min', (r.duration_s / 60)::text,
               'sec', (r.duration_s % 60)::text,
               'note', ws.notes))
      from public.session_runs r
      join public.workout_sessions ws on ws.id = r.session_id and ws.deleted_at is null
           and ws.local_date = p_date and ws.user_id = (select auth.uid())
      where r.user_id = (select auth.uid())
      limit 1), '{}'::jsonb));
$$;

-- ---------------------------------------------------------------------
-- Grava o conteúdo de um dia (ou apaga, se doc.del) nas tabelas normalizadas
-- ---------------------------------------------------------------------
create or replace function public.app_apply_day(p_prog uuid, p_date date, p_doc jsonb)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_del boolean := coalesce((p_doc ->> 'del')::boolean, false);
  v_keep uuid[] := '{}';
  v_tpl uuid; v_sid uuid; v_act text;
  v_st timestamptz; v_fi timestamptz;
  v_run jsonb := coalesce(p_doc -> 'run', '{}'::jsonb);
  v_km numeric; v_dur int;
begin
  if not v_del then
    v_st := case when jsonb_typeof(p_doc -> 'startedAt') = 'number' then to_timestamp((p_doc ->> 'startedAt')::bigint / 1000.0) end;
    v_fi := case when jsonb_typeof(p_doc -> 'finishedAt') = 'number' then to_timestamp((p_doc ->> 'finishedAt')::bigint / 1000.0) end;
    if v_st is not null and v_fi is not null and v_fi < v_st then v_fi := null; end if;

    -- musculação / pescoço: uma sessão por ficha que tem série feita
    for v_tpl in
      select distinct b.template_id
      from jsonb_each(coalesce(p_doc -> 'sets', '{}'::jsonb)) s(code, arr)
      join public.template_items i on i.legacy_code = s.code
      join public.template_blocks b on b.id = i.block_id
      join public.workout_templates t on t.id = b.template_id and t.program_id = p_prog
      where exists (select 1 from jsonb_array_elements(s.arr) z where coalesce((z ->> 'done')::boolean, false))
    loop
      select case when kind = 'mobility' then 'mobility' else 'strength' end into v_act
        from public.workout_templates where id = v_tpl;

      select id into v_sid from public.workout_sessions
       where user_id = v_uid and local_date = p_date and template_id = v_tpl
       order by (deleted_at is null) desc, created_at limit 1;
      if v_sid is null then
        insert into public.workout_sessions (user_id, local_date, activity, program_id, template_id, started_at, finished_at)
        values (v_uid, p_date, v_act, p_prog, v_tpl, v_st, v_fi) returning id into v_sid;
      else
        update public.workout_sessions
           set deleted_at = null, activity = v_act, program_id = p_prog, started_at = v_st, finished_at = v_fi
         where id = v_sid;
      end if;
      v_keep := v_keep || v_sid;

      -- séries: apaga tudo e regrava as feitas (o upsert desfaz o apagado)
      update public.session_sets set deleted_at = now() where session_id = v_sid and deleted_at is null;
      insert into public.session_sets (session_id, user_id, template_item_id, exercise_id, is_alternative,
                                       set_index, weight_kg, reps, duration_s)
      select v_sid, v_uid, i.id,
             case when coalesce((z.x ->> 'alt')::boolean, false) and al.exercise_id is not null
                  then al.exercise_id else i.exercise_id end,
             coalesce((z.x ->> 'alt')::boolean, false),
             (z.ord - 1)::smallint,
             nullif(replace(z.x ->> 'kg', ',', '.'), '')::numeric,
             case when ex.measure = 'time' then null else round(nullif(replace(z.x ->> 'reps', ',', '.'), '')::numeric)::smallint end,
             case when ex.measure = 'time' then round(nullif(replace(z.x ->> 'reps', ',', '.'), '')::numeric)::int end
      from jsonb_each(coalesce(p_doc -> 'sets', '{}'::jsonb)) s(code, arr)
      join public.template_items i on i.legacy_code = s.code
      join public.template_blocks b on b.id = i.block_id and b.template_id = v_tpl
      join public.exercises ex on ex.id = i.exercise_id
      left join lateral (select a.exercise_id from public.template_item_alternatives a
                          where a.item_id = i.id order by a.position limit 1) al on true
      cross join lateral jsonb_array_elements(s.arr) with ordinality z(x, ord)
      where coalesce((z.x ->> 'done')::boolean, false)
      on conflict (session_id, template_item_id, set_index) do update
        set exercise_id = excluded.exercise_id, is_alternative = excluded.is_alternative,
            weight_kg = excluded.weight_kg, reps = excluded.reps, duration_s = excluded.duration_s,
            deleted_at = null;
    end loop;

    -- corrida
    v_km := nullif(replace(coalesce(v_run ->> 'km', ''), ',', '.'), '')::numeric;
    if v_km is not null and v_km > 0 and v_km < 500 then
      v_dur := least(coalesce(nullif(replace(coalesce(v_run ->> 'min', ''), ',', '.'), '')::numeric, 0)::int * 60
                     + coalesce(nullif(replace(coalesce(v_run ->> 'sec', ''), ',', '.'), '')::numeric, 0)::int, 172799);
      select id into v_sid from public.workout_sessions
       where user_id = v_uid and local_date = p_date and activity = 'run'
       order by (deleted_at is null) desc, created_at limit 1;
      if v_sid is null then
        insert into public.workout_sessions (user_id, local_date, activity, program_id, notes)
        values (v_uid, p_date, 'run', p_prog, nullif(v_run ->> 'note', '')) returning id into v_sid;
      else
        update public.workout_sessions
           set deleted_at = null, program_id = p_prog, notes = nullif(v_run ->> 'note', '')
         where id = v_sid;
      end if;
      v_keep := v_keep || v_sid;
      insert into public.session_runs (session_id, user_id, distance_km, duration_s, source)
      values (v_sid, v_uid, v_km, nullif(v_dur, 0), 'manual')
      on conflict (session_id) do update
        set distance_km = excluded.distance_km, duration_s = excluded.duration_s;
    end if;
  end if;

  -- o que sobrou do dia some (sem perder o histórico)
  update public.workout_sessions set deleted_at = now()
   where user_id = v_uid and local_date = p_date and deleted_at is null and not (id = any (v_keep));
  update public.session_sets set deleted_at = now()
   where user_id = v_uid and deleted_at is null
     and session_id in (select id from public.workout_sessions
                         where user_id = v_uid and local_date = p_date and deleted_at is not null);
end;
$$;

-- ---------------------------------------------------------------------
-- Envia as mudanças do aparelho e devolve as do servidor
--   p = { since: seq, days: {data: {v, del?, sets, run, plan, mode, startedAt, finishedAt}},
--         weights: {data: {v, del?, kg, waist, arm}}, settings: {nome: {v, value}} }
-- ---------------------------------------------------------------------
create or replace function public.sync_app(p jsonb, p_template_slug text default 'ficha-hipertrofia-meia-12s')
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_since bigint := coalesce((p ->> 'since')::bigint, 0);
  v_prog uuid;
  v_key text; v_doc jsonb; v_ver bigint; v_cur bigint; v_del boolean;
  v_rejected text[] := '{}';
begin
  if v_uid is null then raise exception 'É preciso estar logado.'; end if;

  select e.program_id into v_prog from public.program_enrollments e
   where e.user_id = v_uid and e.status = 'active' limit 1;
  if v_prog is null then
    v_prog := public.clone_program(
      (select id from public.programs where slug = p_template_slug and owner_id is null),
      coalesce(nullif(p -> 'settings' -> 'startDate' ->> 'value', '')::date, current_date));
  end if;

  -- dias
  for v_key, v_doc in select key, value from jsonb_each(coalesce(p -> 'days', '{}'::jsonb)) loop
    begin
      v_ver := (v_doc ->> 'v')::bigint;
      v_del := coalesce((v_doc ->> 'del')::boolean, false);
      select version_ms into v_cur from public.app_sync_meta where user_id = v_uid and kind = 'day' and key = v_key;
      if v_cur is not null and v_cur >= v_ver then continue; end if;
      perform public.app_apply_day(v_prog, v_key::date, v_doc);
      insert into public.app_sync_meta (user_id, kind, key, version_ms, deleted, data)
      values (v_uid, 'day', v_key, v_ver, v_del,
              case when v_del then '{}'::jsonb else jsonb_strip_nulls(jsonb_build_object(
                'plan', v_doc -> 'plan', 'mode', v_doc -> 'mode',
                'startedAt', v_doc -> 'startedAt', 'finishedAt', v_doc -> 'finishedAt')) end)
      on conflict (user_id, kind, key) do update
        set version_ms = excluded.version_ms, deleted = excluded.deleted, data = excluded.data,
            seq = nextval('public.app_sync_seq'), updated_at = now();
    exception when others then
      v_rejected := v_rejected || ('day:' || v_key);
    end;
  end loop;

  -- pesos e medidas
  for v_key, v_doc in select key, value from jsonb_each(coalesce(p -> 'weights', '{}'::jsonb)) loop
    begin
      v_ver := (v_doc ->> 'v')::bigint;
      v_del := coalesce((v_doc ->> 'del')::boolean, false);
      select version_ms into v_cur from public.app_sync_meta where user_id = v_uid and kind = 'weight' and key = v_key;
      if v_cur is not null and v_cur >= v_ver then continue; end if;
      if v_del then
        update public.body_measurements set deleted_at = now()
         where user_id = v_uid and measured_on = v_key::date and deleted_at is null and source in ('manual','import');
      else
        insert into public.body_measurements (user_id, measured_on, weight_kg, waist_cm, arm_cm, source)
        values (v_uid, v_key::date, (v_doc ->> 'kg')::numeric,
                case when (v_doc ->> 'waist')::numeric between 30 and 250 then (v_doc ->> 'waist')::numeric end,
                case when (v_doc ->> 'arm')::numeric between 10 and 80 then (v_doc ->> 'arm')::numeric end,
                'manual')
        on conflict (user_id, measured_on, source) do update
          set weight_kg = excluded.weight_kg, waist_cm = excluded.waist_cm, arm_cm = excluded.arm_cm, deleted_at = null;
        update public.body_measurements set deleted_at = now()
         where user_id = v_uid and measured_on = v_key::date and source = 'import' and deleted_at is null;
      end if;
      insert into public.app_sync_meta (user_id, kind, key, version_ms, deleted)
      values (v_uid, 'weight', v_key, v_ver, v_del)
      on conflict (user_id, kind, key) do update
        set version_ms = excluded.version_ms, deleted = excluded.deleted,
            seq = nextval('public.app_sync_seq'), updated_at = now();
    exception when others then
      v_rejected := v_rejected || ('weight:' || v_key);
    end;
  end loop;

  -- configurações
  for v_key, v_doc in select key, value from jsonb_each(coalesce(p -> 'settings', '{}'::jsonb)) loop
    begin
      v_ver := (v_doc ->> 'v')::bigint;
      select version_ms into v_cur from public.app_sync_meta where user_id = v_uid and kind = 'setting' and key = v_key;
      if v_cur is not null and v_cur >= v_ver then continue; end if;
      if v_key = 'startDate' then
        update public.program_enrollments set start_date = (v_doc ->> 'value')::date
         where user_id = v_uid and status = 'active';
      elsif v_key = 'sound' then
        update public.profiles set settings = settings || jsonb_build_object('rest_beep', (v_doc ->> 'value')::boolean)
         where id = v_uid;
      else
        continue;
      end if;
      insert into public.app_sync_meta (user_id, kind, key, version_ms, data)
      values (v_uid, 'setting', v_key, v_ver, jsonb_build_object('value', v_doc -> 'value'))
      on conflict (user_id, kind, key) do update
        set version_ms = excluded.version_ms, data = excluded.data,
            seq = nextval('public.app_sync_seq'), updated_at = now();
    exception when others then
      v_rejected := v_rejected || ('setting:' || v_key);
    end;
  end loop;

  return jsonb_build_object(
    'seq', coalesce((select max(m.seq) from public.app_sync_meta m where m.user_id = v_uid), 0),
    'rejected', to_jsonb(v_rejected),
    'days', coalesce((
      select jsonb_object_agg(m.key,
               jsonb_build_object('v', m.version_ms, 'del', m.deleted)
               || case when m.deleted then '{}'::jsonb else public.app_day_doc(m.key::date) || m.data end)
      from public.app_sync_meta m
      where m.user_id = v_uid and m.kind = 'day' and m.seq > v_since), '{}'::jsonb),
    'weights', coalesce((
      select jsonb_object_agg(m.key,
               jsonb_build_object('v', m.version_ms, 'del', m.deleted)
               || case when m.deleted then '{}'::jsonb else
                    coalesce((select jsonb_strip_nulls(jsonb_build_object('kg', b.weight_kg, 'waist', b.waist_cm, 'arm', b.arm_cm))
                                from public.body_measurements b
                               where b.user_id = v_uid and b.measured_on = m.key::date and b.deleted_at is null
                               order by (b.source = 'manual') desc, b.updated_at desc limit 1), '{}'::jsonb) end)
      from public.app_sync_meta m
      where m.user_id = v_uid and m.kind = 'weight' and m.seq > v_since), '{}'::jsonb),
    'settings', coalesce((
      select jsonb_object_agg(m.key, jsonb_build_object('v', m.version_ms, 'value', m.data -> 'value'))
      from public.app_sync_meta m
      where m.user_id = v_uid and m.kind = 'setting' and m.seq > v_since), '{}'::jsonb));
end;
$$;

revoke execute on function public.app_day_doc(date) from public, anon;
revoke execute on function public.app_apply_day(uuid, date, jsonb) from public, anon;
revoke execute on function public.sync_app(jsonb, text) from public, anon;
grant execute on function public.app_day_doc(date) to authenticated;
grant execute on function public.app_apply_day(uuid, date, jsonb) to authenticated;
grant execute on function public.sync_app(jsonb, text) to authenticated;

-- ---------------------------------------------------------------------
-- Dados que já estavam no banco (importados antes desta migration)
-- entram no controle de sincronização, para chegarem aos outros aparelhos
-- ---------------------------------------------------------------------
insert into public.app_sync_meta (user_id, kind, key, version_ms, data)
select ws.user_id, 'day', ws.local_date::text,
       (extract(epoch from max(ws.updated_at)) * 1000)::bigint,
       jsonb_strip_nulls(jsonb_build_object(
         'startedAt', (extract(epoch from min(ws.started_at)) * 1000)::bigint,
         'finishedAt', (extract(epoch from max(ws.finished_at)) * 1000)::bigint))
from public.workout_sessions ws
where ws.deleted_at is null
group by ws.user_id, ws.local_date
on conflict do nothing;

insert into public.app_sync_meta (user_id, kind, key, version_ms)
select b.user_id, 'weight', b.measured_on::text, (extract(epoch from max(b.updated_at)) * 1000)::bigint
from public.body_measurements b
where b.deleted_at is null and b.weight_kg is not null and b.source in ('manual','import')
group by b.user_id, b.measured_on
on conflict do nothing;

insert into public.app_sync_meta (user_id, kind, key, version_ms, data)
select e.user_id, 'setting', 'startDate', (extract(epoch from e.updated_at) * 1000)::bigint,
       jsonb_build_object('value', e.start_date)
from public.program_enrollments e
where e.status = 'active'
on conflict do nothing;
