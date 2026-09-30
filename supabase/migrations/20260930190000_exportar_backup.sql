-- =====================================================================
-- export_app_backup(): o caminho inverso de import_app_backup.
-- Devolve os registros do usuário logado no mesmo formato do localStorage
-- do app ({startDate, weights, sessions, prefs}), para o app baixar os
-- dados em um aparelho novo. Só leitura; respeita o RLS (security invoker).
-- Não devolve o que não é guardado no banco: troca/mudança de dia do
-- treino (session.plan) e cronômetro em andamento.
-- =====================================================================
create or replace function public.export_app_backup()
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_start date;
  v_sessions jsonb;
  v_weights jsonb;
  v_sound boolean;
begin
  if v_uid is null then raise exception 'É preciso estar logado.'; end if;

  select e.start_date into v_start from public.program_enrollments e
   where e.user_id = v_uid and e.status = 'active' limit 1;

  with sets as (
    select ws.local_date d, ti.legacy_code code, ss.set_index, ss.is_alternative alt,
           ss.weight_kg, coalesce(ss.reps, ss.duration_s) reps
    from public.session_sets ss
    join public.workout_sessions ws on ws.id = ss.session_id and ws.deleted_at is null
    join public.template_items ti on ti.id = ss.template_item_id and ti.legacy_code is not null
    where ss.user_id = v_uid and ss.deleted_at is null
  ),
  codes as (select d, code, max(set_index) mx from sets group by d, code),
  arr as (
    select c.d, c.code,
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
    left join sets s on s.d = c.d and s.code = c.code and s.set_index = g
    group by c.d, c.code
  ),
  day_sets as (select d, jsonb_object_agg(code, a) o from arr group by d),
  day_times as (
    select ws.local_date d,
           min(extract(epoch from ws.started_at) * 1000)::bigint st,
           max(extract(epoch from ws.finished_at) * 1000)::bigint fi
    from public.workout_sessions ws
    where ws.user_id = v_uid and ws.deleted_at is null and ws.activity <> 'run'
    group by ws.local_date
  ),
  day_run as (
    select ws.local_date d,
           jsonb_strip_nulls(jsonb_build_object(
             'km', replace(trim_scale(r.distance_km)::text, '.', ','),
             'min', (r.duration_s / 60)::text,
             'sec', (r.duration_s % 60)::text,
             'note', ws.notes)) o
    from public.session_runs r
    join public.workout_sessions ws on ws.id = r.session_id and ws.deleted_at is null
    where r.user_id = v_uid
  ),
  days as (
    select d from day_sets union select d from day_run
  )
  select coalesce(jsonb_object_agg(days.d::text,
           jsonb_build_object('sets', coalesce(ds.o, '{}'::jsonb), 'run', coalesce(dr.o, '{}'::jsonb))
           || jsonb_strip_nulls(jsonb_build_object('startedAt', dt.st, 'finishedAt', dt.fi))), '{}'::jsonb)
    into v_sessions
  from days
  left join day_sets ds on ds.d = days.d
  left join day_run dr on dr.d = days.d
  left join day_times dt on dt.d = days.d;

  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'date', m.measured_on, 'kg', m.weight_kg, 'waist', m.waist_cm, 'arm', m.arm_cm))
         order by m.measured_on), '[]'::jsonb)
    into v_weights
  from (
    select distinct on (measured_on) * from public.body_measurements
    where user_id = v_uid and deleted_at is null and weight_kg is not null
    order by measured_on, (source = 'manual') desc, updated_at desc
  ) m;

  select (settings ->> 'rest_beep')::boolean into v_sound from public.profiles where id = v_uid;

  return jsonb_build_object('v', 2, 'startDate', v_start, 'weights', v_weights,
                            'sessions', v_sessions, 'prefs', jsonb_build_object('sound', coalesce(v_sound, true)));
end;
$$;

grant execute on function public.export_app_backup() to authenticated;
revoke execute on function public.export_app_backup() from anon, public;
