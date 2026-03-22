-- ============================================================
-- domain_trust シードデータ
-- 生成日: 2026-03-21
-- ============================================================
-- 前提: create_tables.sql で domain_trust テーブルが作成済みであること
-- 冪等: ON CONFLICT (domain) DO UPDATE により何度でも安全に実行可能
-- ============================================================
-- カテゴリ体系:
--   official       (10) : 公式ブログ・公式ドキュメント・公式エンジニアリングブログ
--   academic       ( 9) : 学術論文・学会・プレプリント
--   gov_regulation ( 9) : 政府機関・標準化団体・規制当局
--   major_media    ( 8) : 大手テックメディア
--   tech_blog      ( 6) : テック系ブログプラットフォーム
--   sns            ( 3) : ソーシャルメディア
--   secondary_jp   ( 2) : 二次情報（日本語）
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- 既存テーブルへのカラム追加（旧スキーマとの互換性確保）
-- IF NOT EXISTS により、カラムが既にある場合はスキップされる
-- ------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'domain_trust' AND column_name = 'updated_at'
    ) THEN
        ALTER TABLE domain_trust ADD COLUMN updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW();
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'domain_trust' AND column_name = 'usage_count'
    ) THEN
        ALTER TABLE domain_trust ADD COLUMN usage_count INTEGER DEFAULT 0;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'domain_trust' AND column_name = 'last_used_date'
    ) THEN
        ALTER TABLE domain_trust ADD COLUMN last_used_date DATE;
    END IF;
END $$;

-- ============================================================
-- STEP 1: 旧CHECK制約を先に削除（UPDATE前に実行が必須）
-- 制約名 domain_trust_category_check は確認済み
-- ============================================================
ALTER TABLE domain_trust DROP CONSTRAINT IF EXISTS domain_trust_category_check;

-- ============================================================
-- STEP 2: 旧カテゴリ値を新体系にマイグレーション（制約なしの状態で実行）
-- ============================================================
UPDATE domain_trust SET category = 'official'       WHERE category IN ('official_blog', 'official_docs', 'github', 'cloud_provider', 'ai_company', 'product_hunt');
UPDATE domain_trust SET category = 'academic'       WHERE category IN ('research', 'paper', 'preprint');
UPDATE domain_trust SET category = 'gov_regulation' WHERE category IN ('government', 'regulation', 'standards', 'gov');
UPDATE domain_trust SET category = 'major_media'    WHERE category IN ('press', 'media', 'news');
UPDATE domain_trust SET category = 'secondary_jp'   WHERE category IN ('secondary', 'curation');
-- 上記にマッチしなかった値を unknown に統一
UPDATE domain_trust SET category = 'unknown'        WHERE category NOT IN (
    'official', 'academic', 'major_media', 'gov_regulation',
    'tech_blog', 'sns', 'secondary_jp', 'unknown'
);

-- ============================================================
-- STEP 3: 新CHECK制約を追加
-- ============================================================
ALTER TABLE domain_trust ADD CONSTRAINT domain_trust_category_check
    CHECK (category IN (
        'official', 'academic', 'major_media',
        'gov_regulation', 'tech_blog', 'sns',
        'secondary_jp', 'unknown'
    ));

-- ------------------------------------------------------------
-- official (trust_score: 10) — 公式ブログ・ドキュメント
-- ------------------------------------------------------------
-- AI企業
INSERT INTO domain_trust (domain, trust_score, category, created_at, updated_at) VALUES
    ('openai.com',              10, 'official', NOW(), NOW()),
    ('anthropic.com',           10, 'official', NOW(), NOW()),
    ('ai.meta.com',             10, 'official', NOW(), NOW()),
    ('deepmind.google',         10, 'official', NOW(), NOW()),
    ('blog.google',             10, 'official', NOW(), NOW()),
    ('mistral.ai',              10, 'official', NOW(), NOW()),
    ('cohere.com',              10, 'official', NOW(), NOW()),
    ('stability.ai',            10, 'official', NOW(), NOW()),
    ('x.ai',                    10, 'official', NOW(), NOW()),
    ('ai.google.dev',           10, 'official', NOW(), NOW())
ON CONFLICT (domain) DO UPDATE SET
    trust_score = EXCLUDED.trust_score,
    category    = EXCLUDED.category,
    updated_at  = NOW();

-- クラウド・インフラ
INSERT INTO domain_trust (domain, trust_score, category, created_at, updated_at) VALUES
    ('aws.amazon.com',          10, 'official', NOW(), NOW()),
    ('cloud.google.com',        10, 'official', NOW(), NOW()),
    ('azure.microsoft.com',     10, 'official', NOW(), NOW()),
    ('developer.nvidia.com',    10, 'official', NOW(), NOW()),
    ('blog.cloudflare.com',     10, 'official', NOW(), NOW())
ON CONFLICT (domain) DO UPDATE SET
    trust_score = EXCLUDED.trust_score,
    category    = EXCLUDED.category,
    updated_at  = NOW();

-- 開発プラットフォーム・ツール
INSERT INTO domain_trust (domain, trust_score, category, created_at, updated_at) VALUES
    ('vercel.com',              10, 'official', NOW(), NOW()),
    ('docker.com',              10, 'official', NOW(), NOW()),
    ('kubernetes.io',           10, 'official', NOW(), NOW()),
    ('github.blog',             10, 'official', NOW(), NOW()),
    ('github.com',              10, 'official', NOW(), NOW()),
    ('nodejs.org',              10, 'official', NOW(), NOW()),
    ('python.org',              10, 'official', NOW(), NOW()),
    ('code.visualstudio.com',   10, 'official', NOW(), NOW())
ON CONFLICT (domain) DO UPDATE SET
    trust_score = EXCLUDED.trust_score,
    category    = EXCLUDED.category,
    updated_at  = NOW();

-- 大手企業エンジニアリングブログ
INSERT INTO domain_trust (domain, trust_score, category, created_at, updated_at) VALUES
    ('developer.apple.com',         10, 'official', NOW(), NOW()),
    ('developer.android.com',       10, 'official', NOW(), NOW()),
    ('devblogs.microsoft.com',      10, 'official', NOW(), NOW()),
    ('engineering.fb.com',          10, 'official', NOW(), NOW()),
    ('netflixtechblog.com',         10, 'official', NOW(), NOW()),
    ('blog.twitter.com',            10, 'official', NOW(), NOW()),
    ('engineering.atspotify.com',   10, 'official', NOW(), NOW()),
    ('uber.com',                    10, 'official', NOW(), NOW())
ON CONFLICT (domain) DO UPDATE SET
    trust_score = EXCLUDED.trust_score,
    category    = EXCLUDED.category,
    updated_at  = NOW();

-- ------------------------------------------------------------
-- academic (trust_score: 9) — 学術・論文
-- ------------------------------------------------------------
INSERT INTO domain_trust (domain, trust_score, category, created_at, updated_at) VALUES
    ('arxiv.org',               9, 'academic', NOW(), NOW()),
    ('paperswithcode.com',      9, 'academic', NOW(), NOW()),
    ('scholar.google.com',      9, 'academic', NOW(), NOW()),
    ('semanticscholar.org',     9, 'academic', NOW(), NOW()),
    ('openreview.net',          9, 'academic', NOW(), NOW()),
    ('proceedings.mlr.press',   9, 'academic', NOW(), NOW()),
    ('aclweb.org',              9, 'academic', NOW(), NOW()),
    ('neurips.cc',              9, 'academic', NOW(), NOW()),
    ('icml.cc',                 9, 'academic', NOW(), NOW()),
    ('iclr.cc',                 9, 'academic', NOW(), NOW()),
    ('aaai.org',                9, 'academic', NOW(), NOW()),
    ('dl.acm.org',              9, 'academic', NOW(), NOW()),
    ('ieee.org',                9, 'academic', NOW(), NOW()),
    ('nature.com',              9, 'academic', NOW(), NOW()),
    ('science.org',             9, 'academic', NOW(), NOW())
ON CONFLICT (domain) DO UPDATE SET
    trust_score = EXCLUDED.trust_score,
    category    = EXCLUDED.category,
    updated_at  = NOW();

-- ------------------------------------------------------------
-- gov_regulation (trust_score: 9) — 政府・標準化団体
-- ------------------------------------------------------------
INSERT INTO domain_trust (domain, trust_score, category, created_at, updated_at) VALUES
    ('nist.gov',                        9, 'gov_regulation', NOW(), NOW()),
    ('cisa.gov',                        9, 'gov_regulation', NOW(), NOW()),
    ('ftc.gov',                         9, 'gov_regulation', NOW(), NOW()),
    ('whitehouse.gov',                  9, 'gov_regulation', NOW(), NOW()),
    ('digital-strategy.ec.europa.eu',   9, 'gov_regulation', NOW(), NOW()),
    ('w3.org',                          9, 'gov_regulation', NOW(), NOW()),
    ('ietf.org',                        9, 'gov_regulation', NOW(), NOW()),
    ('openssf.org',                     9, 'gov_regulation', NOW(), NOW()),
    ('meti.go.jp',                      9, 'gov_regulation', NOW(), NOW()),
    ('soumu.go.jp',                     9, 'gov_regulation', NOW(), NOW()),
    ('digital.go.jp',                   9, 'gov_regulation', NOW(), NOW()),
    ('ppc.go.jp',                       9, 'gov_regulation', NOW(), NOW())
ON CONFLICT (domain) DO UPDATE SET
    trust_score = EXCLUDED.trust_score,
    category    = EXCLUDED.category,
    updated_at  = NOW();

-- ------------------------------------------------------------
-- major_media (trust_score: 8) — 大手テックメディア
-- ------------------------------------------------------------
INSERT INTO domain_trust (domain, trust_score, category, created_at, updated_at) VALUES
    ('techcrunch.com',      8, 'major_media', NOW(), NOW()),
    ('wired.com',           8, 'major_media', NOW(), NOW()),
    ('theverge.com',        8, 'major_media', NOW(), NOW()),
    ('arstechnica.com',     8, 'major_media', NOW(), NOW()),
    ('venturebeat.com',     8, 'major_media', NOW(), NOW()),
    ('siliconangle.com',    8, 'major_media', NOW(), NOW()),
    ('infoworld.com',       8, 'major_media', NOW(), NOW()),
    ('zdnet.com',           8, 'major_media', NOW(), NOW()),
    ('theregister.com',     8, 'major_media', NOW(), NOW()),
    ('reuters.com',         8, 'major_media', NOW(), NOW()),
    ('bloomberg.com',       8, 'major_media', NOW(), NOW()),
    ('nikkei.com',          8, 'major_media', NOW(), NOW()),
    ('itmedia.co.jp',       8, 'major_media', NOW(), NOW())
ON CONFLICT (domain) DO UPDATE SET
    trust_score = EXCLUDED.trust_score,
    category    = EXCLUDED.category,
    updated_at  = NOW();

-- ------------------------------------------------------------
-- tech_blog (trust_score: 6) — テックブログ
-- ------------------------------------------------------------
INSERT INTO domain_trust (domain, trust_score, category, created_at, updated_at) VALUES
    ('huggingface.co',              6, 'tech_blog', NOW(), NOW()),
    ('blog.langchain.dev',          6, 'tech_blog', NOW(), NOW()),
    ('llamaindex.ai',               6, 'tech_blog', NOW(), NOW()),
    ('medium.com',                  6, 'tech_blog', NOW(), NOW()),
    ('dev.to',                      6, 'tech_blog', NOW(), NOW()),
    ('hackernoon.com',              6, 'tech_blog', NOW(), NOW()),
    ('thenewstack.io',              6, 'tech_blog', NOW(), NOW()),
    ('dzone.com',                   6, 'tech_blog', NOW(), NOW()),
    ('martinfowler.com',            6, 'tech_blog', NOW(), NOW()),
    ('blog.pragmaticengineer.com',  6, 'tech_blog', NOW(), NOW())
ON CONFLICT (domain) DO UPDATE SET
    trust_score = EXCLUDED.trust_score,
    category    = EXCLUDED.category,
    updated_at  = NOW();

-- ------------------------------------------------------------
-- sns (trust_score: 3) — ソーシャルメディア
-- ------------------------------------------------------------
INSERT INTO domain_trust (domain, trust_score, category, created_at, updated_at) VALUES
    ('twitter.com',             3, 'sns', NOW(), NOW()),
    ('x.com',                   3, 'sns', NOW(), NOW()),
    ('reddit.com',              3, 'sns', NOW(), NOW()),
    ('news.ycombinator.com',    3, 'sns', NOW(), NOW()),
    ('lobste.rs',               3, 'sns', NOW(), NOW())
ON CONFLICT (domain) DO UPDATE SET
    trust_score = EXCLUDED.trust_score,
    category    = EXCLUDED.category,
    updated_at  = NOW();

-- ------------------------------------------------------------
-- secondary_jp (trust_score: 2) — 二次情報（日本語）
-- ------------------------------------------------------------
INSERT INTO domain_trust (domain, trust_score, category, created_at, updated_at) VALUES
    ('qiita.com',                   2, 'secondary_jp', NOW(), NOW()),
    ('zenn.dev',                    2, 'secondary_jp', NOW(), NOW()),
    ('note.com',                    2, 'secondary_jp', NOW(), NOW()),
    ('hatena.ne.jp',                2, 'secondary_jp', NOW(), NOW()),
    ('gigazine.net',                2, 'secondary_jp', NOW(), NOW()),
    ('publickey1.jp',               2, 'secondary_jp', NOW(), NOW()),
    ('gihyo.jp',                    2, 'secondary_jp', NOW(), NOW()),
    ('codezine.jp',                 2, 'secondary_jp', NOW(), NOW()),
    ('atmarkit.itmedia.co.jp',      2, 'secondary_jp', NOW(), NOW())
ON CONFLICT (domain) DO UPDATE SET
    trust_score = EXCLUDED.trust_score,
    category    = EXCLUDED.category,
    updated_at  = NOW();

COMMIT;

-- ============================================================
-- 確認用クエリ（実行は任意）
-- ============================================================
-- SELECT category, COUNT(*) AS cnt, AVG(trust_score) AS avg_score
--   FROM domain_trust
--  GROUP BY category
--  ORDER BY avg_score DESC;
--
-- 期待される結果:
--   official        31件  avg=10.0
--   academic        15件  avg= 9.0
--   gov_regulation  12件  avg= 9.0
--   major_media     13件  avg= 8.0
--   tech_blog       10件  avg= 6.0
--   sns              5件  avg= 3.0
--   secondary_jp     9件  avg= 2.0
--   合計: 95件
