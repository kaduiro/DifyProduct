-- ============================================================
-- Supabase テーブル定義 - AI Tech Intelligence ワークフロー用
-- 対象: domain_trust, deliveries, watch_entities, article_hashes
-- 生成日: 2026-03-21
-- 互換性: Supabase (PostgreSQL 15+)
-- ============================================================
-- 実行方法: Supabase SQL Editor にて実行
-- 冪等: IF NOT EXISTS を使用しているため何度でも安全に実行可能
-- ============================================================

BEGIN;

-- ============================================================
-- 1. domain_trust（ドメイン信頼度スコアリング）
-- ============================================================
-- 一次情報ソースを優先するためのスコアリングテーブル。
-- trust_score: 1(低) 〜 10(高)
-- category: official, academic, major_media, gov_regulation,
--           tech_blog, sns, secondary_jp, unknown

CREATE TABLE IF NOT EXISTS domain_trust (
    id             BIGSERIAL    PRIMARY KEY,
    domain         TEXT         NOT NULL UNIQUE,
    trust_score    INTEGER      NOT NULL DEFAULT 5
                                CHECK (trust_score BETWEEN 1 AND 10),
    category       TEXT         NOT NULL DEFAULT 'unknown'
                                CHECK (category IN (
                                    'official', 'academic', 'major_media',
                                    'gov_regulation', 'tech_blog', 'sns',
                                    'secondary_jp', 'unknown'
                                )),
    usage_count    INTEGER      DEFAULT 0,
    last_used_date DATE,
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_domain_trust_category
    ON domain_trust(category);
CREATE INDEX IF NOT EXISTS idx_domain_trust_score
    ON domain_trust(trust_score DESC);

-- ============================================================
-- 2. deliveries（配信履歴）
-- ============================================================
-- 各回の配信結果を記録する。

CREATE TABLE IF NOT EXISTS deliveries (
    id                     BIGSERIAL    PRIMARY KEY,
    delivery_date          DATE         NOT NULL,
    date_range             TEXT         NOT NULL,
    categories             JSONB        NOT NULL DEFAULT '{}',
    keywords               JSONB        NOT NULL DEFAULT '[]',
    diff_summary           JSONB        DEFAULT '{}',
    raw_finding_count      INTEGER,
    filtered_finding_count INTEGER,
    created_at             TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_deliveries_date
    ON deliveries(delivery_date DESC);

-- ============================================================
-- 3. watch_entities（3軸統合ウォッチリスト）
-- ============================================================
-- 企業・OSS・カテゴリを1つのテーブルで統合管理する。

CREATE TABLE IF NOT EXISTS watch_entities (
    id                  BIGSERIAL    PRIMARY KEY,
    name                TEXT         NOT NULL,
    entity_type         TEXT         NOT NULL
                                    CHECK (entity_type IN ('company', 'oss', 'category')),
    status              TEXT         NOT NULL DEFAULT 'active'
                                    CHECK (status IN ('active', 'paused', 'archived')),
    priority            INTEGER      NOT NULL DEFAULT 5
                                    CHECK (priority BETWEEN 1 AND 10),
    search_names        JSONB        DEFAULT '[]',
    official_domain     TEXT,
    github_repo         TEXT,
    search_terms        JSONB        DEFAULT '[]',
    hit_count           INTEGER      DEFAULT 0,
    miss_count          INTEGER      DEFAULT 0,
    consecutive_misses  INTEGER      DEFAULT 0,
    last_hit_date       DATE,
    added_date          DATE         NOT NULL DEFAULT CURRENT_DATE,
    notes               TEXT,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_watch_entities_type_status
    ON watch_entities(entity_type, status);
CREATE INDEX IF NOT EXISTS idx_watch_entities_priority
    ON watch_entities(priority DESC);

-- ============================================================
-- 4. article_hashes（記事重複検知）
-- ============================================================
-- 記事タイトル等からハッシュを生成し、重複配信を防止する。

CREATE TABLE IF NOT EXISTS article_hashes (
    id              BIGSERIAL    PRIMARY KEY,
    hash            TEXT         NOT NULL,
    title           TEXT         NOT NULL,
    url             TEXT,
    source_domain   TEXT,
    first_seen_date DATE         NOT NULL,
    delivery_id     BIGINT       REFERENCES deliveries(id),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_article_hashes_hash
    ON article_hashes(hash);
CREATE INDEX IF NOT EXISTS idx_article_hashes_date
    ON article_hashes(first_seen_date);

COMMIT;

-- ============================================================
-- 確認用クエリ（実行は任意）
-- ============================================================
-- SELECT tablename FROM pg_tables WHERE schemaname = 'public';
-- SELECT column_name, data_type, is_nullable FROM information_schema.columns WHERE table_name = 'domain_trust';
