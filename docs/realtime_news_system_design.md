# AI/ITニュース リアルタイム監視・比較分析システム 設計書

## 概要

既存の月水金定期配信ワークフロー（AInews_DeepResearch_Breadth）を補完し、
「リアルタイム検知」「比較分析」「即実行」「技術マッピング」の4つの仕組みを追加する。

### システム全体像

```
[既存] AInews_DeepResearch_Breadth (月水金 定期配信)
  |
  +-- [新規1] Breaking News Alert (2時間ごとポーリング / 別ワークフロー)
  +-- [新規2] Benchmark Compare  (Breaking News から条件分岐で起動)
  +-- [新規3] Try-It-Now Links   (Benchmark Compare の後段)
  +-- [新規4] Competitor Map      (定期配信・Breaking News 両方の後段)
```

---

## 1. ブレイキングニュースアラート

### 1.1 設計方針

- **別ワークフロー**として構築する（理由: ポーリング頻度が定期配信と異なる。障害時に既存配信に影響しない）
- **ポーリング頻度: 2時間ごと**（理由: 毎時はAPI費用が嵩む。4時間では速報性が落ちる。2時間がバランス良い）
- Difyの外部スケジューラ（cron / GitHub Actions / n8n 等）から2時間ごとにワークフローAPIを呼び出す
- 「重大ではない」と判定された場合はSlack送信をスキップし、空振りさせる

### 1.2 「重大」の判定基準設計

LLMに判定させるためのスコアリングフレームワーク:

| 判定軸 | 重み | 説明 |
|--------|------|------|
| 影響範囲 (Scope) | 30% | 業界全体か、特定企業のみか |
| 即時性 (Urgency) | 25% | 今日知らなければ意味がなくなるか |
| 開発者への関連性 (Relevance) | 25% | 開発者の日常業務・技術選定に直結するか |
| 不可逆性 (Irreversibility) | 20% | 買収・規制など、一度起きたら戻せない変化か |

スコア70/100以上を「ブレイキング」と判定する。

### 1.3 Difyワークフロー構成

```
Start
  |
  v
[Code] 日時計算（前回チェックからの差分時間を算出）
  |
  v
[Tool] Tavily Search（"AI breaking news" + 直近2時間の期間指定）
  |
  v
[LLM] ニュース重大度スコアリング（スコア付きJSON出力）
  |
  v
[Code] スコア閾値判定（70以上のニュースを抽出）
  |
  v
[IF] ブレイキングニュースが存在するか？
  |-- YES --> [LLM] アラートメッセージ生成
  |            |
  |            v
  |           [HTTP] Slack Webhook送信
  |            |
  |            v
  |           [IF] 新モデルリリースか？
  |            |-- YES --> [HTTP] ベンチマーク比較ワークフロー呼び出し
  |            |-- NO  --> End
  |
  |-- NO  --> End（何も送信しない）
```

### 1.4 LLMプロンプト: 重大度スコアリング

```
あなたはAI/IT業界のシニアアナリストです。

以下のニュース群を分析し、各ニュースの「重大度スコア」を算出してください。

## 評価基準（100点満点）
1. **影響範囲 (30点)**: AI/IT業界全体に影響するか？
   - 30点: 業界の勢力図が変わるレベル（大型買収、主要モデルの世代交代）
   - 20点: 主要プレイヤー複数に影響（API価格改定、新規制）
   - 10点: 特定企業・プロダクトに限定
   - 0点: ニッチな話題

2. **即時性 (25点)**: 今すぐ知る必要があるか？
   - 25点: 本日中に対応が必要（APIの破壊的変更、サービス停止）
   - 15点: 今週中に把握すべき（新モデルリリース、重要アップデート）
   - 5点: 月次の振り返りで十分
   - 0点: 時間的制約なし

3. **開発者関連性 (25点)**: 開発者の技術選定・業務に直結するか？
   - 25点: 今使っているツール/APIに直接影響
   - 15点: 技術選定の候補に入るべき新技術
   - 5点: 知識として知っておくレベル
   - 0点: 開発者には無関係

4. **不可逆性 (20点)**: 後戻りできない変化か？
   - 20点: 買収完了、サービス終了、法規制施行
   - 10点: 大型投資、戦略転換の発表
   - 0点: ベータリリース、研究論文

## ニュースソース
{{#tavily_search_results#}}

## 出力形式（必ずこのJSON形式で出力）
```json
{
  "news_items": [
    {
      "title": "ニュースタイトル",
      "summary": "50文字以内の要約",
      "score": 85,
      "score_breakdown": {
        "scope": 25,
        "urgency": 20,
        "relevance": 25,
        "irreversibility": 15
      },
      "category": "model_release|acquisition|regulation|api_change|funding|partnership|open_source|other",
      "source_url": "元記事URL"
    }
  ],
  "highest_score": 85
}
```

スコアは厳格に付けてください。70点以上は本当に重大なニュースのみです。
日常的なアップデートや小規模な発表は50点以下にしてください。
```

### 1.5 Slackメッセージフォーマット（Block Kit）

```json
{
  "blocks": [
    {
      "type": "header",
      "text": {
        "type": "plain_text",
        "text": "🚨 BREAKING: {{title}}"
      }
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*重大度: {{score}}/100*\n\n{{summary}}"
      },
      "accessory": {
        "type": "button",
        "text": {
          "type": "plain_text",
          "text": "記事を読む"
        },
        "url": "{{source_url}}",
        "action_id": "read_article"
      }
    },
    {
      "type": "context",
      "elements": [
        {
          "type": "mrkdwn",
          "text": "📊 影響範囲: {{scope}}/30 | ⏰ 即時性: {{urgency}}/25 | 👨‍💻 開発者関連: {{relevance}}/25 | 🔒 不可逆性: {{irreversibility}}/20"
        }
      ]
    },
    {
      "type": "divider"
    },
    {
      "type": "actions",
      "elements": [
        {
          "type": "button",
          "text": {
            "type": "plain_text",
            "text": "📋 比較表を生成"
          },
          "style": "primary",
          "action_id": "generate_benchmark"
        },
        {
          "type": "button",
          "text": {
            "type": "plain_text",
            "text": "🗺️ 競合マップ表示"
          },
          "action_id": "show_competitor_map"
        }
      ]
    }
  ]
}
```

### 1.6 外部スケジューラ設定例（crontab）

```bash
# 2時間ごとにDifyワークフローAPIを呼び出す（6:00〜24:00 JST）
0 6,8,10,12,14,16,18,20,22,0 * * * curl -s -X POST \
  "https://your-dify-instance/v1/workflows/run" \
  -H "Authorization: Bearer ${DIFY_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"inputs": {}, "response_mode": "blocking", "user": "cron-breaking-news"}'
```

---

## 2. ベンチマーク比較テーブル自動生成

### 2.1 設計方針

- ブレイキングニュースの `category` が `model_release` の場合に自動起動
- 別ワークフローとして実装し、HTTP Requestで呼び出す（親子アプリ構成に準拠）
- LLMの知識 + Tavily検索で最新ベンチマーク情報を収集し、比較表を生成

### 2.2 Difyワークフロー構成

```
Start（入力: new_model_name, news_summary）
  |
  v
[LLM] 比較対象モデルの特定
  |  （入力されたモデル名から、同カテゴリの主要競合モデルを3〜5個特定）
  v
[Code] 比較対象リストをパース
  |
  v
[Iteration] 各モデルのベンチマーク情報検索
  |  |
  |  +-- [Tool] Tavily Search（"{{model_name}} benchmark MMLU HumanEval"）
  |  +-- [LLM] 検索結果から数値データ抽出
  |
  v
[Variable Aggregator] 全モデルのデータ統合
  |
  v
[LLM] 比較テーブル生成（Markdown + Slack Block Kit形式）
  |
  v
[Code] Slack Block Kit JSON構築
  |
  v
[HTTP] Slack Webhook送信
  |
  v
End
```

### 2.3 LLMプロンプト: 比較対象モデル特定

```
あなたはAIモデルの専門アナリストです。

新しくリリースされたモデル「{{new_model_name}}」について、
比較すべき主要な競合モデルを特定してください。

## ニュース要約
{{news_summary}}

## 要件
- 同じカテゴリ（テキスト生成、画像生成、コード生成など）のモデルを選ぶ
- 現時点で最も広く使われている上位3〜5モデルを選定
- 各社の最新フラッグシップモデルを優先

## 出力形式（JSON）
```json
{
  "new_model": "{{new_model_name}}",
  "model_type": "テキスト生成LLM|画像生成|コード生成|マルチモーダル|音声|埋め込み",
  "competitors": [
    {
      "name": "モデル名",
      "provider": "提供企業名",
      "reason": "比較対象として選定した理由"
    }
  ],
  "benchmark_categories": ["MMLU", "HumanEval", "MATH", "...モデルタイプに適したベンチマーク"]
}
```
```

### 2.4 LLMプロンプト: 比較テーブル生成

```
あなたはAIモデルのベンチマーク分析の専門家です。

以下の検索結果を元に、モデル比較テーブルを生成してください。

## 新モデル
{{new_model_name}}

## 比較対象モデル
{{competitor_list}}

## 収集済みベンチマークデータ
{{aggregated_benchmark_data}}

## 出力要件

### 1. 比較テーブル（必須）
以下の項目を含むこと:
- モデル名
- 提供企業
- パラメータ数（公開されている場合）
- 主要ベンチマークスコア（MMLU, HumanEval, MATH等。モデルタイプに応じて調整）
- コンテキストウィンドウ
- API料金（入力/出力 per 1M tokens）
- リリース日
- 特筆すべき強み/弱み

### 2. 分析コメント（必須）
- 新モデルが既存モデルに対して優位な点
- 新モデルの弱点・懸念事項
- 開発者がすぐに移行を検討すべきユースケース
- 様子見が推奨されるユースケース

### 3. 出力形式
以下のJSON形式で出力してください:
```json
{
  "comparison_table": [
    {
      "model": "モデル名",
      "provider": "企業名",
      "params": "パラメータ数",
      "mmlu": "スコア",
      "humaneval": "スコア",
      "math": "スコア",
      "context_window": "トークン数",
      "price_input": "$X.XX/1M",
      "price_output": "$X.XX/1M",
      "release_date": "YYYY-MM-DD",
      "strengths": "強み",
      "weaknesses": "弱み"
    }
  ],
  "analysis": {
    "advantages": ["新モデルの優位点1", "..."],
    "concerns": ["懸念事項1", "..."],
    "migrate_now": ["すぐ移行すべきユースケース1", "..."],
    "wait_and_see": ["様子見推奨ケース1", "..."]
  }
}
```

重要: ベンチマークスコアが検索結果から確認できなかった場合は "N/A" と明記し、
推測値を入れないでください。
```

### 2.5 Slackメッセージフォーマット（Block Kit）

```json
{
  "blocks": [
    {
      "type": "header",
      "text": {
        "type": "plain_text",
        "text": "📊 モデル比較: {{new_model_name}} vs 競合モデル"
      }
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "新モデル *{{new_model_name}}* のリリースを受け、主要競合モデルとの比較表を自動生成しました。"
      }
    },
    {
      "type": "divider"
    },
    {
      "type": "rich_text",
      "elements": [
        {
          "type": "rich_text_preformatted",
          "elements": [
            {
              "type": "text",
              "text": "モデル          | MMLU  | HumanEval | 料金(入力)  | コンテキスト\n─────────────────┼───────┼───────────┼────────────┼───────────\nGPT-5           | 92.1  | 95.3      | $3.00/1M   | 256K\nClaude Opus 4   | 91.5  | 93.8      | $15.00/1M  | 1M\nGemini 2.5 Pro  | 90.8  | 92.1      | $1.25/1M   | 1M"
            }
          ]
        }
      ]
    },
    {
      "type": "divider"
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*✅ 優位な点*\n{{#each advantages}}• {{this}}\n{{/each}}\n\n*⚠️ 懸念事項*\n{{#each concerns}}• {{this}}\n{{/each}}"
      }
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*🚀 すぐ移行を検討*\n{{#each migrate_now}}• {{this}}\n{{/each}}\n\n*⏳ 様子見推奨*\n{{#each wait_and_see}}• {{this}}\n{{/each}}"
      }
    },
    {
      "type": "divider"
    },
    {
      "type": "context",
      "elements": [
        {
          "type": "mrkdwn",
          "text": "⚠️ ベンチマークスコアはリリース直後のため変動の可能性があります | 自動生成: {{timestamp}}"
        }
      ]
    }
  ]
}
```

**Slack表示の補足**:
Slack Block Kitはネイティブのテーブル表示をサポートしていないため、
`rich_text_preformatted`（等幅フォント）で疑似テーブルを表現する。
モデル数が多い場合は、Slack Canvas / Slack File Upload APIで
HTML/CSVテーブルを添付ファイルとして送る方法も有効。

---

## 3.「今すぐ試せる」ダッシュボード

### 3.1 設計方針

- ベンチマーク比較ワークフローの後段に接続（比較テーブルと同時にリンク集を送信）
- LLMの知識 + Tavily検索でPlayground / Colab / ドキュメントのURLを収集
- 独立して呼び出すことも可能（汎用ワークフロー）

### 3.2 Difyワークフロー構成

```
Start（入力: technology_name, technology_type）
  |
  v
[Tool] Tavily Search（"{{technology_name}} playground API demo try online"）
  |
  v
[Tool] Tavily Search（"{{technology_name}} getting started documentation quickstart"）
  |
  v
[Tool] Tavily Search（"{{technology_name}} Google Colab notebook tutorial"）
  |
  v
[LLM] リンク整理・分類・有効性判定
  |
  v
[Code] Slack Block Kit JSON構築
  |
  v
[HTTP] Slack Webhook送信
  |
  v
End
```

### 3.3 LLMプロンプト: リンク収集・分類

```
あなたはAI/IT開発ツールの専門ガイドです。

新しくリリースされた技術「{{technology_name}}」（種別: {{technology_type}}）について、
開発者がすぐに試せるリソースを以下の検索結果から整理してください。

## 検索結果
### Playground/デモ検索
{{#search_playground#}}

### ドキュメント検索
{{#search_docs#}}

### Colab/チュートリアル検索
{{#search_colab#}}

## 分類カテゴリ（全て埋めること。該当なしの場合は "not_found" と記載）

```json
{
  "technology": "{{technology_name}}",
  "links": {
    "playground": {
      "url": "公式Playgroundまたはデモページ",
      "description": "ブラウザで即座に試せる",
      "requires_signup": true/false,
      "free_tier": true/false
    },
    "api_docs": {
      "url": "APIドキュメント",
      "description": "公式APIリファレンス",
      "quickstart_url": "クイックスタートガイドのURL"
    },
    "colab_notebook": {
      "url": "Google Colabノートブック",
      "description": "ワンクリックで実行可能な環境",
      "official": true/false
    },
    "github_repo": {
      "url": "GitHubリポジトリ",
      "stars": "スター数（わかる場合）",
      "description": "リポジトリの概要"
    },
    "pricing": {
      "url": "料金ページ",
      "free_tier_summary": "無料枠の概要（例: 月1000リクエストまで無料）"
    },
    "community": {
      "discord": "DiscordサーバーURL",
      "forum": "公式フォーラムURL"
    }
  },
  "quick_start_steps": [
    "ステップ1: ...",
    "ステップ2: ...",
    "ステップ3: ..."
  ],
  "estimated_setup_time": "5分|15分|30分|1時間以上"
}
```

重要:
- URLは検索結果に実際に含まれるもののみ使用し、推測でURLを生成しないこと
- 見つからなかった項目は "not_found" と正直に記載すること
- quick_start_steps は最大5ステップ、最小限の手順で試せる方法を記載
```

### 3.4 Slackメッセージフォーマット（Block Kit）

```json
{
  "blocks": [
    {
      "type": "header",
      "text": {
        "type": "plain_text",
        "text": "🧪 今すぐ試せる: {{technology_name}}"
      }
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "セットアップ目安: *{{estimated_setup_time}}*"
      }
    },
    {
      "type": "divider"
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*🎮 Playground*\n{{playground_description}}\nサインアップ: {{requires_signup}} | 無料枠: {{free_tier}}"
      },
      "accessory": {
        "type": "button",
        "text": { "type": "plain_text", "text": "試す" },
        "url": "{{playground_url}}",
        "style": "primary"
      }
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*📖 APIドキュメント*\nクイックスタートガイド付き"
      },
      "accessory": {
        "type": "button",
        "text": { "type": "plain_text", "text": "読む" },
        "url": "{{api_docs_url}}"
      }
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*📓 Google Colab*\nワンクリックで実行環境を起動"
      },
      "accessory": {
        "type": "button",
        "text": { "type": "plain_text", "text": "開く" },
        "url": "{{colab_url}}"
      }
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*⚡ クイックスタート*\n{{#each quick_start_steps}}{{@index}}. {{this}}\n{{/each}}"
      }
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*💰 料金*\n{{free_tier_summary}}"
      },
      "accessory": {
        "type": "button",
        "text": { "type": "plain_text", "text": "料金詳細" },
        "url": "{{pricing_url}}"
      }
    },
    {
      "type": "divider"
    },
    {
      "type": "actions",
      "elements": [
        {
          "type": "button",
          "text": { "type": "plain_text", "text": "⭐ GitHub" },
          "url": "{{github_url}}"
        },
        {
          "type": "button",
          "text": { "type": "plain_text", "text": "💬 Discord" },
          "url": "{{discord_url}}"
        }
      ]
    }
  ]
}
```

---

## 4. 競合/代替技術マッピング

### 4.1 設計方針

- 定期配信・ブレイキングニュースの**両方から呼び出せる**汎用ワークフロー
- 技術名を入力すると、競合・代替・補完技術をマッピングして返す
- LLMの知識を主軸に、Tavily検索で最新の動向を補完

### 4.2 Difyワークフロー構成

```
Start（入力: technology_name, context_summary）
  |
  v
[LLM] 技術カテゴリ判定 + 初期マッピング（LLMの知識ベース）
  |
  v
[Code] マッピング結果パース
  |
  v
[Iteration] 各競合技術の最新状況を検索
  |  |
  |  +-- [Tool] Tavily Search（"{{competitor}} vs {{technology_name}} 2026"）
  |  +-- [LLM] 検索結果から差分・最新動向を抽出
  |
  v
[Variable Aggregator] 全競合の最新情報統合
  |
  v
[LLM] 最終マッピング生成（関係性の分類を含む）
  |
  v
[Code] Slack Block Kit JSON構築
  |
  v
[HTTP] Slack Webhook送信
  |
  v
End
```

### 4.3 LLMプロンプト: 技術マッピング

```
あなたはAI/IT技術のエコシステムに精通したアーキテクトです。

技術「{{technology_name}}」について、関連する競合・代替・補完技術をマッピングしてください。

## コンテキスト
{{context_summary}}

## マッピングルール

各関連技術を以下の関係性で分類すること:

1. **直接競合 (Direct Competitor)**: 同じ問題を同じアプローチで解決
   - 例: LangChain ←→ LlamaIndex
2. **代替手段 (Alternative Approach)**: 同じ問題を異なるアプローチで解決
   - 例: RAG ←→ ファインチューニング
3. **補完技術 (Complementary)**: 組み合わせて使うことが多い
   - 例: LangChain + ChromaDB
4. **上位概念 (Parent Category)**: より広いカテゴリ
   - 例: LangChain → LLMオーケストレーションフレームワーク
5. **下位概念 (Sub-component)**: この技術の一部として使われる
   - 例: LangChain → LCEL (LangChain Expression Language)

## 出力形式（JSON）
```json
{
  "target_technology": "{{technology_name}}",
  "category": "技術カテゴリ名",
  "description": "この技術が何をするものか（1文）",
  "mapping": {
    "direct_competitors": [
      {
        "name": "技術名",
        "description": "概要（1文）",
        "comparison": "{{technology_name}}との主な違い",
        "maturity": "production|beta|alpha|research",
        "momentum": "rising|stable|declining",
        "github_stars_approx": "概算スター数"
      }
    ],
    "alternative_approaches": [
      {
        "name": "技術/手法名",
        "description": "概要（1文）",
        "when_to_use": "こちらを選ぶべき場面"
      }
    ],
    "complementary": [
      {
        "name": "技術名",
        "description": "概要（1文）",
        "how_combined": "どう組み合わせるか"
      }
    ],
    "parent_category": "上位カテゴリ名",
    "sub_components": ["下位技術1", "下位技術2"]
  },
  "recommendation": "開発者へのアドバイス（2〜3文）"
}
```

重要:
- 各カテゴリに最低1つ、最大5つの技術を挙げること
- momentum（勢い）の判定は、GitHub活動、リリース頻度、コミュニティの活発さから判断
- 推測で存在しない技術を作り出さないこと
```

### 4.4 Slackメッセージフォーマット（Block Kit）

```json
{
  "blocks": [
    {
      "type": "header",
      "text": {
        "type": "plain_text",
        "text": "🗺️ 技術マップ: {{technology_name}}"
      }
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "カテゴリ: *{{category}}*\n{{description}}"
      }
    },
    {
      "type": "divider"
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*⚔️ 直接競合*\n{{#each direct_competitors}}• *{{name}}* {{momentum_emoji}} — {{comparison}}\n{{/each}}"
      }
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*🔄 代替アプローチ*\n{{#each alternative_approaches}}• *{{name}}* — {{when_to_use}}\n{{/each}}"
      }
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*🤝 補完技術*\n{{#each complementary}}• *{{name}}* — {{how_combined}}\n{{/each}}"
      }
    },
    {
      "type": "divider"
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*💡 推奨*\n{{recommendation}}"
      }
    },
    {
      "type": "context",
      "elements": [
        {
          "type": "mrkdwn",
          "text": "📈 rising | ➡️ stable | 📉 declining | 自動生成: {{timestamp}}"
        }
      ]
    }
  ]
}
```

---

## 5. ワークフロー間連携と全体アーキテクチャ

### 5.1 ワークフロー一覧

| No | ワークフロー名 | 起動方式 | 入力 | 出力先 |
|----|---------------|---------|------|--------|
| 0 | AInews_DeepResearch_Breadth（既存） | cron 月水金 | topic, depth | LINE |
| 1 | BreakingNews_Alert | cron 2時間ごと | なし | Slack → (2)(4)を条件起動 |
| 2 | Benchmark_Compare | (1)から呼び出し / 手動 | model_name, summary | Slack → (3)を連鎖起動 |
| 3 | TryItNow_Dashboard | (2)から呼び出し / 手動 | technology_name, type | Slack |
| 4 | Competitor_Map | (0)(1)から呼び出し / 手動 | technology_name, context | Slack |

### 5.2 連携フロー図

```
[cron 2h]                          [cron 月水金]
    |                                    |
    v                                    v
(1) BreakingNews_Alert         (0) AInews_DeepResearch_Breadth
    |                                    |
    +-- score >= 70?                     +-- 記事中の技術名を抽出
    |   |                                |
    |   +-- YES: Slack送信               +-- (4) Competitor_Map 呼び出し
    |   |   |                            |
    |   |   +-- category=model_release?  +-- LINE送信（既存）
    |   |       |
    |   |       +-- YES: (2) Benchmark_Compare
    |   |       |         |
    |   |       |         +-- (3) TryItNow_Dashboard
    |   |       |         +-- (4) Competitor_Map
    |   |       |
    |   |       +-- NO: (4) Competitor_Map
    |   |
    |   +-- NO: 何もしない（ログのみ）
```

### 5.3 Difyでの親子ワークフロー呼び出し方法

Difyでワークフロー間連携を実現する方法:

**方法A: HTTP Requestノードによる内部API呼び出し（推奨）**

```yaml
# ワークフロー(1)内のHTTP Requestノード設定
node:
  type: http-request
  title: ベンチマーク比較ワークフロー呼び出し
  method: POST
  url: "https://your-dify-instance/v1/workflows/run"
  headers:
    Authorization: "Bearer {{benchmark_workflow_api_key}}"
    Content-Type: "application/json"
  body:
    type: json
    data: |
      {
        "inputs": {
          "new_model_name": "{{extracted_model_name}}",
          "news_summary": "{{news_summary}}"
        },
        "response_mode": "blocking",
        "user": "breaking-news-trigger"
      }
  timeout:
    connect: 10
    read: 120
    write: 10
```

**方法B: Slack Webhookのみで独立動作**

各ワークフローが独立してSlackに送信し、ユーザーがSlackボタンから手動で次のワークフローを起動する。
自動化の度合いは下がるが、実装がシンプルで障害の影響が局所化される。

### 5.4 Slack Webhook設定

```yaml
# 環境変数（Difyまたは外部スケジューラで管理）
SLACK_WEBHOOK_BREAKING: "SET_IN_ENV"  # #breaking-news チャンネル
SLACK_WEBHOOK_BENCHMARK: "SET_IN_ENV" # #model-benchmarks チャンネル
SLACK_WEBHOOK_TRYIT:     "SET_IN_ENV" # #try-it-now チャンネル
SLACK_WEBHOOK_TECHMAP:   "SET_IN_ENV" # #tech-landscape チャンネル
```

---

## 6. コスト・運用見積もり

### 6.1 API呼び出し回数（1日あたり）

| ワークフロー | Tavily | LLM (Gemini Flash) | 備考 |
|-------------|--------|---------------------|------|
| BreakingNews (12回/日) | 12回 | 12回 | 大半は空振り（Slack送信なし） |
| Benchmark (推定0.5回/日) | 3回 | 3回 | モデルリリースは週1-2回程度 |
| TryItNow (推定0.5回/日) | 1.5回 | 0.5回 | Benchmarkと連動 |
| CompetitorMap (推定1回/日) | 3回 | 2回 | 定期配信 + Breaking連動 |
| **合計** | **約20回/日** | **約18回/日** | |

### 6.2 月額コスト概算

- Tavily: 約600回/月 (無料枠1000回/月に収まる可能性あり)
- Gemini Flash: 約540回/月 (無料枠内で十分賄える)
- Slack Webhook: 無料

**追加コスト: ほぼゼロ** （既存の無料枠内で運用可能）

---

## 7. 実装優先度

| 優先度 | ワークフロー | 理由 |
|--------|-------------|------|
| **P0** | BreakingNews_Alert | 最もインパクトが高い。これだけで「見逃し」問題を大幅に改善 |
| **P1** | Competitor_Map | 実装がシンプル（LLM1回 + 検索数回）で、定期配信にも付加価値を出せる |
| **P2** | Benchmark_Compare | モデルリリース時の価値は高いが、発生頻度が低い |
| **P3** | TryItNow_Dashboard | Benchmark_Compareの後段として自然に追加可能 |

### 推奨実装順序

1. **Week 1**: BreakingNews_Alert を構築・テスト
2. **Week 2**: Competitor_Map を構築し、既存ワークフローと連携
3. **Week 3**: Benchmark_Compare を構築
4. **Week 4**: TryItNow_Dashboard を追加し、全体統合テスト
