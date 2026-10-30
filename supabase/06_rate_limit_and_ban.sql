-- =====================================================================
-- 性界地図：荒らし対策（05_content_rules.sql のあとに実行）
--  ・書き込みは1人1時間に10件まで（管理者・まとめ処理は対象外）
--    1回の操作（1つのトランザクション）を1件と数える
--  ・管理者が特定の利用者のログインと編集を停止できる
-- =====================================================================

-- 書き込みの記録（件数を数えるためだけの表。誰も直接は読めない）
create table public.write_log (
  user_id    uuid   not null,
  txid       bigint not null,
  created_at timestamptz not null default now(),
  primary key (user_id, txid)
);
create index write_log_recent_idx on public.write_log (user_id, created_at);
alter table public.write_log enable row level security;

create or replace function public.enforce_write_limit()
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid    uuid := auth.uid();
  v_n      int;
  v_oldest timestamptz;
begin
  if v_uid is null or is_privileged() then return; end if;

  insert into write_log (user_id, txid) values (v_uid, txid_current()) on conflict do nothing;
  if not found then return; end if;   -- 同じ操作の2つ目以降の書き込みは数えない

  select count(*), min(created_at) into v_n, v_oldest
  from write_log where user_id = v_uid and created_at > now() - interval '1 hour';

  if v_n > 10 then
    raise exception '書き込みは1時間に10件までです。約%分後にもう一度お試しください。',
      greatest(1, ceil(extract(epoch from (v_oldest + interval '1 hour' - now())) / 60)::int);
  end if;

  delete from write_log where user_id = v_uid and created_at < now() - interval '1 day';
end $$;
revoke execute on function public.enforce_write_limit() from anon, authenticated, public;

-- 用語の追加・改名・削除
create or replace function public.terms_rate_limit()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform enforce_write_limit();
  return new;
end $$;
create trigger terms_rate_limit before insert or update on public.terms
  for each row execute function public.terms_rate_limit();

-- 親子の線の追加・削除
create or replace function public.term_parents_rate_limit()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform enforce_write_limit();
  return coalesce(new, old);
end $$;
create trigger term_parents_rate_limit before insert or delete on public.term_parents
  for each row execute function public.term_parents_rate_limit();

-- 通報
create or replace function public.reports_rate_limit()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform enforce_write_limit();
  return new;
end $$;
create trigger reports_rate_limit before insert on public.reports
  for each row execute function public.reports_rate_limit();

revoke execute on function public.terms_rate_limit()        from anon, authenticated, public;
revoke execute on function public.term_parents_rate_limit() from anon, authenticated, public;
revoke execute on function public.reports_rate_limit()      from anon, authenticated, public;

-- 用語と親子の線を1回の操作で追加する（1件と数えるため）
create or replace function public.add_term(p_label text, p_parent bigint default null)
returns bigint language plpgsql security invoker set search_path = public as $$
declare
  v_id bigint;
begin
  insert into terms (label) values (p_label) returning id into v_id;
  if p_parent is not null then
    insert into term_parents (child_id, parent_id) values (v_id, p_parent);
  end if;
  return v_id;
end $$;
revoke execute on function public.add_term(text, bigint) from anon, public;
grant  execute on function public.add_term(text, bigint) to authenticated;

-- ---------------------------------------------------------------------
-- 利用者の停止（ログイン拒否＋編集停止）／解除
--   Supabase の banned_until を設定すると、ログインとログイン状態の延長ができなくなる。
--   ログイン中の状態も消すので、遅くとも約1時間で画面からも締め出される。
--   編集は is_banned によりその場で止まる。
-- ---------------------------------------------------------------------
create or replace function public.ban_user(p_user_id uuid, p_banned boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception '管理者のみ実行できます'; end if;
  if p_user_id = auth.uid() then raise exception '自分自身は停止できません'; end if;
  if p_banned and exists (select 1 from profiles where id = p_user_id and role = 'admin') then
    raise exception '管理者は停止できません';
  end if;

  update profiles set is_banned = p_banned where id = p_user_id;
  update auth.users
     set banned_until = case when p_banned then now() + interval '100 years' else null end
   where id = p_user_id;
  if p_banned then
    delete from auth.sessions where user_id = p_user_id;
  end if;
end $$;
revoke execute on function public.ban_user(uuid, boolean) from anon, public;
grant  execute on function public.ban_user(uuid, boolean) to authenticated;
