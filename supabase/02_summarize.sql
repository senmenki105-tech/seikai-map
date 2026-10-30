-- =====================================================================
-- 性界地図：まとめ処理（自動で中間の親を作る）用のDB部分
-- 01_schema.sql を実行したあとに、SQL Editor で実行してください。
-- ここにある関数は service_role（Edge Function）専用です。
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. ジョブ管理（Batch API に送った単位で1行）
-- ---------------------------------------------------------------------
create table public.summarize_jobs (
  id             bigint generated always as identity primary key,
  batch_id       text not null unique,
  status         text not null default 'in_progress' check (status in ('in_progress', 'applied', 'failed')),
  parent_count   int  not null default 0,     -- 送った親の数
  applied_groups int  not null default 0,     -- 実際に作った中間の親の数
  note           text,
  submitted_at   timestamptz not null default now(),
  finished_at    timestamptz
);

alter table public.summarize_jobs enable row level security;
-- 管理者は画面から状況を見られる（書き込みは service_role のみ）
create policy summarize_jobs_admin_select on public.summarize_jobs
  for select using (is_admin());

-- ---------------------------------------------------------------------
-- 2. 前回の送信時刻（ここ以降に変更のあった親だけを処理する）
-- ---------------------------------------------------------------------
create or replace function public.summarize_cursor()
returns timestamptz language sql stable security definer set search_path = public as $$
  select max(submitted_at) from summarize_jobs where status <> 'failed';
$$;

create or replace function public.summarize_open_jobs()
returns setof public.summarize_jobs language sql stable security definer set search_path = public as $$
  select * from summarize_jobs where status = 'in_progress' order by id;
$$;

create or replace function public.summarize_record_job(p_batch_id text, p_parent_count int)
returns bigint language sql security definer set search_path = public as $$
  insert into summarize_jobs (batch_id, parent_count) values (p_batch_id, p_parent_count) returning id;
$$;

create or replace function public.summarize_finish_job(p_id bigint, p_status text, p_applied int, p_note text)
returns void language sql security definer set search_path = public as $$
  update summarize_jobs
  set status = p_status, applied_groups = p_applied, note = p_note, finished_at = now()
  where id = p_id;
$$;

-- ---------------------------------------------------------------------
-- 3. 候補の親を抽出
--   ・表示中で、表示中の子を p_min_children 個以上持つ
--   ・中間の親を挟んでも階層が p_max_depth を超えない（深さは最上位を0と数える）
--   ・p_since 以降に、利用者の操作で子の付け外しがあった（初回は p_since = null で全件）
--   ・まとめ処理自身の変更（source = 'system'）では再度候補にしない
-- ---------------------------------------------------------------------
create or replace function public.summarize_candidates(
  p_since        timestamptz,
  p_min_children int default 5,
  p_max_depth    int default 6,
  p_max_children int default 80,
  p_limit        int default 500
)
returns table (parent_id bigint, label text, depth int, children jsonb)
language sql stable security definer set search_path = public as $$
  with recursive
  live as (
    select id, label from terms where deleted_at is null and not is_hidden
  ),
  edges as (
    select tp.child_id, tp.parent_id
    from term_parents tp
    join live c on c.id = tp.child_id
    join live p on p.id = tp.parent_id
  ),
  -- 最上位からの最長の深さ
  walk(id, d) as (
    select l.id, 0 from live l where not exists (select 1 from edges e where e.child_id = l.id)
    union   -- 同じ（用語, 深さ）の組は1回だけ数える：複数の親を持つ構造でも行数が爆発しない
    select e.child_id, w.d + 1 from edges e join walk w on w.id = e.parent_id where w.d < 50
  ),
  depths as (select id, max(d) as d from walk group by id),
  changed as (
    select distinct r.parent_id as id
    from revisions r
    where r.table_name = 'term_parents' and r.source <> 'system' and r.created_at > p_since
  ),
  cand as (
    select p.id, p.label, dp.d, count(*) as n
    from edges e
    join live p on p.id = e.parent_id
    join depths dp on dp.id = p.id
    where dp.d + 2 <= p_max_depth
      and (p_since is null or p.id in (select id from changed))
    group by p.id, p.label, dp.d
    having count(*) >= p_min_children
  )
  select c.id, c.label, c.d::int,
    (select jsonb_agg(jsonb_build_object('id', k.id, 'label', k.label) order by k.id)
       from (select l.id, l.label from edges e join live l on l.id = e.child_id
             where e.parent_id = c.id order by l.id limit p_max_children) k)
  from cand c
  order by c.n desc, c.id
  limit p_limit;
$$;

-- ---------------------------------------------------------------------
-- 4. 中間の親を1つ反映（失敗してもほかの反映に影響しないよう1件ずつ）
--   p_children のうち「今も p_parent の子であるもの」だけを動かす。
--   同じ名前の用語がすでにあればそれを使う。循環になる場合は何もしない。
--   service_role から呼ぶので、履歴には source = 'system' で残る。
-- ---------------------------------------------------------------------
create or replace function public.apply_intermediate(p_parent bigint, p_name text, p_children bigint[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_name   text := btrim(coalesce(p_name, ''));
  v_kids   bigint[];
  v_mid    bigint;
  v_kid    bigint;
begin
  if char_length(v_name) not between 1 and 100 then
    return jsonb_build_object('status', 'skipped', 'reason', 'invalid_name');
  end if;
  if not exists (select 1 from terms where id = p_parent and deleted_at is null and not is_hidden) then
    return jsonb_build_object('status', 'skipped', 'reason', 'parent_gone');
  end if;

  -- 今も子であり、表示中のものだけ
  select array_agg(distinct tp.child_id) into v_kids
  from term_parents tp join terms t on t.id = tp.child_id
  where tp.parent_id = p_parent and tp.child_id = any(p_children)
    and t.deleted_at is null and not t.is_hidden;
  if coalesce(array_length(v_kids, 1), 0) < 2 then
    return jsonb_build_object('status', 'skipped', 'reason', 'too_few_children');
  end if;

  -- 親や子と同じ名前は不可
  if exists (select 1 from terms where (id = p_parent or id = any(v_kids))
             and lower(btrim(label)) = lower(v_name)) then
    return jsonb_build_object('status', 'skipped', 'reason', 'same_name');
  end if;

  begin
    select id into v_mid from terms
    where deleted_at is null and lower(btrim(label)) = lower(v_name) limit 1;
    if v_mid is not null and exists (select 1 from terms where id = v_mid and is_hidden) then
      return jsonb_build_object('status', 'skipped', 'reason', 'name_hidden');
    end if;
    if v_mid is null then
      insert into terms (label) values (v_name) returning id into v_mid;
    end if;

    insert into term_parents (child_id, parent_id) values (v_mid, p_parent) on conflict do nothing;
    foreach v_kid in array v_kids loop
      if v_kid <> v_mid then
        insert into term_parents (child_id, parent_id) values (v_kid, v_mid) on conflict do nothing;
        delete from term_parents where child_id = v_kid and parent_id = p_parent;
      end if;
    end loop;
  exception when others then
    -- 循環などで失敗したら、この1件だけ取り消す
    return jsonb_build_object('status', 'skipped', 'reason', sqlerrm);
  end;

  return jsonb_build_object('status', 'applied', 'term_id', v_mid, 'moved', array_length(v_kids, 1));
end $$;

-- service_role 以外からは呼べないようにする
revoke execute on function public.summarize_cursor()                                   from anon, authenticated, public;
revoke execute on function public.summarize_open_jobs()                                from anon, authenticated, public;
revoke execute on function public.summarize_record_job(text, int)                       from anon, authenticated, public;
revoke execute on function public.summarize_finish_job(bigint, text, int, text)         from anon, authenticated, public;
revoke execute on function public.summarize_candidates(timestamptz, int, int, int, int) from anon, authenticated, public;
revoke execute on function public.apply_intermediate(bigint, text, bigint[])            from anon, authenticated, public;
grant  execute on function public.summarize_cursor()                                   to service_role;
grant  execute on function public.summarize_open_jobs()                                to service_role;
grant  execute on function public.summarize_record_job(text, int)                       to service_role;
grant  execute on function public.summarize_finish_job(bigint, text, int, text)         to service_role;
grant  execute on function public.summarize_candidates(timestamptz, int, int, int, int) to service_role;
grant  execute on function public.apply_intermediate(bigint, text, bigint[])            to service_role;
