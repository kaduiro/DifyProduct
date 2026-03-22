-- ============================================================
-- Supabase Schema v4.0 - AI Tech Intelligence ワークフロー用
-- 生成日: 2026-03-20
-- ============================================================
-- 概要:
--   watch_entities : 3軸統合ウォッチリスト（企業・OSS・カテゴリ）
--   deliveries     : 配信履歴
--   article_hashes : 記事重複検知
--   domain_trust   : ドメイン信頼度（一次情報優先スコアリング）
-- ============================================================

BEGIN;

-- ============================================================
-- 1. watch_entities（3軸統合ウォッチリスト）
-- ============================================================
-- 企業・OSS・カテゴリを1つのテーブルで統合管理する。
-- entity_type で種別を区別し、priority で収集優先度を制御する。

CREATE TABLE watch_entities (
    id                  BIGSERIAL    PRIMARY KEY,
    name                TEXT         NOT NULL,
    entity_type         TEXT         NOT NULL CHECK (entity_type IN ('company', 'oss', 'category')),
    status              TEXT         NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'paused', 'archived')),
    priority            INTEGER      NOT NULL DEFAULT 5 CHECK (priority BETWEEN 1 AND 10),
    search_names        JSONB        DEFAULT '[]',        -- 検索に使う別名リスト
    official_domain     TEXT,                              -- 公式ドメイン（企業向け）
    github_repo         TEXT,                              -- GitHubリポジトリ（OSS向け）
    search_terms        JSONB        DEFAULT '[]',         -- 検索キーワード（カテゴリ向け）
    hit_count           INTEGER      DEFAULT 0,            -- 記事ヒット累計
    miss_count          INTEGER      DEFAULT 0,            -- ミス累計
    consecutive_misses  INTEGER      DEFAULT 0,            -- 連続ミス回数
    last_hit_date       DATE,                              -- 最終ヒット日
    added_date          DATE         NOT NULL DEFAULT CURRENT_DATE,
    notes               TEXT,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- インデックス: タイプ×ステータスで絞り込み
CREATE INDEX idx_watch_entities_type_status ON watch_entities(entity_type, status);
-- インデックス: 優先度降順でソート
CREATE INDEX idx_watch_entities_priority ON watch_entities(priority DESC);


-- ============================================================
-- 2. deliveries（配信履歴）
-- ============================================================
-- 各回の配信結果を記録する。カテゴリ別集計・キーワード・差分サマリを保持。

CREATE TABLE deliveries (
    id                     BIGSERIAL    PRIMARY KEY,
    delivery_date          DATE         NOT NULL,
    date_range             TEXT         NOT NULL,           -- 例: "2026-03-13~2026-03-20"
    categories             JSONB        NOT NULL DEFAULT '{}',
    keywords               JSONB        NOT NULL DEFAULT '[]',
    diff_summary           JSONB        DEFAULT '{}',       -- 前回比の差分サマリ
    raw_finding_count      INTEGER,                         -- フィルタ前の件数
    filtered_finding_count INTEGER,                         -- フィルタ後の件数
    created_at             TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- インデックス: 配信日降順
CREATE INDEX idx_deliveries_date ON deliveries(delivery_date DESC);


-- ============================================================
-- 3. article_hashes（記事重複検知）
-- ============================================================
-- 記事タイトル等からハッシュを生成し、重複配信を防止する。

CREATE TABLE article_hashes (
    id              BIGSERIAL    PRIMARY KEY,
    hash            TEXT         NOT NULL,
    title           TEXT         NOT NULL,
    url             TEXT,
    source_domain   TEXT,
    first_seen_date DATE         NOT NULL,
    delivery_id     BIGINT       REFERENCES deliveries(id),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ユニークインデックス: ハッシュ値で重複を防止
CREATE UNIQUE INDEX idx_article_hashes_hash ON article_hashes(hash);
-- インデックス: 初回検出日
CREATE INDEX idx_article_hashes_date ON article_hashes(first_seen_date);


-- ============================================================
-- 4. domain_trust（ドメイン信頼度）
-- ============================================================
-- 一次情報（公式ブログ・公式ドキュメント）を優先するためのスコアリング。
-- trust_score: 1(低)〜10(高)

CREATE TABLE domain_trust (
    id             BIGSERIAL    PRIMARY KEY,
    domain         TEXT         NOT NULL UNIQUE,
    trust_score    INTEGER      NOT NULL DEFAULT 5 CHECK (trust_score BETWEEN 1 AND 10),
    category       TEXT         CHECK (category IN (
                       'official_blog', 'official_docs', 'github',
                       'product_hunt', 'press', 'major_media',
                       'tech_blog', 'sns', 'unknown'
                   )),
    usage_count    INTEGER      DEFAULT 0,
    last_used_date DATE,
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);


-- ============================================================
-- 初期データ投入
-- ============================================================

-- ------------------------------------------------------------
-- watch_entities: 企業 20社
-- ------------------------------------------------------------
INSERT INTO watch_entities (name, entity_type, priority, search_names, official_domain) VALUES
    ('OpenAI',         'company', 10, '["OpenAI"]',                          'openai.com'),
    ('Anthropic',      'company', 10, '["Anthropic", "Claude"]',             'anthropic.com'),
    ('Google DeepMind','company',  9, '["Google DeepMind", "Gemini API"]',   'deepmind.google'),
    ('Meta AI',        'company',  9, '["Meta AI", "Llama"]',               'ai.meta.com'),
    ('Cursor',         'company',  8, '["Cursor AI", "Cursor IDE"]',        'cursor.com'),
    ('Vercel',         'company',  7, '["Vercel", "v0.dev"]',               'vercel.com'),
    ('Mistral',        'company',  8, '["Mistral AI"]',                     'mistral.ai'),
    ('Hugging Face',   'company',  8, '["Hugging Face", "HuggingFace"]',    'huggingface.co'),
    ('Replicate',      'company',  7, '["Replicate"]',                      'replicate.com'),
    ('Modal',          'company',  7, '["Modal"]',                          'modal.com'),
    ('Together AI',    'company',  7, '["Together AI"]',                    'together.ai'),
    ('Fireworks AI',   'company',  7, '["Fireworks AI"]',                   'fireworks.ai'),
    ('Groq',           'company',  8, '["Groq"]',                           'groq.com'),
    ('Cohere',         'company',  7, '["Cohere"]',                         'cohere.com'),
    ('LangChain',      'company',  8, '["LangChain", "LangSmith"]',        'langchain.com'),
    ('LlamaIndex',     'company',  7, '["LlamaIndex"]',                    'llamaindex.ai'),
    ('CrewAI',         'company',  7, '["CrewAI"]',                         'crewai.com'),
    ('Stability AI',   'company',  6, '["Stability AI"]',                   'stability.ai'),
    ('Perplexity',     'company',  8, '["Perplexity"]',                     'perplexity.ai'),
    ('Windsurf',       'company',  7, '["Windsurf", "Codeium"]',            'windsurf.com');

-- ------------------------------------------------------------
-- watch_entities: OSS 17件
-- ------------------------------------------------------------
INSERT INTO watch_entities (name, entity_type, priority, github_repo) VALUES
    ('llama.cpp',              'oss', 9, 'llama-cpp/llama.cpp'),
    ('vllm',                   'oss', 9, 'vllm-project/vllm'),
    ('ollama',                 'oss', 9, 'ollama/ollama'),
    ('langchain',              'oss', 8, 'langchain-ai/langchain'),
    ('llamaindex',             'oss', 7, 'run-llama/llama_index'),
    ('crewai',                 'oss', 7, 'crewAIInc/crewAI'),
    ('autogen',                'oss', 7, 'microsoft/autogen'),
    ('browser-use',            'oss', 7, 'browser-use/browser-use'),
    ('openai-agents-sdk',      'oss', 8, 'openai/openai-agents-python'),
    ('mcp-servers',            'oss', 8, 'modelcontextprotocol/servers'),
    ('dify',                   'oss', 8, 'langgenius/dify'),
    ('n8n',                    'oss', 6, 'n8n-io/n8n'),
    ('flowise',                'oss', 6, 'FlowiseAI/Flowise'),
    ('comfyui',                'oss', 6, 'comfyanonymous/ComfyUI'),
    ('whisper',                'oss', 6, 'openai/whisper'),
    ('onnxruntime',            'oss', 5, 'microsoft/onnxruntime'),
    ('stable-diffusion-webui', 'oss', 5, 'AUTOMATIC1111/stable-diffusion-webui');

-- ------------------------------------------------------------
-- watch_entities: カテゴリ 14件
-- ------------------------------------------------------------
INSERT INTO watch_entities (name, entity_type, priority, search_terms) VALUES
    ('AI IDE',                  'category', 9, '["AI IDE", "AI code editor", "coding assistant"]'),
    ('eval framework',          'category', 7, '["LLM eval", "evaluation framework", "LLM benchmark"]'),
    ('agent infrastructure',    'category', 9, '["AI agent framework", "agent platform", "agentic AI"]'),
    ('browser automation',      'category', 7, '["browser automation", "web agent", "browser-use"]'),
    ('voice agent',             'category', 6, '["voice AI", "speech agent", "voice assistant API"]'),
    ('MCP',                     'category', 8, '["Model Context Protocol", "MCP server", "MCP client"]'),
    ('vector database',         'category', 7, '["vector database", "vector store", "embedding database"]'),
    ('inference infrastructure','category', 8, '["LLM inference", "inference engine", "serving framework"]'),
    ('code generation',         'category', 8, '["code generation", "AI coding", "copilot"]'),
    ('AI code review',          'category', 6, '["AI code review", "automated review"]'),
    ('RAG pipeline',            'category', 7, '["RAG pipeline", "retrieval augmented", "RAG framework"]'),
    ('multimodal AI',           'category', 7, '["multimodal AI", "vision language model", "VLM"]'),
    ('on-device AI',            'category', 6, '["on-device AI", "edge AI", "local LLM"]'),
    ('AI observability',        'category', 6, '["LLM observability", "AI monitoring", "LLM tracing"]');

-- ------------------------------------------------------------
-- domain_trust: ドメイン信頼度（一次情報優先）
-- ------------------------------------------------------------

-- Tier 1: 公式ブログ (score=10)
INSERT INTO domain_trust (domain, trust_score, category) VALUES
    ('openai.com',                10, 'official_blog'),
    ('anthropic.com',             10, 'official_blog'),
    ('deepmind.google',           10, 'official_blog'),
    ('ai.meta.com',               10, 'official_blog'),
    ('blog.google',               10, 'official_blog'),
    ('aws.amazon.com/blogs',      10, 'official_blog'),
    ('azure.microsoft.com/blog',  10, 'official_blog');

-- Tier 2: 公式ドキュメント (score=9)
INSERT INTO domain_trust (domain, trust_score, category) VALUES
    ('docs.anthropic.com',   9, 'official_docs'),
    ('platform.openai.com',  9, 'official_docs'),
    ('ai.google.dev',        9, 'official_docs'),
    ('docs.mistral.ai',      9, 'official_docs'),
    ('docs.cohere.com',      9, 'official_docs'),
    ('docs.langchain.com',   9, 'official_docs'),
    ('docs.llamaindex.ai',   9, 'official_docs'),
    ('huggingface.co/docs',  9, 'official_docs');

-- Tier 3: GitHub (score=9)
INSERT INTO domain_trust (domain, trust_score, category) VALUES
    ('github.com',  9, 'github'),
    ('github.blog', 9, 'github');

-- Tier 4: Product Hunt (score=8)
INSERT INTO domain_trust (domain, trust_score, category) VALUES
    ('producthunt.com', 8, 'product_hunt');

-- Tier 5: テック系プレス (score=7)
INSERT INTO domain_trust (domain, trust_score, category) VALUES
    ('ycombinator.com', 7, 'press'),
    ('techcrunch.com',  7, 'press'),
    ('theverge.com',    7, 'press'),
    ('arstechnica.com', 7, 'press'),
    ('wired.com',       7, 'press');

-- Tier 6: 大手メディア (score=5)
INSERT INTO domain_trust (domain, trust_score, category) VALUES
    ('reuters.com',   5, 'major_media'),
    ('bloomberg.com', 5, 'major_media'),
    ('nytimes.com',   5, 'major_media');

-- Tier 7: テックブログ (score=3)
INSERT INTO domain_trust (domain, trust_score, category) VALUES
    ('qiita.com',    3, 'tech_blog'),
    ('zenn.dev',     3, 'tech_blog'),
    ('medium.com',   3, 'tech_blog'),
    ('dev.to',       3, 'tech_blog'),
    ('hashnode.dev', 3, 'tech_blog');

-- Tier 8: SNS (score=2)
INSERT INTO domain_trust (domain, trust_score, category) VALUES
    ('twitter.com', 2, 'sns'),
    ('x.com',       2, 'sns'),
    ('reddit.com',  2, 'sns');

COMMIT;

-- ============================================================
-- 確認用クエリ（実行は任意）
-- ============================================================
-- SELECT entity_type, COUNT(*) FROM watch_entities GROUP BY entity_type;
-- SELECT category, COUNT(*), AVG(trust_score) FROM domain_trust GROUP BY category ORDER BY AVG(trust_score) DESC;
