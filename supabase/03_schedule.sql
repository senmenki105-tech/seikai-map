-- =====================================================================
-- 性界地図：まとめ処理を毎日実行するスケジュール
-- 1. Supabase の Database → Extensions で pg_cron と pg_net を有効にする
-- 2. 下の <...> を書き換えて SQL Editor で実行する
--    <project-ref>   ：プロジェクトのURL https://<project-ref>.supabase.co の部分
--    <cron-secret>   ：Edge Function に設定した CRON_SECRET と同じ値
-- =====================================================================

-- 合言葉は Vault（暗号化して保存する仕組み）に入れる
select vault.create_secret('<cron-secret>', 'seikai_cron_secret');

-- 毎日 3:17（UTC）に実行。日本時間では 12:17。
-- 結果の回収→反映→次の送信を1回の呼び出しで行う。
-- Batch API は最長24時間かかるため、送った分は翌日の実行で反映される。
select cron.schedule(
  'seikai-summarize',
  '17 3 * * *',
  $$
  select net.http_post(
    url     := 'https://<project-ref>.supabase.co/functions/v1/summarize',
    headers := jsonb_build_object(
      'content-type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'seikai_cron_secret')
    ),
    body    := '{}'::jsonb,
    timeout_milliseconds := 120000
  );
  $$
);

-- 確認・変更用
-- select * from cron.job;                                   -- 登録されたスケジュール
-- select * from cron.job_run_details order by start_time desc limit 10;  -- 実行結果
-- select * from public.summarize_jobs order by id desc;      -- まとめ処理のジョブ
-- select cron.unschedule('seikai-summarize');                -- 止める
