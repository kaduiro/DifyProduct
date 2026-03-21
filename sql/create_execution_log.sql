-- ============================================================
-- execution_log テーブル
-- AInews_TechIntelligence ワークフロー実行ログ
-- 作成日: 2026-03-21
-- ============================================================
-- 概要:
--   ワークフロー実行ごとの開始・完了・エラー情報を記録する。
--   各フェーズ（RSS取得, arXiv取得, Tavily検索, LLM分析, Slack配信, DB保存）の
--   成否をJSONBで保持し、障害分析・連続失敗検知に利用する。
-- ============================================================

CREATE TABLE IF NOT EXISTS execution_log (
    id                          UUID            DEFAULT gen_random_uuid() PRIMARY KEY,
    workflow_run_id              TEXT,
    execution_date               TIMESTAMPTZ     DEFAULT NOW(),
    status                       TEXT            CHECK (status IN ('started', 'completed', 'partial_failure', 'failed')),

    -- 各フェーズの成否
    -- 各JSONBの想定スキーマ:
    --   { "status": "success"|"error"|"skipped",
    --     "error_message": "...",
    --     "item_count": 0,
    --     "duration_ms": 0 }
    rss_fetch_status             JSONB           DEFAULT '{}',
    arxiv_fetch_status           JSONB           DEFAULT '{}',
    github_fetch_status          JSONB           DEFAULT '{}',
    tavily_search_status         JSONB           DEFAULT '{}',
    llm_analysis_status          JSONB           DEFAULT '{}',
    slack_delivery_status        JSONB           DEFAULT '{}',
    db_save_status               JSONB           DEFAULT '{}',

    -- 統計情報
    total_sources_attempted      INTEGER         DEFAULT 0,
    total_sources_succeeded      INTEGER         DEFAULT 0,
    total_articles_found         INTEGER         DEFAULT 0,
    total_articles_after_filter  INTEGER         DEFAULT 0,

    -- フォールバック情報
    fallback_level               INTEGER         DEFAULT 1 CHECK (fallback_level BETWEEN 1 AND 5),
    fallback_note                TEXT            DEFAULT '',

    -- エラー詳細
    -- 配列形式: [{ "node_id": "...", "node_name": "...", "error_type": "...", "message": "...", "timestamp": "..." }]
    error_details                JSONB           DEFAULT '[]',

    -- 実行時間
    duration_seconds             NUMERIC,

    created_at                   TIMESTAMPTZ     DEFAULT NOW()
);

-- インデックス: 実行日時降順（最新のログを高速に取得）
CREATE INDEX IF NOT EXISTS idx_execution_log_date
    ON execution_log (execution_date DESC);

-- インデックス: ステータスで絞り込み（失敗ログの検索用）
CREATE INDEX IF NOT EXISTS idx_execution_log_status
    ON execution_log (status);

-- インデックス: workflow_run_idで検索
CREATE INDEX IF NOT EXISTS idx_execution_log_run_id
    ON execution_log (workflow_run_id);

-- ============================================================
-- 連続失敗検知用ビュー
-- 直近N件の実行結果をステータスで集計する
-- ============================================================
CREATE OR REPLACE VIEW v_recent_execution_summary AS
SELECT
    COUNT(*)                                                    AS total_recent,
    COUNT(*) FILTER (WHERE status = 'completed')                AS completed_count,
    COUNT(*) FILTER (WHERE status = 'partial_failure')          AS partial_failure_count,
    COUNT(*) FILTER (WHERE status = 'failed')                   AS failed_count,
    MIN(execution_date)                                         AS oldest_date,
    MAX(execution_date)                                         AS latest_date
FROM (
    SELECT status, execution_date
    FROM execution_log
    ORDER BY execution_date DESC
    LIMIT 10
) recent;

-- ============================================================
-- 連続失敗検知用関数
-- 直近N件が全てfailedかどうかを判定する
-- ============================================================
CREATE OR REPLACE FUNCTION check_consecutive_failures(threshold INTEGER DEFAULT 3)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT COUNT(*) = threshold
    FROM (
        SELECT status
        FROM execution_log
        ORDER BY execution_date DESC
        LIMIT threshold
    ) recent
    WHERE status = 'failed';
$$;

-- ============================================================
-- RLS (Row Level Security) ポリシー
-- ============================================================
ALTER TABLE execution_log ENABLE ROW LEVEL SECURITY;

-- anon/authenticated ユーザーに読み取り・書き込みを許可
-- （ワークフローからの書き込みに必要）
CREATE POLICY "Allow read execution_log"
    ON execution_log FOR SELECT
    USING (true);

CREATE POLICY "Allow insert execution_log"
    ON execution_log FOR INSERT
    WITH CHECK (true);

CREATE POLICY "Allow update execution_log"
    ON execution_log FOR UPDATE
    USING (true);

-- ============================================================
-- コメント
-- ============================================================
COMMENT ON TABLE execution_log IS 'AInews_TechIntelligence ワークフローの実行ログ。各フェーズの成否・統計・エラー詳細を記録する。';
COMMENT ON COLUMN execution_log.status IS 'started: 実行開始, completed: 正常完了, partial_failure: 一部障害あり配信成功, failed: 配信失敗';
COMMENT ON COLUMN execution_log.fallback_level IS '1: 全ソース利用可, 2: Tavily障害, 3: RSS全滅, 4: arXivのみ, 5: 全滅';
COMMENT ON COLUMN execution_log.error_details IS 'エラー詳細の配列。各要素は node_id, node_name, error_type, message, timestamp を含む';
COMMENT ON VIEW v_recent_execution_summary IS '直近10件の実行結果サマリ。連続失敗の検知に使用';
COMMENT ON FUNCTION check_consecutive_failures IS '直近N件が全てfailedかどうかを判定する関数。デフォルト閾値は3';
