# 性界地図

性的な嗜好を分類した用語を、世界地図のように配置して関係線で結ぶWebアプリです。
利用者は自由に編集でき、すべての変更は履歴に残り、管理者が差し戻せます。

- 画面：`index.html`（GitHub Pages でそのまま公開）
- データ：Supabase（PostgreSQL＋認証）
- 自動整理：Supabase Edge Function から Claude API（Batch API）を毎日呼び、似た用語をまとめる中間の親を作る

## 構成

| ファイル | 内容 |
|---|---|
| `index.html` | 地図の画面。先頭の `SEIKAI_CONFIG` に Supabase の URL と anon key を入れる。空ならデモモード |
| `supabase/01_schema.sql` | テーブル・履歴・権限（RLS）・差し戻し関数 |
| `supabase/02_summarize.sql` | まとめ処理用のテーブルと関数（service_role 専用） |
| `supabase/03_schedule.sql` | まとめ処理を毎日呼ぶスケジュール |
| `supabase/04_privacy.sql` | 個人情報の最小化（氏名などを保存時に破棄、表示名を無作為に） |
| `supabase/05_content_rules.sql` | URL・連絡先・禁止パターンを登録時に拒否（禁止パターンの中身はリポジトリに含めない） |
| `supabase/06_rate_limit_and_ban.sql` | 書き込みを1時間に10件までに制限、管理者による利用者の停止（ログイン拒否） |
| `terms.html` / `privacy.html` | 利用規約 / プライバシーポリシー |
| `supabase/functions/summarize/index.ts` | まとめ処理の Edge Function |

## 公開の手順

1. Supabase でプロジェクトを作り、SQL Editor で `01_schema.sql` → `02_summarize.sql` の順に実行する
2. Authentication → Providers で Google と GitHub を有効にする（各サービスで OAuth アプリを作り、Client ID と Secret を登録）
3. Authentication → URL Configuration の Site URL と Redirect URLs に、GitHub Pages のアドレスを登録する
4. `index.html` の `SEIKAI_CONFIG` に Project URL と anon key を入れる（anon key は公開してよいキー。service_role key は絶対に入れない）
5. GitHub の Settings → Pages で、main ブランチの `/`（root）を公開元にする
6. 一度ログインしてから、SQL Editor で自分を管理者にする：
   ```sql
   update public.profiles set role = 'admin'
   where id = (select id from auth.users where email = 'あなたのメールアドレス');
   ```

### まとめ処理（任意）

```bash
supabase secrets set ANTHROPIC_API_KEY=sk-ant-... CRON_SECRET=長いランダムな文字列
supabase functions deploy summarize --no-verify-jwt
```

`?dry=1` を付けて呼ぶと、送信せずに候補だけを確認できます。
確認できたら pg_cron と pg_net を有効にし、`03_schedule.sql` の `<...>` を書き換えて実行します。
Claude Console で月の利用上限を設定しておいてください。
