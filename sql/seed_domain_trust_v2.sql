-- ============================================================
-- domain_trust 追加シードデータ (v2)
-- 生成日: 2026-03-22
-- ============================================================
-- 前提: seed_domain_trust.sql (95件) が適用済みであること
-- 冪等: ON CONFLICT (domain) DO UPDATE により何度でも安全に実行可能
-- ============================================================
-- 追加ドメイン: 22件
--   official   (10) : +20件 — フロントエンド/バックエンドFW、DevOps、DB、モバイル等
--   tech_blog  ( 6) : + 2件 — セキュリティ/インフラ系テックブログ
-- ============================================================
-- 注: thenewstack.io は seed_domain_trust.sql で登録済みのため除外
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- official (trust_score: 10) — フロントエンドフレームワーク
-- ------------------------------------------------------------
INSERT INTO domain_trust (domain, trust_score, category, created_at, updated_at) VALUES
    ('react.dev',                           10, 'official', NOW(), NOW()),
    ('blog.vuejs.org',                      10, 'official', NOW(), NOW()),
    ('blog.angular.dev',                    10, 'official', NOW(), NOW()),
    ('nextjs.org',                          10, 'official', NOW(), NOW()),
    ('svelte.dev',                          10, 'official', NOW(), NOW())
ON CONFLICT (domain) DO UPDATE SET
    trust_score = EXCLUDED.trust_score,
    category    = EXCLUDED.category,
    updated_at  = NOW();

-- ------------------------------------------------------------
-- official (trust_score: 10) — バックエンド言語・フレームワーク
-- ------------------------------------------------------------
INSERT INTO domain_trust (domain, trust_score, category, created_at, updated_at) VALUES
    ('go.dev',                              10, 'official', NOW(), NOW()),
    ('blog.rust-lang.org',                  10, 'official', NOW(), NOW()),
    ('spring.io',                           10, 'official', NOW(), NOW()),
    ('rubyonrails.org',                     10, 'official', NOW(), NOW()),
    ('typescriptlang.org',                  10, 'official', NOW(), NOW())
ON CONFLICT (domain) DO UPDATE SET
    trust_score = EXCLUDED.trust_score,
    category    = EXCLUDED.category,
    updated_at  = NOW();

-- ------------------------------------------------------------
-- official (trust_score: 10) — DevOps・モニタリング
-- ------------------------------------------------------------
INSERT INTO domain_trust (domain, trust_score, category, created_at, updated_at) VALUES
    ('hashicorp.com',                       10, 'official', NOW(), NOW()),
    ('grafana.com',                         10, 'official', NOW(), NOW()),
    ('datadoghq.com',                       10, 'official', NOW(), NOW())
ON CONFLICT (domain) DO UPDATE SET
    trust_score = EXCLUDED.trust_score,
    category    = EXCLUDED.category,
    updated_at  = NOW();

-- ------------------------------------------------------------
-- official (trust_score: 10) — データベース・BaaS
-- ------------------------------------------------------------
INSERT INTO domain_trust (domain, trust_score, category, created_at, updated_at) VALUES
    ('mongodb.com',                         10, 'official', NOW(), NOW()),
    ('redis.io',                            10, 'official', NOW(), NOW()),
    ('supabase.com',                        10, 'official', NOW(), NOW())
ON CONFLICT (domain) DO UPDATE SET
    trust_score = EXCLUDED.trust_score,
    category    = EXCLUDED.category,
    updated_at  = NOW();

-- ------------------------------------------------------------
-- official (trust_score: 10) — モバイル・ブラウザ・クラウドネイティブ
-- ------------------------------------------------------------
INSERT INTO domain_trust (domain, trust_score, category, created_at, updated_at) VALUES
    ('reactnative.dev',                     10, 'official', NOW(), NOW()),
    ('developer.chrome.com',                10, 'official', NOW(), NOW()),
    ('android-developers.googleblog.com',   10, 'official', NOW(), NOW()),
    ('cncf.io',                             10, 'official', NOW(), NOW())
ON CONFLICT (domain) DO UPDATE SET
    trust_score = EXCLUDED.trust_score,
    category    = EXCLUDED.category,
    updated_at  = NOW();

-- ------------------------------------------------------------
-- tech_blog (trust_score: 6) — セキュリティ・インフラ系ブログ
-- ------------------------------------------------------------
INSERT INTO domain_trust (domain, trust_score, category, created_at, updated_at) VALUES
    ('snyk.io',                             6, 'tech_blog', NOW(), NOW()),
    ('crowdstrike.com',                     6, 'tech_blog', NOW(), NOW())
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
-- 期待される結果（v1 + v2 合算）:
--   official        51件  avg=10.0
--   academic        15件  avg= 9.0
--   gov_regulation  12件  avg= 9.0
--   major_media     13件  avg= 8.0
--   tech_blog       12件  avg= 6.0
--   sns              5件  avg= 3.0
--   secondary_jp     9件  avg= 2.0
--   合計: 117件
