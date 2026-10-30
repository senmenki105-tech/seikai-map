-- =====================================================================
-- 性界地図：登録できない内容をデータベースで弾く（04_privacy.sql のあとに実行）
--  ・URL とそれに類する入力（ドメイン、メールアドレス、@ID、長い数字、連絡先の案内）
--  ・管理者が登録した禁止パターン（banned_patterns 表。中身は公開しない）
--  ・用語名は40文字まで（文章ではなく用語を登録してもらうため）
-- 対象：用語名、表示名、通報の理由
-- =====================================================================

-- 禁止パターン（正規表現）。管理者だけが読み書きできる
create table public.banned_patterns (
  id         bigint generated always as identity primary key,
  pattern    text not null check (('' ~ pattern) is not null),  -- 正しい正規表現でなければ登録できない
  note       text,
  created_at timestamptz not null default now()
);
alter table public.banned_patterns enable row level security;
create policy banned_patterns_admin on public.banned_patterns
  for all using (is_admin()) with check (is_admin());

-- 違反があれば理由を、なければ null を返す
create or replace function public.content_violation(p_text text)
returns text language plpgsql stable security definer set search_path = public as $$
declare
  v  text := lower(normalize(coalesce(p_text, ''), NFKC));   -- 全角→半角、大文字→小文字
  v2 text;
  r  record;
begin
  -- 区切り文字を取り除いた形でも調べる（「h t t p」「www。example。com」などの書き換え対策）
  v2 := translate(v, '。', '.');
  v2 := regexp_replace(v2, '[[:space:]_・、,*|()「」\[\]{}<>"''`]', '', 'g');

  if v2 ~ '(https?|hxxps?|h\*\*ps?|ttps?:|://|www\.|www[a-z])' then
    return 'URLやサイトのアドレス';
  end if;
  if v2 ~ '[a-z0-9]\.(com|net|org|jp|io|me|co|info|xyz|link|ly|gl|gg|cc|tv|app|dev|site|online|page|to|biz|ru|cn|kr|uk|us|tk|shop|club|top|fun|live|blog|art|moe|work|fm|be|ws|nu|im)([^a-z]|$)'
     or v2 ~ '(ドット|どっと|dot|点)(com|net|org|jp|io|me|co|info|xyz|link|gg|cc|tv|app|コム|こむ|ジェーピー)' then
    return 'URLやサイトのアドレス';
  end if;
  if v2 ~ '(@|＠|あっとまーく|アットマーク)' then
    return 'メールアドレスや@ID';
  end if;
  if v2 ~ '[0-9]{9,}' then
    return '電話番号や長い数字';
  end if;
  if v2 ~ '(lineid|line@|ラインid|discord|telegram|kakao|カカオ|skype|signal|wechat|連絡先|連絡して|dmして|dmください|dmまで)' then
    return '連絡先の案内';
  end if;

  for r in select pattern from banned_patterns loop
    if v ~ r.pattern or v2 ~ r.pattern then
      return '禁止されている内容';   -- どのパターンに当たったかは示さない
    end if;
  end loop;
  return null;
end $$;

revoke execute on function public.content_violation(text) from anon, authenticated, public;

-- ---------------------------------------------------------------------
-- 用語：名前の変更・追加のたびに確認（管理者・まとめ処理も対象）
-- ---------------------------------------------------------------------
create or replace function public.terms_before_write()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_bad text;
begin
  if tg_op = 'INSERT' or new.label is distinct from old.label then
    v_bad := content_violation(new.label);
    if v_bad is not null then
      raise exception '登録できない内容が含まれています（%）', v_bad;
    end if;
    if char_length(btrim(new.label)) > 40 then
      raise exception '用語名は40文字までです';
    end if;
  end if;

  if not is_privileged() then
    if tg_op = 'INSERT' then
      new.created_by := auth.uid();
      new.created_at := now();
      new.is_hidden  := false;
      new.deleted_at := null;
    else
      if new.is_hidden is distinct from old.is_hidden then
        raise exception '非表示の切り替えは管理者のみです';
      end if;
      if new.created_by is distinct from old.created_by or new.created_at is distinct from old.created_at
         or new.id is distinct from old.id then
        raise exception 'この項目は変更できません';
      end if;
    end if;
  end if;
  new.updated_by := auth.uid();
  new.updated_at := now();
  return new;
end $$;

-- ---------------------------------------------------------------------
-- 表示名
-- ---------------------------------------------------------------------
create or replace function public.profiles_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_bad text;
begin
  if new.display_name is distinct from old.display_name then
    if char_length(btrim(coalesce(new.display_name, ''))) = 0 then
      raise exception '表示名を入力してください';
    end if;
    v_bad := content_violation(new.display_name);
    if v_bad is not null then
      raise exception '表示名に使えない内容が含まれています（%）', v_bad;
    end if;
    new.display_name := btrim(new.display_name);
  end if;

  if not is_privileged() then
    if new.role is distinct from old.role or new.is_banned is distinct from old.is_banned
       or new.created_at is distinct from old.created_at then
      raise exception 'この項目は変更できません';
    end if;
    if new.adult_confirmed_at is distinct from old.adult_confirmed_at then
      if old.adult_confirmed_at is not null then
        raise exception '18歳以上の確認は取り消せません';
      end if;
      new.adult_confirmed_at := now();
    end if;
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------------
-- 通報の理由
-- ---------------------------------------------------------------------
create or replace function public.reports_before_insert()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_bad text;
begin
  v_bad := content_violation(new.reason);
  -- 禁止語そのものを通報理由に書くことはあり得るので、URL類だけを弾く
  if v_bad is not null and v_bad <> '禁止されている内容' then
    raise exception '通報の理由に使えない内容が含まれています（%）', v_bad;
  end if;
  return new;
end $$;

create trigger reports_before_insert
  before insert on public.reports
  for each row execute function public.reports_before_insert();

revoke execute on function public.reports_before_insert() from anon, authenticated, public;

-- 禁止パターンの追加は Supabase の SQL Editor で行う（例）：
--   insert into public.banned_patterns (pattern, note) values ('例の語', 'メモ');
-- 正規表現（PostgreSQL の書式）で、全角・大文字は半角・小文字にそろえた文字列と照合する。
