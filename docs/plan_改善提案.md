# Plan.md 問題点分析と改善提案

## 🔍 発見された問題点

### 【重大】問題1: 未定義変数の参照
**問題**: `findings_count` がプロンプトで使用されているが、定義・更新されていない

**影響**: 実行時エラーまたは不正な値の参照

**該当箇所**: 
- 3-1. LLM: 検索計画立案のプロンプト（132行目）
- `{{#conversation.findings_count#}}` が参照されているが、どこでも定義・更新されていない

---

### 【重要】問題2: Conversation Variablesの定義不足
**問題**: Conversation Variablesの定義セクションが完全に欠落している

**影響**: 
- `topics`, `findings`, `nextSearchTopic`, `shouldContinue` が使用できない
- ワークフローが正常に動作しない

**該当箇所**: セクション4が「(変更なし)」と記載されているが、実際の定義がない

---

### 【重要】問題3: エラーハンドリングの不備
**問題**: 
- Tavily Searchが失敗した場合の処理が不明確
- JSON Parseが失敗した場合の処理がない
- shouldContinueがfalseの場合でもVariable Assignerが実行される可能性

**影響**: エラー時にワークフローが予期しない動作をする

**該当箇所**: 
- 3-3. Tool: Tavily Search（155行目）にエラーハンドリングの記載なし
- 3-4. Variable Assigner（157-172行目）で、shouldContinueがfalseの場合の処理が不明確

---

### 【重要】問題4: メッセージ分割ロジックの不備
**問題**: 
- カテゴリ境界で分割していない（中途半端な位置で切れる可能性）
- part2が空の場合でもLINE整形LLM2が実行される
- 3つ以上の分割が必要な場合に対応していない

**影響**: 
- 読みにくいメッセージ分割
- 無駄なLLM呼び出し
- 長文レポートでエラー

**該当箇所**: 5. Code: LINEメッセージ分割（182-228行目）

---

### 【中】問題5: コンテキストウィンドウ対策が不十分
**問題**: 
- `findings` が肥大化した場合の対策が「必要に応じて追加」という曖昧な記載のみ
- 具体的な実装方針がない

**影響**: 大量の検索結果でマスターレポート作成LLMが失敗する可能性

**該当箇所**: 注意事項2（305-307行目）

---

### 【中】問題6: 8カテゴリのカバー状況評価がない
**問題**: 
- 検索計画立案LLMが8カテゴリのカバー状況を評価するロジックがない
- `findings` の全文ではなく件数のみを参照しているため、どのカテゴリが不足しているか判断できない

**影響**: 8カテゴリを網羅的にカバーできない可能性

**該当箇所**: 3-1. LLM: 検索計画立案（118-147行目）

---

### 【中】問題7: shouldContinue判定の不安定性
**問題**: 
- shouldContinueの判定が完全にLLM任せ
- 客観的な終了条件（例: 全カテゴリ3件以上）がない

**影響**: 早期終了または無駄な検索が発生する可能性

**該当箇所**: 3-1. LLM: 検索計画立案（141-146行目）

---

### 【軽微】問題8: 実行時間の見積もりが楽観的
**問題**: 
- 1回の検索30秒×3回=1.5分という見積もり
- LLM呼び出し時間（検索計画立案、JSON Parse、マスターレポート作成、LINE整形）が考慮されていない

**影響**: 実際の実行時間が想定より長くなる可能性

**該当箇所**: 注意事項1（301-303行目）

---

### 【軽微】問題9: マスターレポートの品質保証がない
**問題**: 
- マスターレポート作成LLMのプロンプトが「(変更なし)」と記載されているが、実際の内容がない
- 重複排除、信憑性評価、日付確認などの具体的な指示がない

**影響**: レポート品質が不安定

**該当箇所**: 4. LLM: マスターレポート作成（176-178行目）

---

### 【軽微】問題10: LINE送信の条件分岐がない
**問題**: 
- part2が空の場合でもLINE送信2が実行される
- 無駄なHTTPリクエストが発生する可能性

**影響**: コストの無駄、エラーの可能性

**該当箇所**: 7. HTTP Request: LINE送信（254-256行目）

---

## 🎯 改善提案（推奨度順）

### 【推奨度: ⭐⭐⭐⭐⭐】改善案1: Conversation Variablesの定義追加

#### 概要
Conversation Variablesの定義セクションを追加し、`findings_count` も含めて適切に管理する

#### 実装内容
```yaml
conversation_variables:
  - id: topics-var
    name: topics
    value_type: array[string]
    value: []
    description: 調査済みトピックのリスト
  
  - id: nextSearchTopic-var
    name: nextSearchTopic
    value_type: string
    value: ''
    description: 次に検索するキーワード
  
  - id: findings-var
    name: findings
    value_type: array[string]
    value: []
    description: 調査結果（事実）の蓄積リスト
  
  - id: shouldContinue-var
    name: shouldContinue
    value_type: string
    value: 'true'
    description: 調査を継続するか否か
  
  - id: findings_count-var
    name: findings_count
    value_type: number
    value: 0
    description: 調査済み件数
```

#### 推奨理由
✅ **必須**: ワークフローが正常に動作するために不可欠  
✅ **即座に実装可能**: 定義を追加するだけ  
✅ **影響範囲が明確**: 他の部分への影響が少ない

---

### 【推奨度: ⭐⭐⭐⭐⭐】改善案2: エラーハンドリングの強化

#### 概要
Tavily Search失敗時、JSON Parse失敗時、shouldContinue判定時のエラーハンドリングを明確化

#### 実装内容

**A. Tavily Search失敗時の処理**
```yaml
# IF/ELSEノードを追加: Tavily Search成功/失敗を判定
# 失敗時は空文字列をfindingsに追加し、エラーログを記録
```

**B. JSON Parse失敗時の処理**
```yaml
# JSON Parseの前にCodeノードでJSON検証
# 失敗時はデフォルト値（nextSearchTopic: "", shouldContinue: false）を設定
```

**C. shouldContinue判定の改善**
```yaml
# Variable Assignerで、shouldContinueがfalseの場合は
# Tavily Searchの結果を追加しない（Skip Searchパスを明確化）
```

#### 推奨理由
✅ **堅牢性向上**: エラー時にワークフローが予期しない動作をしない  
✅ **デバッグ容易**: エラー原因の特定が容易  
✅ **ユーザー体験**: 部分的な失敗でも処理を継続できる

---

### 【推奨度: ⭐⭐⭐⭐】改善案3: メッセージ分割ロジックの改善

#### 概要
カテゴリ境界で分割し、part2が空の場合は処理をスキップ

#### 実装内容

**改善された分割ロジック**:
```python
def main(master_report: str) -> dict:
    MAX_LENGTH = 3500
    
    if len(master_report) <= MAX_LENGTH:
        return {
            "part1": master_report,
            "part2": "",
            "has_part2": False
        }
    
    # カテゴリ見出し（## で始まる行）を探す
    lines = master_report.split('\n')
    category_headings = []
    for i, line in enumerate(lines):
        if line.strip().startswith('## '):
            category_headings.append(i)
    
    # 最初の分割点を探す（カテゴリ境界で分割）
    part1_lines = []
    part2_lines = []
    current_length = 0
    split_index = 0
    
    for i, heading_idx in enumerate(category_headings):
        # この見出しまでの文字数を計算
        section_length = sum(len(lines[j]) + 1 for j in range(
            category_headings[i-1] if i > 0 else 0, 
            heading_idx
        ))
        
        if current_length + section_length > MAX_LENGTH and i > 0:
            # 前のカテゴリ境界で分割
            split_index = category_headings[i-1]
            break
        current_length += section_length
    
    if split_index == 0:
        # 分割不要
        return {
            "part1": master_report,
            "part2": "",
            "has_part2": False
        }
    
    part1_lines = lines[:split_index]
    part2_lines = lines[split_index:]
    
    return {
        "part1": "\n".join(part1_lines),
        "part2": "\n".join(part2_lines),
        "has_part2": True
    }
```

**IF/ELSEノードでpart2の有無を判定**:
```yaml
# has_part2がfalseの場合、LINE整形LLM2とLINE送信2をスキップ
```

#### 推奨理由
✅ **品質向上**: カテゴリ境界で分割することで読みやすさが向上  
✅ **コスト削減**: 不要なLLM呼び出しを回避  
✅ **エラー回避**: 空のpart2によるエラーを防止

---

### 【推奨度: ⭐⭐⭐⭐】改善案4: 8カテゴリカバー状況の評価機能追加

#### 概要
Codeノードでカテゴリ別の情報量をカウントし、LLMに渡す

#### 実装内容

**A. カテゴリ別カウントCodeノード**:
```python
def main(findings: list[str]) -> dict:
    """
    findingsを分析してカテゴリ別の情報量をカウント
    """
    category_keywords = {
        "llm": ["大規模言語モデル", "LLM", "foundation model", "基盤モデル", "GPT", "Gemini", "Claude"],
        "business": ["ビジネス", "企業", "business", "enterprise", "投資", "資金調達"],
        "research": ["研究", "research", "技術革新", "innovation", "論文", "paper"],
        "regulation": ["規制", "政策", "regulation", "policy", "法律", "law"],
        "creative": ["クリエイティブ", "creative", "画像生成", "動画生成", "DALL-E", "Midjourney"],
        "implementation": ["実用化", "導入", "implementation", "deployment", "採用", "adoption"],
        "risk": ["リスク", "倫理", "risk", "ethics", "安全性", "safety"],
        "future": ["未来", "展望", "future", "outlook", "予測", "prediction"]
    }
    
    category_counts = {key: 0 for key in category_keywords.keys()}
    
    for finding in findings:
        finding_lower = finding.lower()
        for category, keywords in category_keywords.items():
            if any(keyword.lower() in finding_lower for keyword in keywords):
                category_counts[category] += 1
                break  # 1つのニュースは1つのカテゴリにのみカウント
    
    return {
        "category_counts": category_counts,
        "total_count": len(findings)
    }
```

**B. 検索計画立案LLMのプロンプト改善**:
```yaml
## カテゴリカバー状況
{{#category_counter.category_counts#}}

- 十分（3件以上）: 優先度を下げる
- 不足（0-2件）: 優先的に調査
```

#### 推奨理由
✅ **網羅性向上**: 8カテゴリを確実にカバー  
✅ **効率性向上**: 不足カテゴリを優先的に調査  
✅ **客観性**: LLMの主観的判断に頼らない

---

### 【推奨度: ⭐⭐⭐】改善案5: コンテキストウィンドウ対策の実装

#### 概要
`findings` が肥大化した場合に、Codeノードで要約処理を実行

#### 実装内容

**A. findings要約Codeノード**:
```python
def main(findings: list[str], max_items: int = 50) -> dict:
    """
    findingsが多すぎる場合、最新のものと重要度の高いものを残す
    """
    if len(findings) <= max_items:
        return {
            "summarized_findings": findings,
            "was_summarized": False
        }
    
    # 最新のmax_items件を残す（簡易実装）
    # より高度な実装: 重要度スコアを計算して上位を残す
    summarized = findings[-max_items:]
    
    return {
        "summarized_findings": summarized,
        "was_summarized": True,
        "original_count": len(findings),
        "summarized_count": len(summarized)
    }
```

**B. フローに組み込み**:
```
Iteration → findings要約Code → マスターレポート作成LLM
```

#### 推奨理由
✅ **安定性**: トークン上限エラーを回避  
✅ **柔軟性**: findingsの量に応じて自動調整  
⚠️ **注意**: 要約により情報が失われる可能性

---

### 【推奨度: ⭐⭐⭐】改善案6: shouldContinue判定の客観化

#### 概要
Codeノードで客観的な終了条件をチェックし、LLMの判断を補完

#### 実装内容

**A. 終了条件チェックCodeノード**:
```python
def main(
    category_counts: dict,
    shouldContinue_llm: str,
    iteration_count: int,
    max_iterations: int = 5
) -> dict:
    """
    客観的な終了条件をチェック
    """
    # 全カテゴリが3件以上あるか
    all_sufficient = all(count >= 3 for count in category_counts.values())
    
    # イテレーション回数が上限に達したか
    reached_max = iteration_count >= max_iterations
    
    # LLMの判断
    llm_says_continue = shouldContinue_llm.lower() == 'true'
    
    # 最終判断
    if all_sufficient or reached_max:
        final_shouldContinue = False
        reason = "全カテゴリ充足" if all_sufficient else "最大イテレーション数到達"
    else:
        final_shouldContinue = llm_says_continue
        reason = "LLM判断"
    
    return {
        "shouldContinue": str(final_shouldContinue).lower(),
        "reason": reason
    }
```

**B. フローに組み込み**:
```
LLM判断 → 終了条件チェックCode → IF/ELSE
```

#### 推奨理由
✅ **安定性**: LLMの不安定な判断を補完  
✅ **効率性**: 無駄な検索を回避  
⚠️ **注意**: 実装がやや複雑になる

---

### 【推奨度: ⭐⭐】改善案7: マスターレポート作成プロンプトの詳細化

#### 概要
マスターレポート作成LLMのプロンプトを詳細に記載

#### 実装内容
```yaml
system:
  text: |
    あなたはAIニュースの「編集長」です。
    取材班が集めた大量の検索結果（findings）に基づき、今週のAIニュースの「マスターレポート」を作成してください。

    ## 入力データ
    {{#conversation.findings#}}

    ## 思考プロセス（Thinking）
    1. **重複排除**: 同じニュースが複数回出現している場合は統合してください。
    2. **信憑性評価**: 
       - 信頼できる情報源（公式発表、主要メディア）を優先
       - 推測や噂レベルのものは除外するか、「噂レベル」と明記
    3. **日付確認**: 指定期間（{{#code_node.date_range#}}）外の古いニュースは除外してください。
    4. **重要度評価**: 業界への影響度が高いニュースを優先的に記載してください。
    5. **カテゴリ分類**: 各ニュースを8つのカテゴリに分類してください。

    ## 出力要件
    - 以下の8つのカテゴリに分類して記述してください。
      [大規模言語モデル, ビジネス, 研究, 規制, クリエイティブ, 実用化, リスク, 未来]
    - 各ニュースには必ず「具体的な数値」「固有名詞」「日付」を含めてください。
    - 文体は「だ・である」調で、客観的な事実を中心に記述してください。
    - マークダウン形式で出力してください。
    - 各カテゴリごとに見出しを付けてください。
```

#### 推奨理由
✅ **品質向上**: 明確な指示によりレポート品質が向上  
✅ **一貫性**: 毎回同じ基準でレポート作成  
⚠️ **注意**: プロンプトが長くなる

---

### 【推奨度: ⭐⭐】改善案8: 実行時間見積もりの修正

#### 概要
より現実的な実行時間見積もりを記載

#### 実装内容
```
実行時間の内訳:
- 検索計画立案LLM: 10秒 × 3回 = 30秒
- JSON Parse: 2秒 × 3回 = 6秒
- Tavily Search: 30秒 × 3回 = 90秒
- 変数更新: 1秒 × 3回 = 3秒
- マスターレポート作成LLM: 60秒
- メッセージ分割Code: 1秒
- LINE整形LLM: 20秒 × 2回 = 40秒
- LINE送信: 5秒 × 2回 = 10秒
合計: 約4-5分（最悪ケース: 8-10分）
```

#### 推奨理由
✅ **正確性**: より現実的な見積もり  
✅ **計画性**: タイムアウト設定の根拠  
⚠️ **注意**: 環境によって変動する可能性

---

## 📊 改善案の優先順位まとめ

### 最優先（即座に実装必須）
1. **改善案1**: Conversation Variablesの定義追加
2. **改善案2**: エラーハンドリングの強化

### 高優先（品質・安定性向上）
3. **改善案3**: メッセージ分割ロジックの改善
4. **改善案4**: 8カテゴリカバー状況の評価機能追加

### 中優先（最適化・改善）
5. **改善案5**: コンテキストウィンドウ対策の実装
6. **改善案6**: shouldContinue判定の客観化
7. **改善案7**: マスターレポート作成プロンプトの詳細化

### 低優先（ドキュメント改善）
8. **改善案8**: 実行時間見積もりの修正

---

## 🎯 推奨実装順序

### Phase 1: 必須修正（1-2日）
1. Conversation Variablesの定義追加
2. エラーハンドリングの基本実装
3. マスターレポート作成プロンプトの詳細化

### Phase 2: 品質向上（2-3日）
4. メッセージ分割ロジックの改善
5. 8カテゴリカバー状況の評価機能追加
6. LINE送信の条件分岐追加

### Phase 3: 最適化（1-2日）
7. コンテキストウィンドウ対策の実装
8. shouldContinue判定の客観化
9. 実行時間見積もりの修正

---

## ⚠️ 注意事項

1. **段階的実装**: 一度に全てを実装せず、Phaseごとにテストを実施
2. **後方互換性**: 既存の動作に影響を与えないよう注意
3. **パフォーマンス**: 追加したCodeノードが実行時間に与える影響を測定
4. **テスト**: 各改善案を実装後、必ずテストを実施

---

**作成日**: 2024年1月
**バージョン**: 1.0





