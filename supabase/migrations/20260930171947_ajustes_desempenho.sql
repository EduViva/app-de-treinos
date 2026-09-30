-- =====================================================================
-- Ajustes de desempenho apontados pelo Supabase Advisor
-- 1) índices para as chaves estrangeiras sem índice
-- 2) uma política por ação (políticas permissivas duplicadas custam
--    uma avaliação extra em toda consulta)
-- =====================================================================

-- 1) índices
create index muscle_groups_parent_idx            on public.muscle_groups (parent_id);
create index planned_runs_owner_idx              on public.planned_runs (owner_id);
create index program_enrollments_program_idx     on public.program_enrollments (program_id);
create index program_schedule_owner_idx          on public.program_schedule (owner_id);
create index program_schedule_template_idx       on public.program_schedule (template_id);
create index programs_source_program_idx         on public.programs (source_program_id);
create index session_runs_session_user_idx       on public.session_runs (session_id, user_id);
create index session_sets_exercise_idx           on public.session_sets (exercise_id);
drop index public.session_sets_session_idx;
create index session_sets_session_idx            on public.session_sets (session_id, user_id, set_index);
create index template_item_alternatives_owner_idx on public.template_item_alternatives (owner_id);
create index workout_sessions_planned_run_idx    on public.workout_sessions (planned_run_id);
create index workout_sessions_planned_tpl_idx    on public.workout_sessions (planned_template_id);
create index workout_sessions_program_idx        on public.workout_sessions (program_id);
create index workout_sessions_template_idx       on public.workout_sessions (template_id);

-- 2a) exercise_muscles: leitura numa política, escrita em três
drop policy exercise_muscles_write on public.exercise_muscles;
create policy exercise_muscles_insert on public.exercise_muscles for insert to authenticated
  with check (exists (select 1 from public.exercises e where e.id = exercise_id and e.owner_id = (select auth.uid())));
create policy exercise_muscles_update on public.exercise_muscles for update to authenticated
  using (exists (select 1 from public.exercises e where e.id = exercise_id and e.owner_id = (select auth.uid())))
  with check (exists (select 1 from public.exercises e where e.id = exercise_id and e.owner_id = (select auth.uid())));
create policy exercise_muscles_delete on public.exercise_muscles for delete to authenticated
  using (exists (select 1 from public.exercises e where e.id = exercise_id and e.owner_id = (select auth.uid())));

-- 2b) workout_templates: uma única política de leitura
drop policy workout_templates_public on public.workout_templates;
drop policy workout_templates_select on public.workout_templates;
create policy workout_templates_select on public.workout_templates for select to authenticated
  using (owner_id is null
         or owner_id = (select auth.uid())
         or exists (select 1 from public.programs p where p.id = program_id and p.visibility = 'public'));
