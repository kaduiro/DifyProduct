# AInews TechIntelligence v3.1 改善設計書
# 収集と評価の分離 + 重複統合と追跡履歴の強化

---

## 問題の整理

現行 v3.0 の Phase 2（`code_credibility_dedup_diff`）は以下を1つの Code ノードに詰め込んでいる:

1. ドメインベースの信頼度スコアリング（内容を見ていない）
2. タイトル先頭30文字での重複判定（不正確）
3. 簡易的な差分検知（追跡履歴なし）

**指摘1** が求めているのは「広く拾い、そのあとで5軸評価で絞る」こと。
**指摘2** が求めているのは「記事ではなくエンティティ（製品・技術）を追跡する」こと。

---

## 改善後の全体アーキテクチャ

```
Phase 1: 収集（既存のまま）
  Tavily検索 + GitHub API → 生データ

Phase 2: 正規化（新規 Code ノード）
  生データ → 共通フォーマットに変換
  何も捨てない。URLハッシュ生成のみ

Phase 3: 5軸評価（新規 LLM ノード / Gemini）
  各記事を5軸でスコアリング
  バッチ処理（1回のLLM呼び出しで全記事評価）

Phase 4: エンティティ抽出・追跡更新（新規 Code + LLM）
  記事からエンティティ（製品/技術/企業）を抽出
  Supabase の entities テーブルと照合・更新
  ステータス変化を検出

Phase 5: 差分レポート生成（新規 Code ノード）
  エンティティベースの差分検知
  前回からの変化を構造化

Phase 6: 実務インパクト分析 + Slack配信（既存改修）
```

---

## Difyノード構成図

```
Start
  │
  ▼
[Code] init_date_range ─────────────────────────────────────
  │  日付範囲・配信ID生成
  │
  ▼
[Iteration] tavily_search_loop ─────────────────────────────
  │  既存の Tavily 検索ループ（変更なし）
  │
  ▼
[Code] normalize_raw_data ──────────────────────────────────
  │  Phase 2: 正規化（共通フォーマット変換）
  │  入力: iteration出力（生データ）
  │  出力: normalized_articles（JSON文字列）
  │
  ▼
[LLM] evaluate_5axes ───────────────────────────────────────
  │  Phase 3: Gemini による5軸評価
  │  入力: normalized_articles
  │  出力: evaluated_articles（JSON文字列）
  │
  ▼
[Code] filter_by_score ─────────────────────────────────────
  │  スコア3以下除外、4-6「注目」、7+「重要」にラベル付け
  │  入力: evaluated_articles
  │  出力: filtered_articles, filter_stats
  │
  ▼
[HTTP] fetch_existing_entities ─────────────────────────────
  │  Supabase から既存エンティティ一覧を取得
  │
  ▼
[LLM] extract_and_match_entities ───────────────────────────
  │  Phase 4: 記事からエンティティ抽出 + 既存エンティティとの照合
  │  入力: filtered_articles, existing_entities
  │  出力: entity_updates（JSON文字列）
  │
  ▼
[Code] build_entity_updates ────────────────────────────────
  │  エンティティテーブル更新データの構築
  │  ステータス変化の検出
  │  差分レポートの生成
  │  入力: entity_updates, existing_entities
  │  出力: upsert_payload, diff_report, status_changes
  │
  ▼
[HTTP] upsert_entities ─────────────────────────────────────
  │  Supabase entities テーブルへ UPSERT
  │
  ▼
[HTTP] save_article_entity_links ───────────────────────────
  │  Supabase article_entity_links テーブルへ INSERT
  │
  ▼
[LLM] impact_analysis ─────────────────────────────────────
  │  実務インパクト分析（既存 llm_impact を改修）
  │  入力: filtered_articles, diff_report, status_changes
  │
  ▼
[Code] format_slack_blocks ─────────────────────────────────
  │  Slack Block Kit 整形（既存改修）
  │
  ▼
[HTTP] send_to_slack ───────────────────────────────────────
  │
  ▼
End
```

### エッジ定義

```yaml
edges:
  - source: start → target: init_date_range
  - source: init_date_range → target: tavily_search_loop
  - source: tavily_search_loop → target: normalize_raw_data
  - source: normalize_raw_data → target: evaluate_5axes
  - source: evaluate_5axes → target: filter_by_score
  - source: filter_by_score → target: fetch_existing_entities
  - source: fetch_existing_entities → target: extract_and_match_entities
  - source: extract_and_match_entities → target: build_entity_updates
  - source: build_entity_updates → target: upsert_entities
  - source: upsert_entities → target: save_article_entity_links
  - source: save_article_entity_links → target: impact_analysis
  - source: impact_analysis → target: format_slack_blocks
  - source: format_slack_blocks → target: send_to_slack
  - source: send_to_slack → target: end
```

---

## 1. Supabase スキーマ

```sql
-- ============================================================
-- エンティティテーブル（記事ではなく「もの」を追跡する）
-- 製品・技術・企業・OSSプロジェクトなど
-- ============================================================
CREATE TABLE entities (
    id              UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    name            TEXT NOT NULL,
    name_normalized TEXT NOT NULL,           -- 小文字化・空白除去した正規化名
    type            TEXT NOT NULL CHECK (type IN (
                        'product',           -- 製品・サービス（GPT-5, Claude Code 等）
                        'oss',               -- OSSプロジェクト（LangChain, Dify 等）
                        'company',           -- 企業（OpenAI, Anthropic 等）
                        'technology',        -- 技術概念（RAG, MCP, LoRA 等）
                        'standard',          -- 規格・規制（EU AI Act 等）
                        'model'              -- AIモデル（GPT-4o, Gemini 2.5 等）
                    )),
    first_seen_date DATE NOT NULL DEFAULT CURRENT_DATE,
    last_seen_date  DATE NOT NULL DEFAULT CURRENT_DATE,
    appearance_count INTEGER NOT NULL DEFAULT 1,
    status_history  JSONB NOT NULL DEFAULT '[]'::JSONB,
    -- status_history の各要素:
    -- {
    --   "date": "2026-03-20",
    --   "status": "emerging",
    --   "source_url": "https://...",
    --   "summary": "初報。ベータ版として公開"
    -- }
    current_status  TEXT NOT NULL DEFAULT 'emerging' CHECK (current_status IN (
                        'emerging',          -- 初出・噂段階
                        'announced',         -- 公式発表済み
                        'beta',              -- ベータ・プレビュー
                        'active',            -- GA・本番利用可能
                        'mature',            -- 成熟・広く普及
                        'declining'          -- 衰退・非推奨化
                    )),
    related_entities JSONB NOT NULL DEFAULT '[]'::JSONB,
    -- related_entities の各要素:
    -- {"entity_id": "uuid", "relationship": "competitor|dependency|parent|successor"}
    overall_score_avg NUMERIC(3,1) DEFAULT 0,  -- 関連記事の平均overall_score
    tags            TEXT[] DEFAULT '{}',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_entity_name_type UNIQUE (name_normalized, type)
);

CREATE INDEX idx_entities_name ON entities(name_normalized);
CREATE INDEX idx_entities_type ON entities(type);
CREATE INDEX idx_entities_status ON entities(current_status);
CREATE INDEX idx_entities_last_seen ON entities(last_seen_date DESC);
CREATE INDEX idx_entities_score ON entities(overall_score_avg DESC);

-- ============================================================
-- 記事テーブル（正規化済み記事の保存）
-- ============================================================
CREATE TABLE articles (
    id              UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    article_hash    TEXT NOT NULL UNIQUE,     -- SHA256(正規化URL)の先頭16文字
    url             TEXT NOT NULL,
    title           TEXT NOT NULL,
    summary         TEXT,
    source_domain   TEXT,
    published_date  DATE,
    -- 5軸評価結果
    is_primary_source   BOOLEAN DEFAULT FALSE,
    has_real_product    BOOLEAN DEFAULT FALSE,
    developer_relevant  BOOLEAN DEFAULT FALSE,
    can_try_now         BOOLEAN DEFAULT FALSE,
    not_just_hype       BOOLEAN DEFAULT FALSE,
    overall_score       INTEGER DEFAULT 0 CHECK (overall_score BETWEEN 0 AND 10),
    importance_label    TEXT DEFAULT 'normal' CHECK (importance_label IN (
                            'excluded',      -- スコア3以下
                            'normal',        -- スコア4-6
                            'important'      -- スコア7以上
                        )),
    delivery_id     TEXT,                     -- どの配信で取得したか
    raw_content     TEXT,                     -- 元の生テキスト（参照用）
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_articles_hash ON articles(article_hash);
CREATE INDEX idx_articles_delivery ON articles(delivery_id);
CREATE INDEX idx_articles_score ON articles(overall_score DESC);
CREATE INDEX idx_articles_date ON articles(published_date DESC);

-- ============================================================
-- 記事→エンティティの紐付け
-- ============================================================
CREATE TABLE article_entity_links (
    id              UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    article_hash    TEXT NOT NULL REFERENCES articles(article_hash),
    entity_id       UUID NOT NULL REFERENCES entities(id),
    relationship_type TEXT NOT NULL CHECK (relationship_type IN (
                        'about',             -- この記事はこのエンティティについて書かれている
                        'mentions',          -- この記事でこのエンティティが言及されている
                        'announces',         -- この記事はこのエンティティの発表記事
                        'reviews',           -- この記事はこのエンティティのレビュー
                        'compares'           -- この記事で他エンティティと比較されている
                    )),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_article_entity UNIQUE (article_hash, entity_id, relationship_type)
);

CREATE INDEX idx_ael_article ON article_entity_links(article_hash);
CREATE INDEX idx_ael_entity ON article_entity_links(entity_id);

-- ============================================================
-- 配信履歴（既存 change_detection 設計との統合）
-- ============================================================
CREATE TABLE delivery_history (
    id              UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    delivery_id     TEXT NOT NULL UNIQUE,
    delivery_date   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    article_count   INTEGER NOT NULL DEFAULT 0,
    new_entity_count INTEGER NOT NULL DEFAULT 0,
    updated_entity_count INTEGER NOT NULL DEFAULT 0,
    status_changes  JSONB DEFAULT '[]'::JSONB,
    -- status_changes: [{"entity_name": "X", "from": "beta", "to": "active"}]
    filter_stats    JSONB DEFAULT '{}'::JSONB,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_delivery_date ON delivery_history(delivery_date DESC);

-- ============================================================
-- ビュー: エンティティのダッシュボード用
-- ============================================================
CREATE VIEW entity_dashboard AS
SELECT
    e.id,
    e.name,
    e.type,
    e.current_status,
    e.first_seen_date,
    e.last_seen_date,
    e.appearance_count,
    e.overall_score_avg,
    (CURRENT_DATE - e.last_seen_date) AS days_since_last_seen,
    (SELECT COUNT(*) FROM article_entity_links ael WHERE ael.entity_id = e.id) AS total_articles,
    e.tags
FROM entities e
ORDER BY e.last_seen_date DESC, e.overall_score_avg DESC;

-- ============================================================
-- 定期クリーンアップ（古い記事データを削除、エンティティは残す）
-- ============================================================
-- 毎週日曜に実行
-- DELETE FROM articles WHERE created_at < NOW() - INTERVAL '90 days';
-- エンティティは削除しない（追跡履歴として価値がある）
```

---

## 2. 評価LLMプロンプト（Gemini向け）

### ノード設定

```yaml
- id: evaluate_5axes
  data:
    title: 5軸評価（Gemini）
    type: llm
    model:
      provider: google
      name: gemini-2.0-flash
      mode: chat
      completion_params:
        temperature: 0.1
        max_tokens: 16000
```

### プロンプト

```yaml
prompt_template:
  - role: system
    text: |
      あなたはAI/IT技術ニュースの品質評価エキスパートです。
      入力された記事リスト（JSON配列）の各記事を、以下の5つの軸で評価してください。

      ## 評価の5軸

      ### 1. is_primary_source（一次情報か）
      - true: 公式ブログ、リリースノート、論文、プレスリリース、公式GitHub
      - false: 二次報道、まとめ記事、噂・リーク情報、SNS投稿
      判定のヒント:
      - URLに blog.openai.com, anthropic.com, arxiv.org, github.com/公式org などが含まれる → true
      - 「〜によると」「〜が報じた」という間接引用が主体 → false
      - 公式ドキュメントやChangelog → true

      ### 2. has_real_product（実体のある製品か）
      - true: デモ、リポジトリ、API、ダウンロード可能なもの、実際に動くプロダクトが存在
      - false: コンセプト発表のみ、ビジョンペーパー、「将来的に〜」のみ
      判定のヒント:
      - GitHubリポジトリURLがある → true
      - 「APIが公開された」「pip install で導入可能」 → true
      - 「開発中」「2027年リリース予定」のみ → false
      - 研究論文でもコードが公開されていれば → true

      ### 3. developer_relevant（開発者に関係あるか）
      - true: API、SDK、フレームワーク、ツール、モデル、開発プラクティスに関する情報
      - false: 経営人事、資金調達のみ、一般消費者向け機能のみ、政治的議論のみ
      判定のヒント:
      - コードを書く人が影響を受ける → true
      - 技術選定に影響する → true
      - CEOの交代ニュースだが技術戦略に変化なし → false
      - 新しい価格プランだがAPI利用者に影響 → true

      ### 4. can_try_now（今試せるか）
      - true: GA、パブリックベータ、Playground、無料枠あり、OSS公開済み
      - false: ウェイトリスト、企業限定ベータ、発表のみ、未公開
      判定のヒント:
      - 「本日より一般公開」「パブリックプレビュー開始」 → true
      - 「申請が必要」「招待制」 → false（ただし申請すれば誰でも可能なら true）
      - OSSでgit clone可能 → true
      - 「近日公開予定」 → false

      ### 5. not_just_hype（一過性の宣伝でないか）
      - true: 技術的裏付けがある、ベンチマーク結果がある、実際のユースケースがある
      - false: バズワードだけ、具体性がない、誇大な主張のみ
      判定のヒント:
      - 具体的な数値（精度○%向上、レイテンシ○ms）がある → true
      - 「革命的」「画期的」だけで具体性なし → false
      - 実際のユーザー事例がある → true
      - PR記事/スポンサード記事の気配がある → false

      ### 6. overall_score（総合スコア 1-10）
      上記5軸の結果を総合し、開発者にとっての価値を1-10で評価。
      - 9-10: 全軸true + 業界インパクト大（主要モデルGA、重要なセキュリティ修正等）
      - 7-8: 4軸以上true + 実用的価値が高い
      - 5-6: 3軸true または 部分的に価値あり
      - 3-4: 1-2軸true 一般的なニュース
      - 1-2: 全軸false に近い、ノイズ

      ## 入力データ
      {{#normalize_raw_data.normalized_articles#}}

      ## 出力形式
      必ず以下のJSON配列で出力してください。```json で囲んでください。
      入力の各記事に対して1つの評価オブジェクトを返してください。
      記事の順序を保持してください。

      ```json
      [
        {
          "index": 0,
          "title": "元のタイトル",
          "url": "元のURL",
          "is_primary_source": true,
          "has_real_product": true,
          "developer_relevant": true,
          "can_try_now": false,
          "not_just_hype": true,
          "overall_score": 7,
          "evaluation_reason": "公式ブログでの発表。APIが公開済みだがベータ段階のため can_try_now は微妙。ベンチマーク結果あり。"
        }
      ]
      ```

      ## 重要な制約
      - 全記事を評価してください。スキップしないでください。
      - evaluation_reason は日本語で1-2文。判断の根拠を簡潔に。
      - 迷った場合は false 寄り（偽陽性より偽陰性を選ぶ）。
      - URL のドメインだけでなく、タイトルと要約の内容も考慮して判断してください。

  - role: user
    text: |
      上記の記事リストを5軸で評価してください。
```

---

## 3. Python コード（各 Code ノード用）

### 3-1. Phase 2: 正規化コード（normalize_raw_data）

```yaml
- id: normalize_raw_data
  data:
    title: 収集データ正規化
    type: code
    code_language: python3
    variables:
      - value_selector: [tavily_search_loop, output]
        variable: raw_findings
    outputs:
      normalized_articles:
        type: string
      total_raw_count:
        type: number
```

```python
def main(raw_findings: list) -> dict:
    """
    Phase 2: 収集結果を共通フォーマットに正規化する。
    この段階では何も捨てない。フォーマット統一とURLハッシュ生成のみ。
    """
    import json
    import re
    import hashlib

    # ========================================
    # URL正規化
    # ========================================
    TRACKING_PARAMS = {
        'utm_source', 'utm_medium', 'utm_campaign',
        'utm_term', 'utm_content', 'ref', 'source',
        'fbclid', 'gclid', 'mc_cid', 'mc_eid'
    }

    def normalize_url(url: str) -> str:
        if not url:
            return ""
        try:
            # プロトコル除去→https統一
            if '://' in url:
                _, rest = url.split('://', 1)
            else:
                rest = url
            # フラグメント除去
            rest = rest.split('#')[0]
            # ホスト と パス+クエリ を分離
            if '/' in rest:
                host, path_query = rest.split('/', 1)
            else:
                host = rest
                path_query = ''
            # www. 除去
            host = host.lower()
            if host.startswith('www.'):
                host = host[4:]
            # クエリパラメータからトラッキング系を除去
            if '?' in path_query:
                path, query = path_query.split('?', 1)
                params = []
                for param in query.split('&'):
                    key = param.split('=')[0].lower()
                    if key not in TRACKING_PARAMS:
                        params.append(param)
                clean_query = '&'.join(params)
                path_query = f"{path}?{clean_query}" if clean_query else path
            else:
                path = path_query
            # 末尾スラッシュ統一
            path_query = path_query.rstrip('/')
            return f"https://{host}/{path_query}" if path_query else f"https://{host}"
        except Exception:
            return url

    def generate_hash(url: str) -> str:
        normalized = normalize_url(url)
        return hashlib.sha256(normalized.encode('utf-8')).hexdigest()[:16]

    def extract_domain(url: str) -> str:
        try:
            if '://' in url:
                _, rest = url.split('://', 1)
            else:
                rest = url
            host = rest.split('/')[0].split('?')[0]
            if host.startswith('www.'):
                host = host[4:]
            return host.lower()
        except Exception:
            return ""

    # ========================================
    # URL抽出パターン
    # ========================================
    url_pattern = re.compile(r'https?://[^\s\)\]\}\"\'<>]+')

    # ========================================
    # メイン処理: 各findingを正規化
    # ========================================
    articles = []
    seen_hashes = set()

    for finding in raw_findings:
        if not finding or not isinstance(finding, str):
            continue

        # テキストからURLを抽出
        urls = url_pattern.findall(finding)
        urls = [u.rstrip('.,;:)）]】') for u in urls]

        # タイトル推定（最初の行または箇条書きの最初の部分）
        lines = finding.strip().split('\n')
        title = lines[0].strip()
        # Markdown記号除去
        title = re.sub(r'^[#\-\*\d\.]+\s*', '', title)
        title = title[:200]

        # 要約（全文の先頭500文字）
        summary = finding[:500]

        if urls:
            # URL がある場合、最も信頼できそうなURLを主URLとする
            primary_url = urls[0]
            article_hash = generate_hash(primary_url)

            # 重複除去（同一URLは1つだけ）
            if article_hash in seen_hashes:
                continue
            seen_hashes.add(article_hash)

            articles.append({
                "index": len(articles),
                "article_hash": article_hash,
                "url": primary_url,
                "all_urls": urls[:5],
                "title": title,
                "summary": summary,
                "source_domain": extract_domain(primary_url),
                "raw_text": finding
            })
        else:
            # URLがない場合もタイトルハッシュで管理
            article_hash = hashlib.sha256(
                title.encode('utf-8')
            ).hexdigest()[:16]

            if article_hash in seen_hashes:
                continue
            seen_hashes.add(article_hash)

            articles.append({
                "index": len(articles),
                "article_hash": article_hash,
                "url": "",
                "all_urls": [],
                "title": title,
                "summary": summary,
                "source_domain": "",
                "raw_text": finding
            })

    return {
        "normalized_articles": json.dumps(articles, ensure_ascii=False),
        "total_raw_count": len(articles)
    }
```

---

### 3-2. スコアフィルタリング（filter_by_score）

```yaml
- id: filter_by_score
  data:
    title: スコアフィルタリング
    type: code
    code_language: python3
    variables:
      - value_selector: [evaluate_5axes, text]
        variable: evaluated_text
      - value_selector: [normalize_raw_data, normalized_articles]
        variable: normalized_articles
    outputs:
      filtered_articles:
        type: string
      filter_stats:
        type: string
      excluded_count:
        type: number
```

```python
def main(evaluated_text: str, normalized_articles: str) -> dict:
    """
    LLMの5軸評価結果を解析し、スコアに基づいてフィルタリングする。
    - overall_score 3以下: excluded（除外）
    - overall_score 4-6: normal（注目）
    - overall_score 7以上: important（重要）
    """
    import json
    import re

    # ========================================
    # LLM出力からJSONを抽出
    # ========================================
    def parse_json_from_llm(text):
        match = re.search(r'```(?:json)?\s*(\[[\s\S]*?\])\s*```', text)
        if match:
            return json.loads(match.group(1))
        match = re.search(r'\[[\s\S]*\]', text)
        if match:
            return json.loads(match.group(0))
        return []

    # 元の正規化データを辞書化（index → 記事）
    try:
        orig_articles = json.loads(normalized_articles)
        orig_map = {a["index"]: a for a in orig_articles}
    except Exception:
        orig_map = {}

    # LLM評価結果をパース
    try:
        evaluations = parse_json_from_llm(evaluated_text)
    except Exception:
        evaluations = []

    # ========================================
    # フィルタリング
    # ========================================
    filtered = []
    excluded = []
    stats = {
        "total_input": len(evaluations),
        "important": 0,    # 7+
        "normal": 0,       # 4-6
        "excluded": 0,     # 3以下
        "axes_summary": {
            "is_primary_source": 0,
            "has_real_product": 0,
            "developer_relevant": 0,
            "can_try_now": 0,
            "not_just_hype": 0
        }
    }

    for ev in evaluations:
        if not isinstance(ev, dict):
            continue

        score = ev.get("overall_score", 0)
        idx = ev.get("index", -1)

        # 元の記事データとマージ
        orig = orig_map.get(idx, {})
        merged = {**orig, **ev}

        # 5軸の集計
        for axis in ["is_primary_source", "has_real_product",
                      "developer_relevant", "can_try_now", "not_just_hype"]:
            if ev.get(axis, False):
                stats["axes_summary"][axis] += 1

        # スコアによる分類
        if score <= 3:
            merged["importance_label"] = "excluded"
            excluded.append(merged)
            stats["excluded"] += 1
        elif score <= 6:
            merged["importance_label"] = "normal"
            filtered.append(merged)
            stats["normal"] += 1
        else:
            merged["importance_label"] = "important"
            filtered.append(merged)
            stats["important"] += 1

    # スコア順にソート（重要→注目の順）
    filtered.sort(key=lambda x: x.get("overall_score", 0), reverse=True)

    return {
        "filtered_articles": json.dumps(filtered, ensure_ascii=False),
        "filter_stats": json.dumps(stats, ensure_ascii=False),
        "excluded_count": stats["excluded"]
    }
```

---

### 3-3. エンティティ抽出・照合 LLM プロンプト（extract_and_match_entities）

```yaml
- id: extract_and_match_entities
  data:
    title: エンティティ抽出・照合
    type: llm
    model:
      provider: google
      name: gemini-2.0-flash
      mode: chat
      completion_params:
        temperature: 0.1
        max_tokens: 16000
```

```yaml
prompt_template:
  - role: system
    text: |
      あなたはAI/IT技術のナレッジグラフ構築エキスパートです。
      記事リストから「エンティティ」（追跡すべき製品・技術・企業・モデル等）を抽出し、
      既存エンティティとの照合を行ってください。

      ## 既存エンティティ一覧
      {{#fetch_existing_entities.body#}}

      ## 評価済み記事リスト
      {{#filter_by_score.filtered_articles#}}

      ## タスク

      ### 1. エンティティ抽出
      各記事から、追跡対象となるエンティティを抽出してください。
      1つの記事から複数のエンティティが抽出される場合があります。

      エンティティの種類:
      - product: 製品・サービス（例: ChatGPT, GitHub Copilot, Dify）
      - oss: OSSプロジェクト（例: LangChain, vLLM, Ollama）
      - company: 企業（例: OpenAI, Anthropic, Google DeepMind）
      - technology: 技術概念（例: RAG, MCP, LoRA, RLHF）
      - standard: 規格・規制（例: EU AI Act, NIST AI RMF）
      - model: AIモデル（例: GPT-5, Claude 4, Gemini 2.5）

      ### 2. 既存エンティティとの照合
      抽出したエンティティが既存一覧に存在するか判定してください。
      - 名前が完全一致しなくても、同一のものを指していれば既存と判定
        例: "GPT-5" と "OpenAI GPT-5" は同一
        例: "Claude Sonnet 4" と "Claude 4 Sonnet" は同一
      - 既存に存在する場合: 既存の entity_id を指定
      - 既存に存在しない場合: "new" と指定

      ### 3. ステータス判定
      各エンティティの現在のステータスを判定:
      - emerging: 噂・リーク段階
      - announced: 公式発表済みだが未リリース
      - beta: ベータ版・プレビュー利用可能
      - active: GA・正式リリース済み
      - mature: 広く普及・安定
      - declining: 非推奨・衰退傾向

      ### 4. 記事との関係性
      各記事とエンティティの関係:
      - about: この記事はこのエンティティが主題
      - mentions: 言及されている
      - announces: 発表・リリース記事
      - reviews: レビュー・評価記事
      - compares: 他との比較記事

      ## 出力形式（JSON）
      ```json
      {
        "entities": [
          {
            "name": "GPT-5",
            "name_normalized": "gpt-5",
            "type": "model",
            "existing_entity_id": "uuid-or-new",
            "current_status": "active",
            "status_summary": "2026年3月18日にGAリリース。全APIプランで利用可能に。",
            "related_article_indices": [0, 3, 7],
            "tags": ["openai", "llm", "multimodal"]
          }
        ],
        "article_entity_links": [
          {
            "article_index": 0,
            "entity_name_normalized": "gpt-5",
            "relationship_type": "announces"
          }
        ]
      }
      ```

      ## 重要な制約
      - エンティティ数は記事数の1-2倍程度が目安（過度に細分化しない）
      - 同一エンティティを複数回抽出しない
      - name_normalized は小文字・ハイフン区切り（例: "gpt-5", "eu-ai-act", "langchain"）
      - 既存エンティティ一覧が空の場合（初回実行）、全て "new" でよい

  - role: user
    text: |
      上記の記事リストからエンティティを抽出し、既存エンティティとの照合を行ってください。
```

---

### 3-4. エンティティ更新データ構築 + 差分レポート生成（build_entity_updates）

```yaml
- id: build_entity_updates
  data:
    title: エンティティ更新・差分検知
    type: code
    code_language: python3
    variables:
      - value_selector: [extract_and_match_entities, text]
        variable: entity_extraction_text
      - value_selector: [fetch_existing_entities, body]
        variable: existing_entities_json
      - value_selector: [filter_by_score, filtered_articles]
        variable: filtered_articles
      - value_selector: [init_date_range, delivery_id]
        variable: delivery_id
    outputs:
      upsert_payload:
        type: string
      article_links_payload:
        type: string
      diff_report:
        type: string
      status_changes:
        type: string
      new_entity_count:
        type: number
      updated_entity_count:
        type: number
```

```python
def main(entity_extraction_text: str, existing_entities_json: str,
         filtered_articles: str, delivery_id: str) -> dict:
    """
    Phase 4: エンティティテーブルの更新データ構築と差分検知。
    - 新規エンティティの登録データ作成
    - 既存エンティティの更新データ作成（last_seen_date, appearance_count, status_history）
    - ステータス変化の検出
    - 差分レポートの生成
    """
    import json
    import re
    from datetime import date

    today = date.today().isoformat()

    # ========================================
    # 入力データのパース
    # ========================================
    def parse_json_from_llm(text):
        match = re.search(r'```(?:json)?\s*(\{[\s\S]*?\})\s*```', text)
        if match:
            return json.loads(match.group(1))
        match = re.search(r'\{[\s\S]*\}', text)
        if match:
            return json.loads(match.group(0))
        return {}

    try:
        extraction = parse_json_from_llm(entity_extraction_text)
    except Exception:
        extraction = {}

    try:
        existing_list = json.loads(existing_entities_json)
        if isinstance(existing_list, list):
            existing_map = {e.get("name_normalized", ""): e for e in existing_list}
        else:
            existing_map = {}
    except Exception:
        existing_list = []
        existing_map = {}

    try:
        articles = json.loads(filtered_articles)
        article_map = {a.get("index", i): a for i, a in enumerate(articles)}
    except Exception:
        articles = []
        article_map = {}

    entities_data = extraction.get("entities", [])
    links_data = extraction.get("article_entity_links", [])

    # ========================================
    # エンティティの UPSERT データ構築
    # ========================================
    upsert_records = []
    status_changes = []
    new_count = 0
    updated_count = 0

    for ent in entities_data:
        name = ent.get("name", "")
        name_norm = ent.get("name_normalized", "")
        ent_type = ent.get("type", "technology")
        new_status = ent.get("current_status", "emerging")
        status_summary = ent.get("status_summary", "")
        existing_id = ent.get("existing_entity_id", "new")
        tags = ent.get("tags", [])

        # 関連記事からURLを取得（status_historyのsource_url用）
        related_indices = ent.get("related_article_indices", [])
        source_url = ""
        scores = []
        for idx in related_indices:
            art = article_map.get(idx, {})
            if art.get("url") and not source_url:
                source_url = art["url"]
            if art.get("overall_score"):
                scores.append(art["overall_score"])

        avg_score = round(sum(scores) / len(scores), 1) if scores else 0

        # 新しい status_history エントリ
        new_history_entry = {
            "date": today,
            "status": new_status,
            "source_url": source_url,
            "summary": status_summary
        }

        if existing_id == "new" or name_norm not in existing_map:
            # 新規エンティティ
            new_count += 1
            upsert_records.append({
                "name": name,
                "name_normalized": name_norm,
                "type": ent_type,
                "first_seen_date": today,
                "last_seen_date": today,
                "appearance_count": 1,
                "status_history": [new_history_entry],
                "current_status": new_status,
                "related_entities": [],
                "overall_score_avg": avg_score,
                "tags": tags,
                "_is_new": True
            })
        else:
            # 既存エンティティの更新
            existing = existing_map[name_norm]
            old_status = existing.get("current_status", "emerging")
            old_count = existing.get("appearance_count", 0)
            old_history = existing.get("status_history", [])
            old_score = existing.get("overall_score_avg", 0)

            # ステータス変化の検出
            if old_status != new_status:
                status_changes.append({
                    "entity_name": name,
                    "entity_type": ent_type,
                    "from_status": old_status,
                    "to_status": new_status,
                    "summary": status_summary
                })

            # status_history に追記
            updated_history = old_history if isinstance(old_history, list) else []
            updated_history.append(new_history_entry)

            # スコア平均の更新（指数移動平均）
            new_avg = round((old_score * 0.7 + avg_score * 0.3), 1) if old_score > 0 else avg_score

            updated_count += 1
            upsert_records.append({
                "name": name,
                "name_normalized": name_norm,
                "type": ent_type,
                "last_seen_date": today,
                "appearance_count": old_count + 1,
                "status_history": updated_history,
                "current_status": new_status,
                "overall_score_avg": new_avg,
                "tags": tags,
                "_is_new": False,
                "_entity_id": existing.get("id", "")
            })

    # ========================================
    # article_entity_links データ構築
    # ========================================
    link_records = []
    for link in links_data:
        art_idx = link.get("article_index", -1)
        ent_name_norm = link.get("entity_name_normalized", "")
        rel_type = link.get("relationship_type", "mentions")

        art = article_map.get(art_idx, {})
        art_hash = art.get("article_hash", "")

        if art_hash and ent_name_norm:
            link_records.append({
                "article_hash": art_hash,
                "entity_name_normalized": ent_name_norm,
                "relationship_type": rel_type
            })

    # ========================================
    # 差分レポート生成
    # ========================================
    diff_lines = []

    # ステータス変化
    if status_changes:
        diff_lines.append("## ステータス変化")
        for sc in status_changes:
            arrow = f"{sc['from_status']} -> {sc['to_status']}"
            diff_lines.append(
                f"- **{sc['entity_name']}** ({sc['entity_type']}): "
                f"{arrow} -- {sc['summary']}"
            )
        diff_lines.append("")

    # 新規エンティティ
    new_entities = [e for e in upsert_records if e.get("_is_new")]
    if new_entities:
        diff_lines.append("## 新規エンティティ")
        for ne in new_entities:
            diff_lines.append(
                f"- **{ne['name']}** ({ne['type']}, {ne['current_status']})"
            )
        diff_lines.append("")

    # 再登場エンティティ（前回も見たが今回も登場）
    returning = [e for e in upsert_records
                 if not e.get("_is_new") and e.get("appearance_count", 0) > 1]
    if returning:
        diff_lines.append("## 継続追跡中のエンティティ")
        for re_ent in returning:
            diff_lines.append(
                f"- **{re_ent['name']}** (通算{re_ent['appearance_count']}回目, "
                f"ステータス: {re_ent['current_status']})"
            )
        diff_lines.append("")

    diff_report = "\n".join(diff_lines) if diff_lines else "差分なし（初回実行または変化なし）"

    # ========================================
    # Supabase用ペイロード整形（_is_new等の内部フラグを除去）
    # ========================================
    clean_upsert = []
    for rec in upsert_records:
        clean = {k: v for k, v in rec.items() if not k.startswith('_')}
        # JSONB フィールドは文字列化しない（Supabase REST APIがJSONBを受け付ける）
        clean_upsert.append(clean)

    return {
        "upsert_payload": json.dumps(clean_upsert, ensure_ascii=False),
        "article_links_payload": json.dumps(link_records, ensure_ascii=False),
        "diff_report": diff_report,
        "status_changes": json.dumps(status_changes, ensure_ascii=False),
        "new_entity_count": new_count,
        "updated_entity_count": updated_count
    }
```

---

## 4. HTTP ノード設定

### 4-1. 既存エンティティ取得（fetch_existing_entities）

```yaml
- id: fetch_existing_entities
  data:
    title: 既存エンティティ取得
    type: http-request
    method: GET
    url: "{{#env.SUPABASE_URL#}}/rest/v1/entities?select=id,name,name_normalized,type,current_status,appearance_count,status_history,overall_score_avg,last_seen_date&order=last_seen_date.desc&limit=500"
    headers:
      apikey: "{{#env.SUPABASE_ANON_KEY#}}"
      Authorization: "Bearer {{#env.SUPABASE_ANON_KEY#}}"
      Content-Type: application/json
    timeout:
      max_connect_timeout: 10
      max_read_timeout: 30
```

### 4-2. エンティティ UPSERT（upsert_entities）

```yaml
- id: upsert_entities
  data:
    title: エンティティ UPSERT
    type: http-request
    method: POST
    url: "{{#env.SUPABASE_URL#}}/rest/v1/entities"
    headers:
      apikey: "{{#env.SUPABASE_ANON_KEY#}}"
      Authorization: "Bearer {{#env.SUPABASE_ANON_KEY#}}"
      Content-Type: application/json
      Prefer: "resolution=merge-duplicates,return=minimal"
    body:
      type: raw-text
      data: "{{#build_entity_updates.upsert_payload#}}"
    timeout:
      max_connect_timeout: 10
      max_read_timeout: 30
```

**注意**: Supabase REST API の UPSERT は `Prefer: resolution=merge-duplicates` ヘッダーで実現する。UNIQUE制約 `uq_entity_name_type` に一致する行があれば UPDATE、なければ INSERT される。

### 4-3. 記事リンク保存（save_article_entity_links）

この前に、articles テーブルにフィルタ済み記事を保存する必要がある。build_entity_updates の中で article 保存用ペイロードも生成するか、別ノードで行う。簡略化のため、article_entity_links の保存はエンティティ名ベースで行い、entity_id の紐付けはSupabase側のトリガーまたは後続バッチで処理する。

```yaml
- id: save_article_entity_links
  data:
    title: 記事リンク保存
    type: http-request
    method: POST
    url: "{{#env.SUPABASE_URL#}}/rest/v1/article_entity_links"
    headers:
      apikey: "{{#env.SUPABASE_ANON_KEY#}}"
      Authorization: "Bearer {{#env.SUPABASE_ANON_KEY#}}"
      Content-Type: application/json
      Prefer: "return=minimal"
    body:
      type: raw-text
      data: "{{#build_entity_updates.article_links_payload#}}"
    timeout:
      max_connect_timeout: 10
      max_read_timeout: 30
```

---

## 5. 実務インパクト分析の改修（impact_analysis）

既存の `llm_impact` プロンプトに、差分レポートとステータス変化情報を追加する。

```yaml
- id: impact_analysis
  data:
    title: 実務インパクト分析
    type: llm
    model:
      provider: google
      name: gemini-2.5-flash-preview-05-20
      mode: chat
      completion_params:
        temperature: 0.3
        max_tokens: 12000
```

```yaml
prompt_template:
  - role: system
    text: |
      あなたはソフトウェア開発チーム向けの「テクノロジーインテリジェンスアナリスト」です。
      ニュースの要約ではなく、**開発者が明日からの設計・実装・学習にどう活かすか**を分析してください。

      ## 入力データ

      ### 評価済み記事リスト（5軸スコア付き）
      {{#filter_by_score.filtered_articles#}}

      ### エンティティ追跡からの差分レポート
      {{#build_entity_updates.diff_report#}}

      ### ステータス変化
      {{#build_entity_updates.status_changes#}}

      ## あなたの出力フォーマット

      ### セクション1: ステータス変化ハイライト（ある場合のみ）
      エンティティのステータスが変化した場合（例: beta→active）、
      その変化が開発者にとって何を意味するかを最優先で伝えてください。

      ### セクション2: 各ニュースの3点分析
      各ニュース項目について:
      1. **何が起きた**: 事実を1-2文。固有名詞・数値・日付を必ず含める。
      2. **誰に効く**: 影響するロール・領域を特定。
      3. **何を試すべきか**: 具体的アクション。
         - 5軸の can_try_now が true の場合: 具体的な試し方（コマンド、URL等）
         - can_try_now が false の場合: 「ウォッチ継続」＋いつ試せそうか

      ### 5軸バッジ
      各項目に5軸の結果をアイコンで表示:
      - [P]: 一次情報  [R]: 実体あり  [D]: 開発者向け  [T]: 今試せる  [H]: 宣伝でない
      （true の軸のみ表示）

      ### ロール別影響度タグ
      - **BE** (バックエンド): 高/中/低/-
      - **FE** (フロントエンド): 高/中/低/-
      - **ML** (ML/AI): 高/中/低/-
      - **Infra** (インフラ/DevOps): 高/中/低/-

      ### 優先度ランク
      - **CRITICAL**: 即座に対応検討（重大脆弱性、Breaking Change等）
      - **HIGH**: 今週中に確認
      - **MEDIUM**: 時間があるときに
      - **LOW**: 興味があれば

      ## 出力形式（JSON配列）
      ```json
      [
        {
          "id": 1,
          "priority": "HIGH",
          "title": "ニュースタイトル（30文字以内）",
          "what_happened": "事実",
          "who_benefits": "対象",
          "what_to_try": "アクション",
          "axes_badges": "[P][R][D][T][H]",
          "roles": {"BE": "中", "FE": "-", "ML": "高", "Infra": "低"},
          "overall_score": 8,
          "source_urls": ["url1"],
          "category": "LLM",
          "entity_name": "GPT-5",
          "status_change": "beta -> active"
        }
      ]
      ```

      ## カテゴリ
      LLM / DevTools / Cloud / Security / Research / Business / Regulation / OSS

      ## 重要な制約
      - 出力は最大15件。優先度が高い順に選定。
      - ステータス変化があるエンティティ関連の記事は優先度を1段上げる。
      - overall_score が7以上（important）の記事を優先的に含める。

  - role: user
    text: |
      上記のデータを分析し、開発チーム向けの実務インパクト分析を実施してください。
```

---

## 6. 環境変数

```yaml
environment_variables:
  - name: SUPABASE_URL
    value: "https://{PROJECT_REF}.supabase.co"
    value_type: string

  - name: SUPABASE_ANON_KEY
    value: ""
    value_type: secret

  - name: SLACK_WEBHOOK_URL
    value: ""
    value_type: secret
```

---

## 7. 既存 v3.0 からの変更サマリー

### 削除するノード
| ノード | 理由 |
|--------|------|
| `code_credibility_dedup_diff` | 3つに分離（normalize, evaluate_5axes, filter_by_score） |

### 新規追加ノード
| ノード | 種別 | 役割 |
|--------|------|------|
| `normalize_raw_data` | Code | 収集データの正規化（何も捨てない） |
| `evaluate_5axes` | LLM (Gemini) | 5軸スコアリング |
| `filter_by_score` | Code | スコアフィルタリング |
| `fetch_existing_entities` | HTTP | Supabase既存エンティティ取得 |
| `extract_and_match_entities` | LLM (Gemini) | エンティティ抽出・照合 |
| `build_entity_updates` | Code | エンティティ更新データ構築・差分検知 |
| `upsert_entities` | HTTP | Supabase UPSERT |
| `save_article_entity_links` | HTTP | 記事-エンティティ紐付け保存 |

### 改修するノード
| ノード | 変更内容 |
|--------|----------|
| `impact_analysis` | 差分レポートとステータス変化を入力に追加 |
| `format_slack_blocks` | 5軸バッジとステータス変化ハイライトを追加 |

---

## 8. Slack 出力イメージ

```
┌─────────────────────────────────────────────────────────┐
│  AI/Tech Intelligence Report                             │
│  2026年3月18日〜2026年3月20日                              │
│  45件収集 → 5軸評価 → 12件採用 (8件除外)                  │
│  新規エンティティ: 3 | ステータス変化: 2                    │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  --- ステータス変化ハイライト ---                          │
│                                                         │
│  GPT-5: beta -> active                                  │
│  Claude Code: announced -> beta                         │
│                                                         │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  [HIGH] `LLM` GPT-5 正式リリース                        │
│  [P][R][D][T][H] スコア: 9/10                           │
│                                                         │
│  1. 何が起きた                                          │
│  OpenAI が 3/18 に GPT-5 を全プランで GA リリース。      │
│  128K コンテキスト、ネイティブマルチモーダル標準搭載。    │
│                                                         │
│  2. 誰に効く                                            │
│  LLM API を利用する全バックエンド開発者。                 │
│                                                         │
│  3. 何を試すべきか                                      │
│  model="gpt-5" に切り替えて既存プロンプトの                │
│  出力品質を比較。特にコード生成タスクで検証。             │
│                                                         │
│  BE:高 FE:中 ML:高 Infra:低                             │
│  エンティティ: GPT-5 (追跡3回目, active)                  │
│  src1 | src2 | src3                                     │
│                                                         │
├─────────────────────────────────────────────────────────┤
│  (以下同様...)                                          │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  --- 今回の追跡エンティティ ---                           │
│  GPT-5 (model/active/3回目)                             │
│  Claude Code (product/beta/2回目)                       │
│  Qwen3 (model/emerging/初出)                            │
│  MCP (technology/active/5回目)                           │
│                                                         │
│  Generated by AInews TechIntelligence v3.1               │
│  5軸: [P]一次情報 [R]実体あり [D]開発者向け              │
│       [T]今試せる [H]宣伝でない                          │
└─────────────────────────────────────────────────────────┘
```

---

## 9. 段階的導入計画

### Phase A: スキーマ作成 + 正規化ノード（1日）
1. Supabase に entities, articles, article_entity_links, delivery_history テーブルを作成
2. `normalize_raw_data` Code ノードを追加
3. 既存パイプラインの `code_credibility_dedup_diff` の前に挿入してテスト

### Phase B: 5軸評価（1-2日）
4. `evaluate_5axes` LLM ノードを追加（Gemini Flash）
5. `filter_by_score` Code ノードを追加
6. 既存の信頼度スコアリングと並行稼働で精度比較

### Phase C: エンティティ追跡（2-3日）
7. `fetch_existing_entities` HTTP ノードを追加
8. `extract_and_match_entities` LLM ノードを追加
9. `build_entity_updates` Code ノードを追加
10. `upsert_entities`, `save_article_entity_links` HTTP ノードを追加
11. 数回実行してエンティティが蓄積されることを確認

### Phase D: 統合・Slack改修（1-2日）
12. `impact_analysis` プロンプトに差分レポートを追加
13. `format_slack_blocks` に5軸バッジとエンティティ情報を追加
14. 既存の `code_credibility_dedup_diff` を削除

**合計見積もり: 5-8日**

---

## 10. コスト見積もり

### LLM呼び出し追加分

| ノード | モデル | 入力トークン目安 | 出力トークン目安 | コスト/回 |
|--------|--------|-----------------|-----------------|----------|
| evaluate_5axes | Gemini 2.0 Flash | ~8,000 | ~4,000 | ~$0.003 |
| extract_and_match_entities | Gemini 2.0 Flash | ~6,000 | ~3,000 | ~$0.002 |
| impact_analysis | Gemini 2.5 Flash | ~10,000 | ~5,000 | ~$0.008 |

- 1回の実行あたり追加コスト: 約 $0.013
- 月12回（月水金）実行: 約 $0.16/月
- Supabase: 無料枠内（テキストデータのみ）

---

## 11. 注意事項

### Dify Sandbox の制約
- Code ノードでは標準ライブラリのみ使用可能（`json`, `re`, `hashlib`, `datetime` 等）
- `urllib.parse` は使えない場合があるため、URL正規化は文字列操作で実装
- 外部ライブラリ（`requests` 等）は使用不可

### Supabase UPSERT の挙動
- `Prefer: resolution=merge-duplicates` で UNIQUE 制約ベースの UPSERT が可能
- `status_history`（JSONB配列）の追記は Supabase REST API 単体では難しいため、Code ノード側で既存データを取得→マージ→送信する方式を採用
- 代替案: Supabase Edge Function で UPSERT + JSONB append を実装

### エンティティ名の正規化
- LLM が返す `name_normalized` のゆれを吸収するため、Supabase 側にも正規化関数があると安全:
```sql
CREATE OR REPLACE FUNCTION normalize_entity_name(input TEXT)
RETURNS TEXT AS $$
BEGIN
    RETURN LOWER(REGEXP_REPLACE(TRIM(input), '\s+', '-', 'g'));
END;
$$ LANGUAGE plpgsql IMMUTABLE;
```
