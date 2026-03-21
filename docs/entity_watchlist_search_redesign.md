# 3軸エンティティウォッチ検索戦略 再設計書

## 背景

2つの根本的な指摘を受け、検索戦略を抜本的に見直す。

### 指摘1: 日本語依存をやめて英語ソースを標準にする
- Qiita/Zennに乗らない情報は日本語圏にまだ入っていないことが多い
- 検索語も日本語トピックではなく、英語の製品カテゴリ + launch系語彙にする

### 指摘2: トピック検索ではなく企業・製品ウォッチを作る
- 新技術は一般検索だけだと埋もれる
- 注目企業リスト、注目OSSリスト、注目カテゴリリストを持ち、毎回その集合に対して監視する

### 従来設計との違い

| 項目 | 従来（fixed_category_watchlist_design） | 新設計 |
|------|----------------------------------------|--------|
| 検索言語 | 日英混在（query_ja / query_en） | **英語のみ** |
| 検索対象 | 5つの固定カテゴリ + 自由ウォッチリスト | **3軸（企業・OSS・カテゴリ）の構造化リスト** |
| クエリ生成 | LLM依存 or 単純テンプレート | **出来事語彙(event vocab)との組合せで決定的生成** |
| ウォッチリスト | 単一テーブル（watchlist） | **3テーブル（axis別）で管理** |
| クエリ数制御 | 固定5+α | **企業8 + OSS6 + カテゴリ4 = 18クエリ（優先度制御）** |

---

## 1. Supabaseスキーマ設計

### 1-1. 3軸ウォッチリストテーブル

```sql
-- =============================================
-- 旧テーブルのドロップ（必要に応じて）
-- 旧 watchlist テーブルが存在する場合はマイグレーションを実施
-- =============================================

-- =============================================
-- テーブル1: 企業ウォッチリスト
-- =============================================
CREATE TABLE watch_companies (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,               -- 企業名（英語表記）: "OpenAI"
    aliases TEXT[] DEFAULT '{}',             -- 別名・表記揺れ: {"open ai", "openai inc"}
    website TEXT,                             -- 公式サイトURL
    category TEXT DEFAULT 'ai_lab',          -- ai_lab / infra / tooling / oss_org
    priority INTEGER DEFAULT 5               -- 1-10: 高いほど優先的にクエリ枠を使う
        CHECK (priority BETWEEN 1 AND 10),
    status TEXT DEFAULT 'active'
        CHECK (status IN ('active', 'paused', 'archived')),
    last_hit_at TIMESTAMPTZ,                 -- 最後に検索結果がヒットした日時
    hit_count INTEGER DEFAULT 0,             -- 累計ヒット回数
    consecutive_miss INTEGER DEFAULT 0,      -- 連続ミス回数（自動アーカイブ判定用）
    added_by TEXT DEFAULT 'seed',            -- seed / auto_discovered / manual
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_watch_companies_status ON watch_companies(status);
CREATE INDEX idx_watch_companies_priority ON watch_companies(priority DESC);

-- =============================================
-- テーブル2: OSSウォッチリスト
-- =============================================
CREATE TABLE watch_oss (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,               -- リポジトリ名: "vllm"
    github_repo TEXT,                        -- フルパス: "vllm-project/vllm"
    aliases TEXT[] DEFAULT '{}',             -- 別名: {"vLLM"}
    category TEXT DEFAULT 'inference',       -- inference / framework / agent / tool / model
    priority INTEGER DEFAULT 5
        CHECK (priority BETWEEN 1 AND 10),
    status TEXT DEFAULT 'active'
        CHECK (status IN ('active', 'paused', 'archived')),
    last_hit_at TIMESTAMPTZ,
    hit_count INTEGER DEFAULT 0,
    consecutive_miss INTEGER DEFAULT 0,
    added_by TEXT DEFAULT 'seed',
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_watch_oss_status ON watch_oss(status);
CREATE INDEX idx_watch_oss_priority ON watch_oss(priority DESC);

-- =============================================
-- テーブル3: カテゴリウォッチリスト
-- =============================================
CREATE TABLE watch_categories (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,               -- カテゴリ名（英語）: "AI IDE"
    description TEXT,                        -- カテゴリの説明
    search_terms TEXT[] DEFAULT '{}',        -- 補助検索語: {"cursor", "copilot", "windsurf"}
    priority INTEGER DEFAULT 5
        CHECK (priority BETWEEN 1 AND 10),
    status TEXT DEFAULT 'active'
        CHECK (status IN ('active', 'paused', 'archived')),
    last_hit_at TIMESTAMPTZ,
    hit_count INTEGER DEFAULT 0,
    consecutive_miss INTEGER DEFAULT 0,
    added_by TEXT DEFAULT 'seed',
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_watch_categories_status ON watch_categories(status);
CREATE INDEX idx_watch_categories_priority ON watch_categories(priority DESC);

-- =============================================
-- テーブル4: 検索ヒット履歴（3軸共通）
-- =============================================
CREATE TABLE watch_hits (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    axis TEXT NOT NULL                       -- 'company' / 'oss' / 'category'
        CHECK (axis IN ('company', 'oss', 'category')),
    entity_name TEXT NOT NULL,               -- ヒットしたエンティティ名
    hit_date DATE NOT NULL DEFAULT CURRENT_DATE,
    query_used TEXT,                          -- 実際に使用したクエリ
    result_count INTEGER DEFAULT 0,          -- ヒット件数
    top_results JSONB DEFAULT '[]'::jsonb,   -- 上位結果のサマリ [{title, url, snippet}]
    created_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE(axis, entity_name, hit_date)      -- 同一日・同一エンティティは1レコード
);

CREATE INDEX idx_watch_hits_date ON watch_hits(hit_date DESC);
CREATE INDEX idx_watch_hits_axis ON watch_hits(axis);

-- =============================================
-- テーブル5: 自動発見キュー
-- 検索結果から未知の企業・OSSを自動検出し、追加候補として保持
-- =============================================
CREATE TABLE watch_discovery_queue (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    axis TEXT NOT NULL
        CHECK (axis IN ('company', 'oss', 'category')),
    name TEXT NOT NULL,
    discovered_from TEXT,                    -- どの検索結果から発見されたか
    mention_count INTEGER DEFAULT 1,         -- 発見回数（多いほど追加すべき）
    status TEXT DEFAULT 'pending'
        CHECK (status IN ('pending', 'approved', 'rejected')),
    created_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE(axis, name)
);

-- =============================================
-- 自動アーカイブ用 RPC関数
-- 5回連続ミスでstatusをarchivedに変更
-- =============================================
CREATE OR REPLACE FUNCTION auto_archive_stale_watches()
RETURNS void AS $$
BEGIN
    UPDATE watch_companies SET status = 'archived', updated_at = now()
    WHERE status = 'active' AND consecutive_miss >= 5;

    UPDATE watch_oss SET status = 'archived', updated_at = now()
    WHERE status = 'active' AND consecutive_miss >= 5;

    UPDATE watch_categories SET status = 'archived', updated_at = now()
    WHERE status = 'active' AND consecutive_miss >= 5;
END;
$$ LANGUAGE plpgsql;

-- =============================================
-- ヒット時にカウンター更新する RPC関数
-- =============================================
CREATE OR REPLACE FUNCTION record_watch_hit(
    p_axis TEXT,
    p_entity_name TEXT,
    p_query TEXT,
    p_result_count INTEGER,
    p_top_results JSONB
)
RETURNS void AS $$
BEGIN
    -- ヒット履歴を記録
    INSERT INTO watch_hits (axis, entity_name, query_used, result_count, top_results)
    VALUES (p_axis, p_entity_name, p_query, p_result_count, p_top_results)
    ON CONFLICT (axis, entity_name, hit_date)
    DO UPDATE SET
        result_count = watch_hits.result_count + EXCLUDED.result_count,
        top_results = watch_hits.top_results || EXCLUDED.top_results;

    -- エンティティのカウンター更新
    IF p_axis = 'company' THEN
        UPDATE watch_companies
        SET hit_count = hit_count + 1,
            last_hit_at = now(),
            consecutive_miss = 0,
            updated_at = now()
        WHERE name = p_entity_name;
    ELSIF p_axis = 'oss' THEN
        UPDATE watch_oss
        SET hit_count = hit_count + 1,
            last_hit_at = now(),
            consecutive_miss = 0,
            updated_at = now()
        WHERE name = p_entity_name;
    ELSIF p_axis = 'category' THEN
        UPDATE watch_categories
        SET hit_count = hit_count + 1,
            last_hit_at = now(),
            consecutive_miss = 0,
            updated_at = now()
        WHERE name = p_entity_name;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- =============================================
-- ミス時にカウンター更新する RPC関数
-- =============================================
CREATE OR REPLACE FUNCTION record_watch_miss(
    p_axis TEXT,
    p_entity_name TEXT
)
RETURNS void AS $$
BEGIN
    IF p_axis = 'company' THEN
        UPDATE watch_companies
        SET consecutive_miss = consecutive_miss + 1, updated_at = now()
        WHERE name = p_entity_name;
    ELSIF p_axis = 'oss' THEN
        UPDATE watch_oss
        SET consecutive_miss = consecutive_miss + 1, updated_at = now()
        WHERE name = p_entity_name;
    ELSIF p_axis = 'category' THEN
        UPDATE watch_categories
        SET consecutive_miss = consecutive_miss + 1, updated_at = now()
        WHERE name = p_entity_name;
    END IF;
END;
$$ LANGUAGE plpgsql;
```

### 1-2. 初期データINSERT文

```sql
-- =============================================
-- 企業ウォッチリスト 初期データ（20社）
-- =============================================
INSERT INTO watch_companies (name, aliases, website, category, priority) VALUES
('OpenAI',          '{"open ai"}',                      'https://openai.com',           'ai_lab',   10),
('Anthropic',       '{"claude"}',                       'https://anthropic.com',        'ai_lab',   10),
('Google DeepMind', '{"deepmind", "google ai"}',        'https://deepmind.google',      'ai_lab',   9),
('Meta AI',         '{"meta", "facebook ai", "fair"}',  'https://ai.meta.com',          'ai_lab',   9),
('Cursor',          '{"cursor ai", "anysphere"}',       'https://cursor.com',           'tooling',  8),
('Vercel',          '{"v0", "next.js"}',                'https://vercel.com',           'tooling',  7),
('Replicate',       '{}',                               'https://replicate.com',        'infra',    6),
('Modal',           '{"modal labs"}',                   'https://modal.com',            'infra',    6),
('Together AI',     '{"together"}',                     'https://together.ai',          'infra',    7),
('Fireworks AI',    '{"fireworks"}',                    'https://fireworks.ai',         'infra',    6),
('Groq',            '{}',                               'https://groq.com',             'infra',    7),
('Mistral',         '{"mistral ai"}',                   'https://mistral.ai',           'ai_lab',   8),
('Cohere',          '{}',                               'https://cohere.com',           'ai_lab',   6),
('LangChain',       '{"langchain ai", "langsmith"}',    'https://langchain.com',        'oss_org',  8),
('LlamaIndex',      '{"llama index"}',                  'https://llamaindex.ai',        'oss_org',  7),
('CrewAI',          '{"crew ai"}',                      'https://crewai.com',           'oss_org',  7),
('Hugging Face',    '{"huggingface", "hf"}',            'https://huggingface.co',       'oss_org',  8),
('Stability AI',    '{"stable diffusion"}',             'https://stability.ai',         'ai_lab',   6),
('Perplexity',      '{"perplexity ai"}',                'https://perplexity.ai',        'ai_lab',   7),
('Windsurf',        '{"codeium"}',                      'https://windsurf.com',         'tooling',  7);

-- =============================================
-- OSSウォッチリスト 初期データ（17リポジトリ）
-- =============================================
INSERT INTO watch_oss (name, github_repo, aliases, category, priority) VALUES
('llama.cpp',               'ggml-org/llama.cpp',               '{"llamacpp"}',             'inference',  9),
('vllm',                    'vllm-project/vllm',                '{"vLLM"}',                 'inference',  9),
('ollama',                  'ollama/ollama',                    '{}',                       'inference',  8),
('langchain',               'langchain-ai/langchain',           '{}',                       'framework',  8),
('llamaindex',              'run-llama/llama_index',            '{"llama_index"}',          'framework',  7),
('crewai',                  'crewAIInc/crewAI',                '{"CrewAI"}',               'agent',      7),
('autogen',                 'microsoft/autogen',                '{"AutoGen"}',              'agent',      7),
('browser-use',             'browser-use/browser-use',          '{}',                       'agent',      7),
('openai-agents-sdk',       'openai/openai-agents-python',      '{"agents sdk"}',           'agent',      8),
('mcp-servers',             'modelcontextprotocol/servers',      '{"MCP servers"}',          'tool',       8),
('dify',                    'langgenius/dify',                  '{}',                       'tool',       7),
('n8n',                     'n8n-io/n8n',                       '{}',                       'tool',       6),
('flowise',                 'FlowiseAI/Flowise',                '{}',                       'tool',       5),
('comfyui',                 'comfyanonymous/ComfyUI',           '{"ComfyUI"}',              'tool',       6),
('stable-diffusion-webui',  'AUTOMATIC1111/stable-diffusion-webui', '{"sd-webui", "a1111"}','tool',       5),
('whisper',                 'openai/whisper',                   '{}',                       'model',      6),
('onnxruntime',             'microsoft/onnxruntime',            '{"ONNX Runtime"}',         'inference',  6);

-- =============================================
-- カテゴリウォッチリスト 初期データ（14カテゴリ）
-- =============================================
INSERT INTO watch_categories (name, description, search_terms, priority) VALUES
('AI IDE',                  'AI-powered integrated development environments',
    '{"cursor", "windsurf", "copilot", "cody", "continue.dev"}',                    8),
('eval framework',          'LLM evaluation and benchmarking frameworks',
    '{"evals", "benchmark", "LMSYS", "arena", "braintrust"}',                       7),
('agent infrastructure',    'Frameworks and platforms for building AI agents',
    '{"agent", "multi-agent", "orchestration", "tool-use"}',                        8),
('browser automation',      'AI-driven browser control and web automation',
    '{"browser-use", "playwright", "puppeteer", "web agent"}',                      7),
('voice agent',             'Voice-based AI agents and speech interfaces',
    '{"voice ai", "speech-to-speech", "realtime api", "conversational ai"}',        6),
('MCP',                     'Model Context Protocol servers and integrations',
    '{"model context protocol", "MCP server", "MCP client", "tool protocol"}',      8),
('vector database',         'Vector stores and embedding search infrastructure',
    '{"pinecone", "weaviate", "qdrant", "chroma", "milvus"}',                       6),
('inference infrastructure','Model serving, quantization, and optimization',
    '{"serving", "quantization", "GGUF", "TensorRT", "triton"}',                   7),
('code generation',         'AI code generation tools and techniques',
    '{"codegen", "code completion", "code review ai", "swe-bench"}',                7),
('AI code review',          'Automated code review using AI',
    '{"code review", "PR review", "static analysis ai", "coderabbit"}',             6),
('RAG pipeline',            'Retrieval-Augmented Generation systems',
    '{"RAG", "retrieval augmented", "chunking", "embedding", "reranking"}',         7),
('multimodal AI',           'Models handling text, image, audio, video together',
    '{"vision language model", "VLM", "text-to-image", "text-to-video"}',           7),
('on-device AI',            'Running AI models locally on consumer hardware',
    '{"on-device", "edge ai", "local llm", "mobile ai", "MLX"}',                   6),
('AI observability',        'Monitoring, tracing, and debugging AI systems',
    '{"langsmith", "langfuse", "phoenix", "tracing", "prompt management"}',         6);
```

---

## 2. クエリ生成Pythonコード（Codeノード用）

### 2-1. メインクエリ生成コード

```python
import json
from datetime import datetime, timedelta

def main(
    companies_json: str,
    oss_json: str,
    categories_json: str
) -> dict:
    """
    3軸ウォッチリストからイベントベース検索クエリを決定的に生成する。
    LLM不使用。Codeノードで完結。

    入力: Supabaseから取得した3テーブルのJSON文字列
    出力: 検索クエリのリスト（Iterationノードに渡す）
    """

    # --- 日付計算 ---
    today = datetime.now()
    weekday = today.weekday()
    if weekday == 0:    # 月曜: 金→月 = 3日分
        days_back = 3
    elif weekday == 2:  # 水曜: 月→水 = 2日分
        days_back = 2
    elif weekday == 4:  # 金曜: 水→金 = 2日分
        days_back = 2
    else:
        days_back = 1
    start_date = today - timedelta(days=days_back)
    date_suffix = f"after:{start_date.strftime('%Y-%m-%d')}"
    date_range = f"{start_date.strftime('%Y-%m-%d')} to {today.strftime('%Y-%m-%d')}"

    # --- 出来事語彙（Event Vocabulary） ---
    EVENT_VOCAB = {
        "company": [
            "launch OR release OR announcing OR changelog",
            "raises OR funding OR acquired OR Series",
            "API OR SDK OR open source OR partnership",
        ],
        "oss": [
            "release OR update OR v2 OR breaking change",
            "changelog OR migration OR new feature",
            "benchmark OR performance OR comparison",
        ],
        "category": [
            "introducing OR launch OR open source OR beta",
            "GA OR now available OR announcing OR preview",
        ],
    }

    # --- クエリ枠数の定義 ---
    QUERY_BUDGET = {
        "company": 8,
        "oss": 6,
        "category": 4,
    }

    # --- パース ---
    try:
        companies = json.loads(companies_json) if companies_json else []
    except (json.JSONDecodeError, TypeError):
        companies = []
    try:
        oss_list = json.loads(oss_json) if oss_json else []
    except (json.JSONDecodeError, TypeError):
        oss_list = []
    try:
        categories = json.loads(categories_json) if categories_json else []
    except (json.JSONDecodeError, TypeError):
        categories = []

    # --- priorityでソートし、枠数分だけ選出 ---
    companies_sorted = sorted(companies, key=lambda x: x.get("priority", 5), reverse=True)
    oss_sorted = sorted(oss_list, key=lambda x: x.get("priority", 5), reverse=True)
    categories_sorted = sorted(categories, key=lambda x: x.get("priority", 5), reverse=True)

    # --- クエリ生成関数 ---
    def build_queries(entities, axis, budget):
        queries = []
        vocab_list = EVENT_VOCAB[axis]
        # ラウンドロビンで語彙を割り当て
        vocab_idx = 0
        slots_used = 0

        for entity in entities:
            if slots_used >= budget:
                break
            name = entity.get("name", "")
            if not name:
                continue

            vocab = vocab_list[vocab_idx % len(vocab_list)]
            vocab_idx += 1

            if axis == "company":
                query = f'"{name}" ({vocab}) {date_suffix}'
            elif axis == "oss":
                query = f'"{name}" ({vocab}) {date_suffix}'
            elif axis == "category":
                # カテゴリは補助検索語も活用
                search_terms = entity.get("search_terms", [])
                if search_terms and len(search_terms) > 0:
                    # 上位2つの補助語を追加
                    extra = " OR ".join(
                        f'"{t}"' for t in search_terms[:2]
                    )
                    query = f'({name} OR {extra}) ({vocab}) {date_suffix}'
                else:
                    query = f'"{name}" ({vocab}) {date_suffix}'
            else:
                query = f'"{name}" ({vocab}) {date_suffix}'

            queries.append({
                "axis": axis,
                "entity_name": name,
                "query": query,
                "priority": entity.get("priority", 5),
            })
            slots_used += 1

        return queries

    # --- 各軸のクエリ生成 ---
    company_queries = build_queries(companies_sorted, "company", QUERY_BUDGET["company"])
    oss_queries = build_queries(oss_sorted, "oss", QUERY_BUDGET["oss"])
    category_queries = build_queries(categories_sorted, "category", QUERY_BUDGET["category"])

    # --- 全クエリを統合 ---
    all_queries = company_queries + oss_queries + category_queries

    # Iterationノードに渡すためのリスト形式
    query_list_for_iteration = json.dumps(all_queries, ensure_ascii=False)

    # デバッグ用サマリ
    summary = (
        f"Generated {len(all_queries)} queries: "
        f"{len(company_queries)} companies, "
        f"{len(oss_queries)} OSS, "
        f"{len(category_queries)} categories. "
        f"Date range: {date_range}"
    )

    return {
        "query_list": query_list_for_iteration,
        "query_count": len(all_queries),
        "date_range": date_range,
        "date_suffix": date_suffix,
        "start_date_iso": start_date.strftime("%Y-%m-%d"),
        "today_iso": today.strftime("%Y-%m-%d"),
        "summary": summary,
    }
```

### 2-2. 検索結果パース・ヒット記録コード（Iteration内Codeノード）

```python
import json

def main(
    search_result: str,
    query_item_json: str
) -> dict:
    """
    Tavily検索結果をパースし、ヒット/ミス判定とSupabase更新用データを生成する。
    Iterationノード内で各クエリの結果に対して実行する。
    """

    try:
        query_item = json.loads(query_item_json)
    except (json.JSONDecodeError, TypeError):
        query_item = {}

    axis = query_item.get("axis", "unknown")
    entity_name = query_item.get("entity_name", "unknown")
    query_used = query_item.get("query", "")

    # Tavily結果パース
    results = []
    try:
        raw = json.loads(search_result) if isinstance(search_result, str) else search_result
        if isinstance(raw, dict):
            results = raw.get("results", [])
        elif isinstance(raw, list):
            results = raw
    except (json.JSONDecodeError, TypeError):
        results = []

    result_count = len(results)
    is_hit = result_count > 0

    # 上位5件を構造化
    top_results = []
    for r in results[:5]:
        top_results.append({
            "title": r.get("title", ""),
            "url": r.get("url", ""),
            "snippet": r.get("content", "")[:200] if r.get("content") else "",
            "score": r.get("score", 0),
        })

    # Supabase RPC呼び出し用のペイロード
    if is_hit:
        rpc_payload = json.dumps({
            "p_axis": axis,
            "p_entity_name": entity_name,
            "p_query": query_used,
            "p_result_count": result_count,
            "p_top_results": top_results,
        }, ensure_ascii=False)
        rpc_function = "record_watch_hit"
    else:
        rpc_payload = json.dumps({
            "p_axis": axis,
            "p_entity_name": entity_name,
        }, ensure_ascii=False)
        rpc_function = "record_watch_miss"

    # レポート用の構造化結果
    structured_result = json.dumps({
        "axis": axis,
        "entity_name": entity_name,
        "is_hit": is_hit,
        "result_count": result_count,
        "top_results": top_results,
    }, ensure_ascii=False)

    return {
        "structured_result": structured_result,
        "is_hit": "true" if is_hit else "false",
        "rpc_function": rpc_function,
        "rpc_payload": rpc_payload,
        "result_count": result_count,
    }
```

### 2-3. 全結果統合・レポート前処理コード

```python
import json

def main(all_results_json: str) -> dict:
    """
    Iterationの全結果を統合し、軸別に分類する。
    LLMレポート生成ノードへの入力を準備する。
    """

    try:
        all_results = json.loads(all_results_json) if isinstance(all_results_json, str) else []
        if isinstance(all_results, str):
            all_results = json.loads(all_results)
    except (json.JSONDecodeError, TypeError):
        all_results = []

    # 軸別に分類
    by_axis = {"company": [], "oss": [], "category": []}
    hits_only = {"company": [], "oss": [], "category": []}

    for item_str in all_results:
        try:
            item = json.loads(item_str) if isinstance(item_str, str) else item_str
        except (json.JSONDecodeError, TypeError):
            continue

        axis = item.get("axis", "unknown")
        if axis in by_axis:
            by_axis[axis].append(item)
            if item.get("is_hit"):
                hits_only[axis].append(item)

    # ヒット率の計算
    stats = {}
    for axis in ["company", "oss", "category"]:
        total = len(by_axis[axis])
        hits = len(hits_only[axis])
        stats[axis] = {
            "total_queries": total,
            "hits": hits,
            "hit_rate": f"{(hits/total*100):.0f}%" if total > 0 else "N/A",
        }

    # レポート用テキスト生成（軸別）
    def format_axis_report(axis_name, items):
        lines = []
        for item in items:
            entity = item.get("entity_name", "?")
            count = item.get("result_count", 0)
            top = item.get("top_results", [])
            lines.append(f"### {entity} ({count} results)")
            for r in top[:3]:
                title = r.get("title", "No title")
                url = r.get("url", "")
                snippet = r.get("snippet", "")
                lines.append(f"- [{title}]({url})")
                if snippet:
                    lines.append(f"  > {snippet[:150]}")
            lines.append("")
        return "\n".join(lines) if lines else f"No hits for {axis_name} axis."

    company_report = format_axis_report("Company", hits_only["company"])
    oss_report = format_axis_report("OSS", hits_only["oss"])
    category_report = format_axis_report("Category", hits_only["category"])

    return {
        "company_report": company_report,
        "oss_report": oss_report,
        "category_report": category_report,
        "stats_json": json.dumps(stats, ensure_ascii=False),
        "total_hits": sum(len(v) for v in hits_only.values()),
        "total_queries": sum(len(v) for v in by_axis.values()),
    }
```

---

## 3. Difyノード構成

### 3-1. ノードフロー全体図

```
Start (入力なし / Cron起動)
  │
  ▼
[Code] ① 日付計算ノード ─── 日付パラメータのみ生成
  │
  ├──────────────────────┬──────────────────────┐
  ▼                      ▼                      ▼
[HTTP] ②             [HTTP] ③             [HTTP] ④
Supabase:             Supabase:             Supabase:
watch_companies       watch_oss             watch_categories
?status=eq.active     ?status=eq.active     ?status=eq.active
&order=priority.desc  &order=priority.desc  &order=priority.desc
  │                      │                      │
  └──────────┬───────────┴──────────────────────┘
             ▼
[Code] ⑤ クエリ生成ノード
  │    ・3軸データ受取
  │    ・イベント語彙と組合せ
  │    ・18クエリ生成
  │    → query_list (JSON配列)
  ▼
[Iteration] ⑥ メイン検索ループ (18回)
  │
  │  ┌─────────────────────────────────────┐
  │  │ [Code] ⑥-a 現在のクエリ項目抽出     │
  │  │          │                           │
  │  │          ▼                           │
  │  │ [Tool] ⑥-b Tavily Search            │
  │  │    query = ⑥-aの出力.query           │
  │  │    search_depth = basic              │
  │  │    max_results = 5                   │
  │  │          │                           │
  │  │          ▼                           │
  │  │ [Code] ⑥-c 結果パース・構造化       │
  │  │          │                           │
  │  │          ▼                           │
  │  │ [HTTP] ⑥-d Supabase RPC             │
  │  │    record_watch_hit / miss           │
  │  └─────────────────────────────────────┘
  │
  ▼
[Variable Aggregator] ⑦ Iteration出力集約
  │
  ▼
[Code] ⑧ 全結果統合・軸別分類
  │    → company_report, oss_report, category_report
  │
  ▼
[LLM] ⑨ インテリジェンスレポート生成
  │    ・3軸の検索結果を英語で受け取り
  │    ・日本語のレポートとして出力
  │    ・「何が起きたか」「なぜ重要か」「次に何をすべきか」
  │
  ▼
[Code] ⑩ Slack Block Kit フォーマット変換
  │
  ├──────────────────┐
  ▼                  ▼
[HTTP] ⑪          [HTTP] ⑫
Slack送信          Supabase:
                   deliveries保存
  │                  │
  └────────┬─────────┘
           ▼
[HTTP] ⑬ Supabase: auto_archive_stale_watches RPC呼び出し
  │
  ▼
End
```

### 3-2. 各ノードの詳細設定

#### ① 日付計算ノード（Code）

- **入力**: なし
- **出力**: `date_suffix`, `start_date_iso`, `today_iso`, `date_range`
- **コード**: 上記2-1の日付計算部分のみ（ウォッチリスト取得前なので軽量に）

```python
from datetime import datetime, timedelta

def main() -> dict:
    today = datetime.now()
    weekday = today.weekday()
    if weekday == 0:
        days_back = 3
    elif weekday == 2:
        days_back = 2
    elif weekday == 4:
        days_back = 2
    else:
        days_back = 1
    start_date = today - timedelta(days=days_back)
    return {
        "date_suffix": f"after:{start_date.strftime('%Y-%m-%d')}",
        "start_date_iso": start_date.strftime("%Y-%m-%d"),
        "today_iso": today.strftime("%Y-%m-%d"),
        "date_range": f"{start_date.strftime('%Y-%m-%d')} to {today.strftime('%Y-%m-%d')}",
    }
```

#### ②③④ Supabase取得ノード（HTTP Request x 3、並列実行）

3つのHTTP Requestノードを ①Code の直後に並列配置する。

**② watch_companies取得**
- Method: `GET`
- URL: `{{#env.SUPABASE_URL#}}/rest/v1/watch_companies?status=eq.active&order=priority.desc`
- Headers:
  ```
  apikey:{{#env.SUPABASE_ANON_KEY#}}
  Authorization:Bearer {{#env.SUPABASE_ANON_KEY#}}
  Content-Type:application/json
  ```

**③ watch_oss取得**
- Method: `GET`
- URL: `{{#env.SUPABASE_URL#}}/rest/v1/watch_oss?status=eq.active&order=priority.desc`
- Headers: 同上

**④ watch_categories取得**
- Method: `GET`
- URL: `{{#env.SUPABASE_URL#}}/rest/v1/watch_categories?status=eq.active&order=priority.desc`
- Headers: 同上

#### ⑤ クエリ生成ノード（Code）

- **入力**:
  - `companies_json`: ②のbody (string)
  - `oss_json`: ③のbody (string)
  - `categories_json`: ④のbody (string)
- **出力**: `query_list` (JSON文字列), `query_count`, `summary` 等
- **コード**: 上記2-1のメインクエリ生成コード

#### ⑥ Iteration（メイン検索ループ）

- **Input**: ⑤の`query_list`をJSONパースして配列化
- **並列数**: 1（Tavily APIレートリミット考慮）
- **最大反復**: 18

**⑥-a 現在のクエリ項目抽出（Code）**
```python
import json

def main(current_item: str) -> dict:
    try:
        item = json.loads(current_item) if isinstance(current_item, str) else current_item
    except (json.JSONDecodeError, TypeError):
        item = {}
    return {
        "query": item.get("query", ""),
        "axis": item.get("axis", ""),
        "entity_name": item.get("entity_name", ""),
        "query_item_json": json.dumps(item, ensure_ascii=False),
    }
```

**⑥-b Tavily Search（Tool）**
- query: `{{#⑥-a.query#}}`
- search_depth: `basic`
- max_results: `5`
- include_answer: `false`

**⑥-c 結果パース（Code）**
- コード: 上記2-2

**⑥-d Supabase RPC呼び出し（HTTP Request）**
- Method: `POST`
- URL: `{{#env.SUPABASE_URL#}}/rest/v1/rpc/{{#⑥-c.rpc_function#}}`
- Body: `{{#⑥-c.rpc_payload#}}`

#### ⑨ LLMレポート生成ノード

プロンプト:

```
You are a senior technology intelligence analyst. Your task is to synthesize search results from three monitoring axes into a concise, actionable Japanese report.

## Input Data

### Company Axis Results
{{company_report}}

### OSS Axis Results
{{oss_report}}

### Category Axis Results
{{category_report}}

### Stats
{{stats_json}}

## Output Requirements

以下の形式で日本語レポートを生成してください:

### 1. 速報（トップ3）
最も重要度の高いニュースを3件、以下の形式で:
- **[企業/OSS名] 何が起きたか** — なぜ重要か（1文）
  - ソースURL

### 2. 企業動向
検索でヒットした企業の動きをまとめる。ヒットしなかった企業は「動きなし」と明記。

### 3. OSS動向
リリースやアップデートのあったOSSをまとめる。バージョン番号があれば明記。

### 4. カテゴリ動向
注目カテゴリに関する新しい動きをまとめる。

### 5. アクション提案
開発者・エンジニアとして「今週やるべきこと」を1-2個提案。

## ルール
- ソースURLは必ず含める
- 推測は明示する（「〜の可能性がある」）
- 英語ソースの内容は日本語に翻訳して記述
- 検索結果にないことは書かない
```

---

## 4. 設計上の重要ポイント

### 4-1. なぜ英語オンリーにするのか

| 理由 | 詳細 |
|------|------|
| 速報性 | 新製品発表は英語が最速。日本語記事は1-3日遅れ |
| 網羅性 | GitHub release、公式blog、Hacker Newsは英語のみ |
| クエリ品質 | 英語の出来事語彙（launch, GA, announcing）は検索精度が高い |
| 翻訳はLLMの仕事 | 英語で取得 → LLMが日本語レポート化。これが正しい分業 |

### 4-2. 優先度制御の仕組み

- 各エンティティに `priority` (1-10) を持たせる
- クエリ枠（企業8, OSS6, カテゴリ4 = 合計18）に対して、priority降順で枠を割り当て
- ヒットすると `consecutive_miss` がリセット、ミスが続くと自動アーカイブ
- `watch_discovery_queue` で新エンティティの自動発見も可能

### 4-3. 従来設計からの移行

1. 旧 `watchlist` テーブルのデータを `watch_companies` / `watch_oss` に振り分け
2. 旧 `FIXED_CATEGORIES` のハードコード定義は不要に（Supabase `watch_categories` で管理）
3. 日本語クエリ（`query_ja`）は全て廃止
4. LLMによるカテゴリ生成・変動枠検知は廃止（決定的クエリ生成に置換）

### 4-4. クエリ枠数のチューニング指針

| 条件 | 推奨調整 |
|------|---------|
| Tavily APIクレジットが潤沢 | 企業12 + OSS8 + カテゴリ6 = 26 |
| 最小限で運用したい | 企業5 + OSS4 + カテゴリ3 = 12 |
| 特定軸を強化したい | その軸のbudgetを増やし他を減らす |
| 新しいエンティティが多い | discovery_queueの承認頻度を上げる |
