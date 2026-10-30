-- =====================================================================
-- 性界地図：個人情報を最小限にする（01_schema.sql のあとに実行）
-- ・ログインのたびに届く氏名・ユーザー名・アイコンURLなどを保存の瞬間に消す
-- ・ログイン中の IP アドレスとブラウザの種類を保存しない
-- ・新しい利用者の表示名を無作為な名前にする
-- メールアドレスと連携先の利用者IDはログインに必要なので残る。
-- =====================================================================
create or replace function public.scrub_auth_user_meta()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.raw_user_meta_data := coalesce(new.raw_user_meta_data, '{}'::jsonb)
    - array['name','full_name','avatar_url','picture','user_name','preferred_username','nickname','slug','given_name','family_name','locale'];
  return new;
end $$;

create or replace function public.scrub_identity_data()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.identity_data := coalesce(new.identity_data, '{}'::jsonb)
    - array['name','full_name','avatar_url','picture','user_name','preferred_username','nickname','slug','given_name','family_name','locale'];
  return new;
end $$;

create or replace function public.scrub_session()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.ip := null;
  new.user_agent := null;
  return new;
end $$;

create trigger scrub_user_meta before insert or update on auth.users
  for each row execute function public.scrub_auth_user_meta();
create trigger scrub_identity_data before insert or update on auth.identities
  for each row execute function public.scrub_identity_data();
create trigger scrub_session before insert or update on auth.sessions
  for each row execute function public.scrub_session();

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, display_name)
  values (new.id, '利用者-' || substr(md5(new.id::text || clock_timestamp()::text), 1, 6));
  return new;
end $$;

revoke execute on function public.scrub_auth_user_meta() from anon, authenticated, public;
revoke execute on function public.scrub_identity_data()  from anon, authenticated, public;
revoke execute on function public.scrub_session()        from anon, authenticated, public;

-- すでに保存されている分も消す
update auth.users      set raw_user_meta_data = raw_user_meta_data;
update auth.identities set identity_data = identity_data;
update auth.sessions   set ip = null, user_agent = null;

-- 元に戻す場合：
-- drop trigger scrub_user_meta on auth.users;
-- drop trigger scrub_identity_data on auth.identities;
-- drop trigger scrub_session on auth.sessions;
