# 変化検知型ダイジェスト 実装設計書

## 概要

現行の `AInews_DeepResearch_Breadth` は毎回フルサマリーを生成しており、月水金の定期配信では前回との重複が多く読者の負担が大きい。本設計では「前回から何が変わったか」を中心に出力する変化検知型ダイジェストへ移行する。

### 解決する課題
- 毎回のフルサマリーによる情報の重複
- 読者が「何が新しいか」を判別する認知コスト
- 継続トピックの進展が埋もれる問題

### 設計方針
- 永続化層に Supabase を採用（Dify Conversation Variables はワークフロー実行間で揮発するため不適）
- 親アプリが前回データ取得・差分計算を担当し、子アプリ（既存 Breadth）がニュース収集を担当
- LLM によるトピック意味的類似度判定と、ハッシュによる記事完全一致判定のハイブリッド方式

---

## 1. データ永続化層の設計

### 1-1. Supabase テーブルスキーマ

```sql
-- ========================================
-- テーブル1: 配信履歴（delivery_history）
-- ========================================
CREATE TABLE delivery_history (
    id              UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    delivery_date   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    delivery_id     TEXT NOT NULL UNIQUE,          -- "2026-03-20_001" 形式
    article_count   INTEGER NOT NULL DEFAULT 0,
    topic_count     INTEGER NOT NULL DEFAULT 0,
    status          TEXT NOT NULL DEFAULT 'completed',  -- completed / failed
    raw_report      TEXT,                          -- マスターレポート全文
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_delivery_history_date ON delivery_history(delivery_date DESC);

-- ========================================
-- テーブル2: 記事ハッシュ（article_hashes）
-- ========================================
CREATE TABLE article_hashes (
    id              UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    delivery_id     TEXT NOT NULL REFERENCES delivery_history(delivery_id),
    article_hash    TEXT NOT NULL,                  -- SHA256(正規化URL)
    url             TEXT NOT NULL,
    title           TEXT NOT NULL,
    category        TEXT,                           -- 8カテゴリのいずれか
    summary         TEXT,                           -- 1行要約
    source          TEXT,                           -- tavily / zenn / qiita / hatena
    first_seen_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_seen_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    seen_count      INTEGER NOT NULL DEFAULT 1,    -- 何回の配信で登場したか
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_article_hashes_delivery ON article_hashes(delivery_id);
CREATE INDEX idx_article_hashes_hash ON article_hashes(article_hash);
CREATE INDEX idx_article_hashes_last_seen ON article_hashes(last_seen_at DESC);

-- ========================================
-- テーブル3: トピッククラスタ（topic_clusters）
-- ========================================
CREATE TABLE topic_clusters (
    id              UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    delivery_id     TEXT NOT NULL REFERENCES delivery_history(delivery_id),
    topic_name      TEXT NOT NULL,                  -- トピック名（例: "OpenAI GPT-5リリース"）
    topic_hash      TEXT NOT NULL,                  -- SHA256(正規化トピック名)
    category        TEXT NOT NULL,                  -- 8カテゴリ
    status          TEXT NOT NULL DEFAULT 'new',    -- new / updated / continuing / resolved
    importance      INTEGER NOT NULL DEFAULT 5,     -- 1-10の重要度
    summary         TEXT,                           -- 最新サマリー
    related_article_hashes TEXT[],                  -- 関連記事ハッシュの配列
    first_seen_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_seen_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    seen_count      INTEGER NOT NULL DEFAULT 1,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_topic_clusters_delivery ON topic_clusters(delivery_id);
CREATE INDEX idx_topic_clusters_hash ON topic_clusters(topic_hash);
CREATE INDEX idx_topic_clusters_status ON topic_clusters(status);
```

### 1-2. 記事ハッシュの生成方法

**キー: URL（正規化済み）を主キーとする**

理由:
- タイトルは同一記事でもソースによって表記揺れがある
- コンテンツは取得タイミングで変化しうる
- URLは記事の一意識別子として最も安定

```python
# 正規化ルール
# 1. クエリパラメータ（utm_source等のトラッキング系）を除去
# 2. フラグメント（#以降）を除去
# 3. 末尾スラッシュを統一
# 4. httpsに統一
# 5. www.の有無を統一
```

### 1-3. データ保持期間

- **article_hashes**: 直近5回分（約2.5週間）
  - 根拠: 月水金配信で、1つのトピックが話題になる期間はおおむね1〜2週間
- **topic_clusters**: 直近10回分（約5週間）
  - トピックの「解決済み（resolved）」判定には長めのスパンが必要
- **delivery_history**: 直近20回分（約10週間）
  - 傾向分析や振り返りに使用

古いデータは Supabase の cron ジョブで定期削除する:

```sql
-- 毎週日曜に実行
DELETE FROM article_hashes
WHERE delivery_id NOT IN (
    SELECT delivery_id FROM delivery_history
    ORDER BY delivery_date DESC LIMIT 5
);

DELETE FROM topic_clusters
WHERE delivery_id NOT IN (
    SELECT delivery_id FROM delivery_history
    ORDER BY delivery_date DESC LIMIT 10
);

DELETE FROM delivery_history
WHERE delivery_date < NOW() - INTERVAL '70 days';
```

---

## 2. 差分検知ロジックの設計

### 2-1. 判定基準の定義

| 分類 | 条件 | 出力時の詳細度 |
|------|------|---------------|
| **新規 (NEW)** | 前回配信の article_hashes に同一 URL ハッシュが存在しない記事 | 詳細（3〜4行の要約 + ソースURL） |
| **更新 (UPDATED)** | 前回存在したトピッククラスタに新たな記事が追加された、またはLLMが「新展開あり」と判定 | 中程度（変化点のみ1〜2行） |
| **継続中 (CONTINUING)** | 前回と同一トピックが存在し、新たな展開がない | 簡潔（トピック名 + 1行サマリーのみ） |
| **解決済み (RESOLVED)** | 前回存在したが今回は登場しなかったトピック | 表示しない（またはフッターで一覧のみ） |

### 2-2. 同一トピック判定方法（ハイブリッド方式）

#### ステップ1: ハッシュによる記事レベル完全一致
```
現在の記事URL → 正規化 → SHA256 → 前回のarticle_hashesテーブルと照合
→ 一致あり: その記事は「既知」とマーク
→ 一致なし: 「新規候補」とマーク
```

#### ステップ2: LLMによるトピックレベル意味的類似度判定
```
新規候補の記事群 + 前回のtopic_clusters
→ LLMに投入し、以下を判定:
  - 新規候補が既存トピックの「新展開」か「完全新規」か
  - 既存トピックに変化があるか（ステータス更新）
```

この2段階方式を採用する理由:
- ハッシュ照合は高速かつ確実だが、同一トピックの別記事を検知できない
- LLM判定はトピックの意味的つながりを理解できるが、コストと時間がかかる
- 先にハッシュで明確な既知記事を除外することで、LLMへの入力量を削減

---

## 3. 親子アプリ構成の設計

### 3-1. 全体アーキテクチャ

```
[親アプリ: AInews_ChangeDetection_Master]
  |
  +--(1) Code: 初期化・配信ID生成
  |
  +--(2) HTTP: Supabase から前回配信データ取得
  |       - 前回の article_hashes
  |       - 前回の topic_clusters
  |
  +--(3) Code: 前回データ整形
  |
  +--(4) HTTP: 子アプリ API 呼び出し
  |       → [子アプリ: AInews_DeepResearch_Breadth（既存）]
  |       ← マスターレポート（今回の全記事情報）
  |
  +--(5) Code: 記事ハッシュ生成・差分計算
  |       - 新規 / 既知 の振り分け
  |
  +--(6) LLM: トピック差分分析
  |       - 新規 / 更新 / 継続中 / 解決済みの判定
  |       - 変化検知型レポート生成
  |
  +--(7) Code: Slack Block Kit フォーマッティング
  |
  +--(8) HTTP: Supabase に今回データ保存
  |       - delivery_history
  |       - article_hashes
  |       - topic_clusters
  |
  +--(9) HTTP: Slack 送信
  |
  +--(10) End
```

### 3-2. Difyノード構成図（詳細）

```
Start
  │
  ▼
[Code] init_and_generate_id ─────────────────────────────────────────────
  │  入力: (なし)
  │  出力: delivery_id, date_range, query_suffix, current_timestamp
  │
  ▼
[HTTP] fetch_previous_delivery ──────────────────────────────────────────
  │  入力: (なし、直近1件を取得)
  │  出力: prev_delivery_id, prev_articles_json, prev_topics_json
  │
  ▼
[Code] parse_previous_data ──────────────────────────────────────────────
  │  入力: prev_articles_json, prev_topics_json
  │  出力: prev_article_hashes(list), prev_topic_clusters(list),
  │         prev_article_hash_set(string), prev_topic_summary(string)
  │
  ▼
[HTTP] call_child_app ───────────────────────────────────────────────────
  │  入力: date_range, query_suffix
  │  出力: master_report (子アプリのフルレポート)
  │
  ▼
[Code] generate_hashes_and_diff ─────────────────────────────────────────
  │  入力: master_report, prev_article_hash_set
  │  出力: new_articles(list), known_articles(list),
  │         all_article_hashes(list), new_articles_text,
  │         known_articles_text, diff_stats
  │
  ▼
[LLM] topic_diff_analysis ──────────────────────────────────────────────
  │  入力: new_articles_text, known_articles_text,
  │         prev_topic_summary, master_report
  │  出力: change_detection_report (差分レポート)
  │
  ▼
[Code] format_slack_blocks ──────────────────────────────────────────────
  │  入力: change_detection_report, diff_stats, delivery_id, date_range
  │  出力: slack_blocks_json
  │
  ▼
[HTTP] save_to_supabase_delivery ────────────────────────────────────────
  │  入力: delivery_id, article_count, topic_count, master_report
  │  出力: (success/failure)
  │
  ▼
[HTTP] save_to_supabase_articles ────────────────────────────────────────
  │  入力: all_article_hashes (JSON配列)
  │  出力: (success/failure)
  │
  ▼
[HTTP] save_to_supabase_topics ──────────────────────────────────────────
  │  入力: topic_clusters (JSON配列)
  │  出力: (success/failure)
  │
  ▼
[HTTP] send_to_slack ────────────────────────────────────────────────────
  │  入力: slack_blocks_json
  │  出力: (success/failure)
  │
  ▼
End
```

### 3-3. 親子アプリ連携方法

Difyでは Conversation Variables はワークフロー実行内でのみ有効であり、実行間でのデータ共有はできない。そのため以下の方式を採用する:

- **子アプリ呼び出し**: HTTP Request ノードで子アプリの Dify API エンドポイントを呼び出す
- **データ永続化**: Supabase REST API を HTTP Request ノードで直接呼び出す
- **前回データ取得**: 親アプリ起動時に Supabase から直近の配信データを取得

```yaml
# 子アプリ呼び出し設定
child_app_call:
  method: POST
  url: "https://{DIFY_HOST}/v1/workflows/run"
  headers:
    Authorization: "Bearer {CHILD_APP_API_KEY}"
    Content-Type: "application/json"
  body:
    inputs:
      topic: "AI"
    response_mode: "blocking"
    user: "change-detection-master"
```

---

## 4. 各ノードの詳細設計

### 4-1. Code: init_and_generate_id

```python
def main() -> dict:
    from datetime import datetime, timedelta

    today = datetime.now()
    delivery_id = today.strftime('%Y-%m-%d') + "_001"
    week_ago = today - timedelta(days=3)  # 月水金なので前回から約2-3日
    date_range = f"{week_ago.strftime('%Y年%m月%d日')}〜{today.strftime('%Y年%m月%d日')}"
    query_suffix = f" {week_ago.strftime('%Y-%m-%d')} to {today.strftime('%Y-%m-%d')}"

    return {
        "delivery_id": delivery_id,
        "date_range": date_range,
        "query_suffix": query_suffix,
        "current_timestamp": today.isoformat()
    }
```

**出力定義**:
| 変数名 | 型 | 説明 |
|--------|------|------|
| delivery_id | string | 配信ID（例: "2026-03-20_001"） |
| date_range | string | 日付範囲の日本語表記 |
| query_suffix | string | 検索クエリ用日付サフィックス |
| current_timestamp | string | 現在時刻ISO形式 |

### 4-2. HTTP: fetch_previous_delivery

```yaml
method: GET
url: "https://{SUPABASE_PROJECT_REF}.supabase.co/rest/v1/delivery_history?order=delivery_date.desc&limit=1&select=delivery_id"
headers:
  apikey: "{SUPABASE_ANON_KEY}"
  Authorization: "Bearer {SUPABASE_ANON_KEY}"
  Content-Type: "application/json"
```

続けて前回の articles と topics を取得するため、この直後に追加の HTTP ノードが2つ必要:

```yaml
# fetch_previous_articles
method: GET
url: "https://{SUPABASE_PROJECT_REF}.supabase.co/rest/v1/article_hashes?delivery_id=eq.{{prev_delivery_id}}&select=article_hash,url,title,category,summary"
headers:
  apikey: "{SUPABASE_ANON_KEY}"
  Authorization: "Bearer {SUPABASE_ANON_KEY}"

# fetch_previous_topics
method: GET
url: "https://{SUPABASE_PROJECT_REF}.supabase.co/rest/v1/topic_clusters?delivery_id=eq.{{prev_delivery_id}}&select=topic_name,topic_hash,category,status,importance,summary,related_article_hashes"
headers:
  apikey: "{SUPABASE_ANON_KEY}"
  Authorization: "Bearer {SUPABASE_ANON_KEY}"
```

### 4-3. Code: parse_previous_data

```python
def main(prev_articles_json: str, prev_topics_json: str) -> dict:
    import json

    # 前回記事ハッシュのパース
    try:
        prev_articles = json.loads(prev_articles_json)
    except (json.JSONDecodeError, TypeError):
        prev_articles = []

    # 前回トピッククラスタのパース
    try:
        prev_topics = json.loads(prev_topics_json)
    except (json.JSONDecodeError, TypeError):
        prev_topics = []

    # 前回記事ハッシュのセットを文字列化（Codeノード間受け渡し用）
    prev_hash_set = set()
    for article in prev_articles:
        if isinstance(article, dict) and "article_hash" in article:
            prev_hash_set.add(article["article_hash"])
    prev_article_hash_set = json.dumps(list(prev_hash_set))

    # 前回トピックのサマリーを生成（LLM入力用）
    topic_lines = []
    for topic in prev_topics:
        if isinstance(topic, dict):
            name = topic.get("topic_name", "不明")
            category = topic.get("category", "不明")
            status = topic.get("status", "unknown")
            importance = topic.get("importance", 5)
            summary = topic.get("summary", "")
            topic_lines.append(
                f"- [{category}] {name} (重要度:{importance}, 状態:{status})\n  {summary}"
            )
    prev_topic_summary = "\n".join(topic_lines) if topic_lines else "前回配信データなし（初回配信）"

    return {
        "prev_article_hashes": json.dumps(prev_articles),
        "prev_topic_clusters": json.dumps(prev_topics),
        "prev_article_hash_set": prev_article_hash_set,
        "prev_topic_summary": prev_topic_summary,
        "prev_article_count": len(prev_articles),
        "prev_topic_count": len(prev_topics),
        "is_first_delivery": len(prev_articles) == 0
    }
```

**出力定義**:
| 変数名 | 型 | 説明 |
|--------|------|------|
| prev_article_hash_set | string | 前回記事ハッシュのJSON配列 |
| prev_topic_summary | string | LLM入力用の前回トピックサマリー |
| is_first_delivery | boolean | 初回配信かどうか |

### 4-4. Code: generate_hashes_and_diff（記事ハッシュ生成 + 差分計算）

```python
def main(master_report: str, prev_article_hash_set: str) -> dict:
    import hashlib
    import json
    import re
    from urllib.parse import urlparse, parse_qs, urlencode, urlunparse

    # --- URL正規化関数 ---
    def normalize_url(url: str) -> str:
        """URLを正規化してトラッキングパラメータ等を除去"""
        if not url:
            return ""
        try:
            parsed = urlparse(url)

            # httpsに統一
            scheme = "https"

            # www.を除去
            netloc = parsed.netloc.lower()
            if netloc.startswith("www."):
                netloc = netloc[4:]

            # トラッキング系パラメータを除去
            tracking_params = {
                'utm_source', 'utm_medium', 'utm_campaign',
                'utm_term', 'utm_content', 'ref', 'source',
                'fbclid', 'gclid', 'mc_cid', 'mc_eid'
            }
            query_params = parse_qs(parsed.query, keep_blank_values=False)
            filtered_params = {
                k: v for k, v in query_params.items()
                if k.lower() not in tracking_params
            }
            clean_query = urlencode(filtered_params, doseq=True)

            # フラグメント除去、末尾スラッシュ統一
            path = parsed.path.rstrip('/')
            if not path:
                path = '/'

            normalized = urlunparse((scheme, netloc, path, '', clean_query, ''))
            return normalized
        except Exception:
            return url

    def generate_hash(url: str) -> str:
        """正規化URLからSHA256ハッシュを生成"""
        normalized = normalize_url(url)
        return hashlib.sha256(normalized.encode('utf-8')).hexdigest()[:16]

    # --- 前回ハッシュセットの復元 ---
    try:
        prev_hashes = set(json.loads(prev_article_hash_set))
    except (json.JSONDecodeError, TypeError):
        prev_hashes = set()

    # --- マスターレポートからURL・タイトル・サマリーを抽出 ---
    # レポート内の各記事を行単位でパース
    # 想定フォーマット: "- タイトル（日付）\n  URL: https://..."
    # または "- タイトル ... https://..."
    url_pattern = re.compile(r'https?://[^\s\)）]+')
    lines = master_report.split('\n')

    articles = []
    current_category = ""
    current_title = ""
    current_summary = ""

    category_map = {
        "大規模言語モデル": "llm",
        "基盤モデル": "llm",
        "ビジネス": "business",
        "企業動向": "business",
        "研究": "research",
        "技術革新": "research",
        "規制": "regulation",
        "政策": "regulation",
        "クリエイティブ": "creative",
        "実用化": "implementation",
        "導入事例": "implementation",
        "リスク": "risk",
        "倫理": "risk",
        "未来": "future",
        "展望": "future"
    }

    for line in lines:
        stripped = line.strip()

        # カテゴリ見出し検出
        if stripped.startswith('## '):
            heading = stripped[3:].strip()
            for key, val in category_map.items():
                if key in heading:
                    current_category = val
                    break
            continue

        # 記事行（箇条書き）の検出
        if stripped.startswith('- ') or stripped.startswith('* '):
            current_title = stripped[2:].strip()
            current_summary = current_title[:200]

            # URLが同一行に含まれるか
            urls_in_line = url_pattern.findall(stripped)
            for url in urls_in_line:
                url_clean = url.rstrip('）).,;')
                article_hash = generate_hash(url_clean)
                articles.append({
                    "article_hash": article_hash,
                    "url": url_clean,
                    "title": re.sub(r'https?://[^\s]+', '', current_title).strip()[:200],
                    "category": current_category,
                    "summary": current_summary[:300],
                    "is_new": article_hash not in prev_hashes
                })

        # URL単独行の検出
        elif url_pattern.search(stripped):
            urls_in_line = url_pattern.findall(stripped)
            for url in urls_in_line:
                url_clean = url.rstrip('）).,;')
                article_hash = generate_hash(url_clean)
                articles.append({
                    "article_hash": article_hash,
                    "url": url_clean,
                    "title": current_title[:200] if current_title else "タイトル不明",
                    "category": current_category,
                    "summary": current_summary[:300] if current_summary else "",
                    "is_new": article_hash not in prev_hashes
                })

    # --- 新規・既知に分類 ---
    new_articles = [a for a in articles if a.get("is_new", True)]
    known_articles = [a for a in articles if not a.get("is_new", True)]

    # --- LLM入力用テキスト生成 ---
    new_text_lines = []
    for a in new_articles:
        new_text_lines.append(f"[{a['category']}] {a['title']}\n  URL: {a['url']}\n  要約: {a['summary']}")
    new_articles_text = "\n\n".join(new_text_lines) if new_text_lines else "新規記事なし"

    known_text_lines = []
    for a in known_articles:
        known_text_lines.append(f"[{a['category']}] {a['title']}\n  URL: {a['url']}")
    known_articles_text = "\n".join(known_text_lines) if known_text_lines else "既知記事なし"

    # --- 統計情報 ---
    diff_stats = json.dumps({
        "total_articles": len(articles),
        "new_count": len(new_articles),
        "known_count": len(known_articles),
        "new_ratio": round(len(new_articles) / max(len(articles), 1) * 100, 1)
    })

    return {
        "new_articles_text": new_articles_text,
        "known_articles_text": known_articles_text,
        "all_article_hashes": json.dumps(articles),
        "diff_stats": diff_stats,
        "new_count": len(new_articles),
        "known_count": len(known_articles)
    }
```

**出力定義**:
| 変数名 | 型 | 説明 |
|--------|------|------|
| new_articles_text | string | 新規記事一覧（LLM入力用） |
| known_articles_text | string | 既知記事一覧（LLM入力用） |
| all_article_hashes | string | 全記事ハッシュJSON（Supabase保存用） |
| diff_stats | string | 差分統計JSON |
| new_count | number | 新規記事数 |
| known_count | number | 既知記事数 |

### 4-5. LLM: topic_diff_analysis（トピック差分分析）

**モデル設定**:
```yaml
provider: anthropic
name: claude-sonnet-4-20250514
mode: chat
temperature: 0.3
```

**プロンプト**:
```yaml
system:
  text: |
    あなたはAIニュースの「変化検知エディター」です。
    前回配信のトピック情報と、今回収集した記事情報を比較し、
    「何が変わったか」を中心とした変化検知型ダイジェストを生成してください。

    ## 前回配信のトピック一覧
    {{#parse_previous_data.prev_topic_summary#}}

    ## 今回の新規記事（前回に存在しなかったURL）
    {{#generate_hashes_and_diff.new_articles_text#}}

    ## 今回の既知記事（前回にも存在したURL）
    {{#generate_hashes_and_diff.known_articles_text#}}

    ## 今回のフルレポート（参照用）
    {{#call_child_app.master_report#}}

    ## あなたの作業

    ### ステップ1: トピッククラスタリング
    今回の全記事を意味的にグルーピングし、トピック（大きなテーマ単位）を抽出してください。
    1つのトピックには複数の記事が紐づくことがあります。

    ### ステップ2: 変化ステータスの判定
    各トピックについて、前回配信のトピック一覧と比較し、以下のいずれかに分類してください。

    - **NEW（新規）**: 前回配信に存在しなかった完全に新しいトピック。
      判定基準: 前回トピック一覧のどのトピックとも意味的に関連しない。
    - **UPDATED（更新）**: 前回も存在したトピックだが、新たな展開・情報がある。
      判定基準: 前回の同名/類似トピックに対して、新しい記事が追加されている、
      または状況に変化がある（例: 発表 → リリース、噂 → 確定）。
    - **CONTINUING（継続中）**: 前回と同じトピックで、特に新たな展開はない。
      判定基準: 記事は存在するが、前回と本質的に同じ内容。
    - **RESOLVED（解決済み）**: 前回存在したが今回はもう話題になっていないトピック。
      判定基準: 前回のトピック一覧にあるが、今回の記事に関連するものが見当たらない。

    ### ステップ3: 重要度評価
    各トピックに1〜10の重要度スコアを付与してください。
    - 10: 業界全体に大きな影響（例: 主要モデルのリリース、大型買収）
    - 7-9: 注目度が高い（例: 重要な技術発表、政策決定）
    - 4-6: 通常レベルのニュース
    - 1-3: 小規模/ニッチな話題

    ### ステップ4: 変化検知型レポート生成
    以下のフォーマットで出力してください。

    ## 出力フォーマット（厳守）

    ```
    ===TOPICS_JSON_START===
    [
      {
        "topic_name": "トピック名",
        "category": "llm|business|research|regulation|creative|implementation|risk|future",
        "status": "NEW|UPDATED|CONTINUING|RESOLVED",
        "importance": 8,
        "summary": "このトピックの最新サマリー（2-3文）",
        "change_detail": "前回からの変化点（UPDATEDの場合のみ、それ以外は空文字）",
        "related_urls": ["https://..."]
      }
    ]
    ===TOPICS_JSON_END===

    ===REPORT_START===
    # AI ニュース変化検知ダイジェスト

    ## 新規トピック
    （NEWステータスのトピックを重要度順に詳しく記述。各3-4行。）

    ## 更新されたトピック
    （UPDATEDステータスのトピック。前回からの変化点を明記。各1-2行。）

    ## 継続中のトピック
    （CONTINUINGステータスのトピック。トピック名+1行サマリーのみ。）

    ## 今回話題にならなかったトピック
    （RESOLVEDステータスのトピック名を箇条書きで列挙。）
    ===REPORT_END===
    ```

    ## 重要な注意事項
    - 初回配信（前回データなし）の場合、全トピックをNEWとして扱ってください。
    - トピック数は通常10〜20個程度になるはずです。あまり細かく分けすぎないでください。
    - 同一カテゴリ内の類似ニュースはなるべく1つのトピックにまとめてください。
    - JSON部分は正確なJSON形式で出力してください。

user:
  text: |
    前回配信からの変化を分析し、変化検知型ダイジェストを生成してください。

    差分統計:
    {{#generate_hashes_and_diff.diff_stats#}}
```

### 4-6. Code: format_slack_blocks（Slack Block Kit フォーマッティング）

```python
def main(
    change_detection_report: str,
    diff_stats: str,
    delivery_id: str,
    date_range: str
) -> dict:
    import json
    import re

    # --- diff_stats パース ---
    try:
        stats = json.loads(diff_stats)
    except (json.JSONDecodeError, TypeError):
        stats = {"total_articles": 0, "new_count": 0, "known_count": 0, "new_ratio": 0}

    # --- LLM出力からレポート部分を抽出 ---
    report_match = re.search(
        r'===REPORT_START===(.*?)===REPORT_END===',
        change_detection_report,
        re.DOTALL
    )
    report_text = report_match.group(1).strip() if report_match else change_detection_report

    # --- トピックJSONを抽出（Supabase保存用） ---
    topics_match = re.search(
        r'===TOPICS_JSON_START===(.*?)===TOPICS_JSON_END===',
        change_detection_report,
        re.DOTALL
    )
    topics_json = "[]"
    if topics_match:
        try:
            topics_data = json.loads(topics_match.group(1).strip())
            topics_json = json.dumps(topics_data, ensure_ascii=False)
        except json.JSONDecodeError:
            topics_json = "[]"

    # --- セクション分割 ---
    sections = {
        "new": "",
        "updated": "",
        "continuing": "",
        "resolved": ""
    }
    current_section = None
    current_lines = []

    for line in report_text.split('\n'):
        stripped = line.strip()
        if '新規トピック' in stripped:
            if current_section and current_lines:
                sections[current_section] = '\n'.join(current_lines)
            current_section = "new"
            current_lines = []
        elif '更新されたトピック' in stripped:
            if current_section and current_lines:
                sections[current_section] = '\n'.join(current_lines)
            current_section = "updated"
            current_lines = []
        elif '継続中のトピック' in stripped:
            if current_section and current_lines:
                sections[current_section] = '\n'.join(current_lines)
            current_section = "continuing"
            current_lines = []
        elif '話題にならなかった' in stripped:
            if current_section and current_lines:
                sections[current_section] = '\n'.join(current_lines)
            current_section = "resolved"
            current_lines = []
        elif current_section:
            if stripped:
                current_lines.append(stripped)

    if current_section and current_lines:
        sections[current_section] = '\n'.join(current_lines)

    # --- Slack Block Kit 構築 ---
    blocks = []

    # ヘッダー
    blocks.append({
        "type": "header",
        "text": {
            "type": "plain_text",
            "text": "AI News Change Detection Digest",
            "emoji": True
        }
    })

    # コンテキスト（メタ情報）
    blocks.append({
        "type": "context",
        "elements": [
            {
                "type": "mrkdwn",
                "text": f":calendar: {date_range}  |  :id: {delivery_id}  |  :bar_chart: 全{stats.get('total_articles', 0)}件中 新規{stats.get('new_count', 0)}件 ({stats.get('new_ratio', 0)}%)"
            }
        ]
    })

    blocks.append({"type": "divider"})

    # 新規セクション
    if sections["new"]:
        blocks.append({
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": ":new: *新規トピック*"
            }
        })
        # 新規は詳しく表示（最大3000文字）
        new_text = sections["new"][:2900]
        blocks.append({
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": new_text
            }
        })
        blocks.append({"type": "divider"})

    # 更新セクション
    if sections["updated"]:
        blocks.append({
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": ":arrows_counterclockwise: *更新されたトピック*"
            }
        })
        updated_text = sections["updated"][:2000]
        blocks.append({
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": updated_text
            }
        })
        blocks.append({"type": "divider"})

    # 継続中セクション
    if sections["continuing"]:
        blocks.append({
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": ":round_pushpin: *継続中のトピック*"
            }
        })
        # 継続中は簡潔に
        continuing_text = sections["continuing"][:1500]
        blocks.append({
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": continuing_text
            }
        })

    # 解決済みセクション（コンパクト）
    if sections["resolved"]:
        blocks.append({
            "type": "context",
            "elements": [
                {
                    "type": "mrkdwn",
                    "text": f":white_check_mark: *前回から消えたトピック*: {sections['resolved'][:500]}"
                }
            ]
        })

    # フッター
    blocks.append({"type": "divider"})
    blocks.append({
        "type": "context",
        "elements": [
            {
                "type": "mrkdwn",
                "text": ":robot_face: Generated by AInews ChangeDetection | Powered by Dify + Claude Sonnet 4"
            }
        ]
    })

    # Slack APIペイロード全体
    slack_payload = json.dumps({
        "channel": "SLACK_CHANNEL_ID",
        "blocks": blocks
    }, ensure_ascii=False)

    return {
        "slack_blocks_json": slack_payload,
        "topics_json": topics_json,
        "report_text": report_text
    }
```

**出力定義**:
| 変数名 | 型 | 説明 |
|--------|------|------|
| slack_blocks_json | string | Slack Block Kit JSON |
| topics_json | string | トピッククラスタJSON（Supabase保存用） |
| report_text | string | プレーンテキストレポート |

### 4-7. HTTP: save_to_supabase_delivery

```yaml
method: POST
url: "https://{SUPABASE_PROJECT_REF}.supabase.co/rest/v1/delivery_history"
headers:
  apikey: "{SUPABASE_ANON_KEY}"
  Authorization: "Bearer {SUPABASE_ANON_KEY}"
  Content-Type: "application/json"
  Prefer: "return=minimal"
body:
  type: json
  data: |
    {
      "delivery_id": "{{#init_and_generate_id.delivery_id#}}",
      "article_count": {{#generate_hashes_and_diff.new_count#}},
      "topic_count": 0,
      "raw_report": "{{#call_child_app.master_report#}}",
      "status": "completed"
    }
```

### 4-8. HTTP: save_to_supabase_articles

記事ハッシュは一括挿入する。Supabase REST API は配列を受け付ける。

```yaml
method: POST
url: "https://{SUPABASE_PROJECT_REF}.supabase.co/rest/v1/article_hashes"
headers:
  apikey: "{SUPABASE_ANON_KEY}"
  Authorization: "Bearer {SUPABASE_ANON_KEY}"
  Content-Type: "application/json"
  Prefer: "return=minimal"
body:
  type: raw
  data: "{{#generate_hashes_and_diff.all_article_hashes#}}"
```

ただし、all_article_hashes の各要素に delivery_id を付与する必要がある。generate_hashes_and_diff ノード内でこれを行うか、保存前に追加の Code ノードを入れる。

### 4-9. HTTP: save_to_supabase_topics

```yaml
method: POST
url: "https://{SUPABASE_PROJECT_REF}.supabase.co/rest/v1/topic_clusters"
headers:
  apikey: "{SUPABASE_ANON_KEY}"
  Authorization: "Bearer {SUPABASE_ANON_KEY}"
  Content-Type: "application/json"
  Prefer: "return=minimal"
body:
  type: raw
  data: "{{#format_slack_blocks.topics_json#}}"
```

### 4-10. HTTP: send_to_slack

```yaml
method: POST
url: "https://slack.com/api/chat.postMessage"
headers:
  Authorization: "Bearer {SLACK_BOT_TOKEN}"
  Content-Type: "application/json"
body:
  type: raw
  data: "{{#format_slack_blocks.slack_blocks_json#}}"
timeout:
  max_connect_timeout: 10
  max_read_timeout: 30
  max_write_timeout: 30
retry_config:
  retry_enabled: true
  max_retries: 3
  retry_interval: 1000
```

---

## 5. Slack出力フォーマットの例

実際のSlack表示イメージ:

```
┌──────────────────────────────────────────────────┐
│  AI News Change Detection Digest                  │
│                                                    │
│  📅 2026年3月18日〜3月20日 | 🆔 2026-03-20_001    │
│  📊 全42件中 新規18件 (42.9%)                      │
│──────────────────────────────────────────────────│
│                                                    │
│  🆕 *新規トピック*                                  │
│                                                    │
│  *Claude 4 ファミリー正式発表*                       │
│  Anthropic が Claude 4 Opus/Sonnet/Haiku を        │
│  発表。コーディング能力が大幅に向上し、              │
│  SWE-bench で GPT-5 を上回るスコアを記録。          │
│  推論コスト30%削減。                                │
│  🔗 https://anthropic.com/news/claude-4            │
│                                                    │
│  *EU AI Act 施行規則の詳細公開*                      │
│  欧州委員会がAI Actの施行細則を公開。               │
│  ハイリスクAIシステムの分類基準が具体化。            │
│  🔗 https://ec.europa.eu/...                       │
│                                                    │
│──────────────────────────────────────────────────│
│                                                    │
│  🔄 *更新されたトピック*                            │
│                                                    │
│  *OpenAI GPT-5 ベータプログラム*                     │
│  → 前回: 限定ベータ開始の発表                       │
│  → 今回: 企業向けベータが100社に拡大。               │
│    初期レビューでマルチモーダル性能が好評。          │
│                                                    │
│  *Google DeepMind Gemini 3 開発*                     │
│  → 前回: 開発中との報道                             │
│  → 今回: ベンチマーク結果がリーク。                  │
│    数学的推論でGPT-5と同等との情報。                 │
│                                                    │
│──────────────────────────────────────────────────│
│                                                    │
│  📍 *継続中のトピック*                              │
│                                                    │
│  • AI Agent フレームワーク競争 — 主要各社が          │
│    エージェント基盤を整備中                          │
│  • 半導体供給問題 — NVIDIA H200の供給不足が継続      │
│  • 日本のAI戦略 — 政府のAI推進計画は変化なし        │
│                                                    │
│  ✅ 前回から消えたトピック: Stability AI 経営問題,   │
│     Meta Llama 3.3 リリース                         │
│                                                    │
│──────────────────────────────────────────────────│
│  🤖 Generated by AInews ChangeDetection            │
└──────────────────────────────────────────────────┘
```

---

## 6. 初回配信時の動作

前回データが存在しない初回配信では:

1. `parse_previous_data` ノードが `is_first_delivery: true` を返す
2. `generate_hashes_and_diff` ノードで全記事が「新規」と判定される
3. LLMプロンプト内の `prev_topic_summary` が「前回配信データなし（初回配信）」となる
4. LLMは全トピックをNEWとして分類
5. 出力はフルサマリーと同等の内容になる（ただしフォーマットは変化検知型）

これにより、既存のフルサマリー配信からの移行がシームレスに行える。

---

## 7. エッジ（接続）定義

```yaml
edges:
  - source: start_node
    target: init_and_generate_id
    sourceType: start
    targetType: code

  - source: init_and_generate_id
    target: fetch_previous_delivery
    sourceType: code
    targetType: http-request

  - source: fetch_previous_delivery
    target: fetch_previous_articles
    sourceType: http-request
    targetType: http-request

  - source: fetch_previous_delivery
    target: fetch_previous_topics
    sourceType: http-request
    targetType: http-request

  - source: fetch_previous_articles
    target: parse_previous_data
    sourceType: http-request
    targetType: code

  - source: fetch_previous_topics
    target: parse_previous_data
    sourceType: http-request
    targetType: code

  - source: parse_previous_data
    target: call_child_app
    sourceType: code
    targetType: http-request

  - source: call_child_app
    target: generate_hashes_and_diff
    sourceType: http-request
    targetType: code

  - source: generate_hashes_and_diff
    target: topic_diff_analysis
    sourceType: code
    targetType: llm

  - source: topic_diff_analysis
    target: format_slack_blocks
    sourceType: llm
    targetType: code

  - source: format_slack_blocks
    target: save_to_supabase_delivery
    sourceType: code
    targetType: http-request

  - source: save_to_supabase_delivery
    target: save_to_supabase_articles
    sourceType: http-request
    targetType: http-request

  - source: save_to_supabase_articles
    target: save_to_supabase_topics
    sourceType: http-request
    targetType: http-request

  - source: save_to_supabase_topics
    target: send_to_slack
    sourceType: http-request
    targetType: http-request

  - source: send_to_slack
    target: end_node
    sourceType: http-request
    targetType: end
```

---

## 8. 環境変数

```yaml
environment_variables:
  - name: SUPABASE_URL
    value: "https://{PROJECT_REF}.supabase.co"

  - name: SUPABASE_ANON_KEY
    value: "{ANON_KEY}"

  - name: SLACK_BOT_TOKEN
    value: "SET_IN_SECRET_MANAGER"

  - name: SLACK_CHANNEL_ID
    value: "C0XXXXXXX"

  - name: CHILD_APP_API_KEY
    value: "app-..."

  - name: DIFY_HOST
    value: "https://your-dify-instance.com"
```

---

## 9. 実装ステップ

### Phase 1: Supabase 環境構築（1日）
1. Supabase プロジェクト作成
2. テーブル作成（上記スキーマ）
3. RLS（Row Level Security）ポリシー設定
4. API接続テスト

### Phase 2: 子アプリ API 化（0.5日）
5. 既存 AInews_DeepResearch_Breadth を「公開API」として設定
6. API キー発行
7. cURL での動作確認

### Phase 3: 親アプリ基本構造（2日）
8. 親ワークフロー新規作成
9. 初期化・Supabase取得ノード実装
10. 子アプリ呼び出しノード実装
11. ハッシュ生成・差分計算ノード実装

### Phase 4: LLM差分分析（1日）
12. トピック差分分析LLMノード実装
13. プロンプト調整・テスト

### Phase 5: Slack配信（1日）
14. Slack Block Kit フォーマッティングノード実装
15. Supabase保存ノード実装
16. Slack送信ノード実装

### Phase 6: テスト・調整（2日）
17. 初回配信テスト（前回データなし）
18. 2回目配信テスト（差分検知動作確認）
19. エッジケーステスト（Supabase障害時、子アプリタイムアウト時）
20. 出力品質チューニング

---

## 10. 注意事項・制約

### 実行時間の見積もり
| ノード | 所要時間 |
|--------|---------|
| 初期化 | 1秒 |
| Supabase前回データ取得 (3リクエスト) | 3秒 |
| 前回データパース | 1秒 |
| 子アプリ呼び出し（既存Breadth全体） | 4-5分 |
| ハッシュ生成・差分計算 | 2秒 |
| LLMトピック差分分析 | 30-60秒 |
| Slack Block Kit整形 | 1秒 |
| Supabase保存 (3リクエスト) | 3秒 |
| Slack送信 | 2秒 |
| **合計** | **約5-7分** |

### Supabase 無料枠の考慮
- 無料プラン: 500MB DB、50,000行
- 月水金配信 × 各回50記事 = 月600行程度 → 十分余裕あり
- 古いデータの定期削除で容量を管理

### エラーハンドリング
- Supabase 取得失敗時: 前回データなしとして初回配信モードで動作
- 子アプリタイムアウト時: Slack にエラー通知を送信して終了
- Supabase 保存失敗時: Slack 配信は実行（データ保存はベストエフォート）

### 既存ワークフローとの共存
- 既存の AInews_DeepResearch_Breadth は変更不要（子アプリとしてそのまま利用）
- 親アプリは新規ワークフローとして作成
- 移行期間中は両方を並行稼働可能
