#!/bin/bash
#
# model_pull.sh (REST /api/pull streaming JSON 版)
# - 端末出力を解析せず、Ollama REST API の JSON ストリームでステージを検出
# - ミリ秒精度、コメント/空行スキップ、ホスト名付きCSV、プロジェクト直下にログ保存
#
# ステージ定義:
# 1) manifest : "pulling manifest" を初めて観測
# 2) download : 最初の "pulling <layer> ... %"（= JSON上は status が layerごとの pulling に変わる）〜 "verifying sha256 digest"
#                ※実装簡略化のため「manifest観測直後から verify 観測直前まで」を download とする
# 3) verify   : "verifying sha256 digest" 観測 〜 "writing manifest"
# 4) write    : "writing manifest" 観測 〜 "success"
# 5) complete : "success" 観測 〜 APIレスポンス終了
#
# CSV: host,model,manifest,download,verify,write,complete,total,sum,check
# check は total と sum の誤差が 0.1s 以内なら OK
#

set -e

HOSTNAME=$(hostname)
CSV_FILE="${HOSTNAME}_models.csv"

# ---- 秒.ナノ秒（mac は gdate があれば使用）----
now() {
  if date +%s.%N >/dev/null 2>&1; then
    date +%s.%N
  elif command -v gdate >/dev/null 2>&1; then
    gdate +%s.%N
  else
    date +%s | awk '{printf "%s.000\n",$1}'
  fi
}

elapsed() {
  awk -v s="$1" -v e="$2" 'BEGIN{printf "%.3f", e - s}'
}

# ---- CSV ヘッダ ----
if [ ! -f "$CSV_FILE" ]; then
  echo "host,model,manifest,download,verify,write,complete,total,sum,check" > "$CSV_FILE"
fi

# ---- 1行ずつ models.txt を処理 ----
while IFS= read -r MODEL; do
  # 空行/コメントスキップ
  [ -z "$MODEL" ] && continue
  case "$MODEL" in \#*) continue ;; esac

  echo ">>> pulling $MODEL (via REST /api/pull)"

  # ログ（プロジェクト直下）
  MODEL_SAFE=$(echo "$MODEL" | tr '/: |' '____')
  TS=$(date +%Y%m%d_%H%M%S)
  RAWLOG="$PWD/raw_${MODEL_SAFE}_${TS}.jsonl"   # APIのJSONストリームそのまま
  STATEFILE="$PWD/state_${MODEL_SAFE}_${TS}.env"

  echo "RAWLOG:    $RAWLOG"
  echo "STATEFILE: $STATEFILE"

  # タイムスタンプ初期化
  START_TIME=$(now)
  {
    echo "t_start=$START_TIME"
    echo "t_manifest="
    echo "t_verify="
    echo "t_write="
    echo "t_success="
  } > "$STATEFILE"

  # --- REST API で pull をストリーミング受信 ---
  # mac/Linux 共通。curl は -N/--no-buffer で行バッファを抑制し逐次取得。
  # stream:true で JSON 行が逐次届く。stderrは不要なので2>/dev/null。
  # 受信した各行を RAWLOG に保存しつつ、status によって時刻を打つ。
  set +e
  curl -sS -N -H "Content-Type: application/json" \
    -d "$(printf '{"model":"%s","stream":true}' "$MODEL")" \
    http://localhost:11434/api/pull 2>/dev/null \
    | tee -a "$RAWLOG" \
    | while IFS= read -r line; do
        # ざっくりJSON抽出（jq不要）。"status":"...” を取り出す
        # 行に status が無ければスキップ（progress-only 行対策）
        case "$line" in
          *'"status":'*)
            status=$(printf "%s" "$line" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
            # 空なら無視
            [ -z "$status" ] && continue

            # 状態に応じて最初の観測時刻を記録
            case "$status" in
              pulling\ manifest*)
                # manifest 観測（最初だけ）
                if ! grep -q '^t_manifest=[0-9]' "$STATEFILE"; then
                  printf 't_manifest=%s\n' "$(now)" >> "$STATEFILE"
                fi
                ;;
              verifying\ sha256\ digest*)
                if ! grep -q '^t_verify=[0-9]' "$STATEFILE"; then
                  printf 't_verify=%s\n' "$(now)" >> "$STATEFILE"
                fi
                ;;
              writing\ manifest*)
                if ! grep -q '^t_write=[0-9]' "$STATEFILE"; then
                  printf 't_write=%s\n' "$(now)" >> "$STATEFILE"
                fi
                ;;
              success*)
                if ! grep -q '^t_success=[0-9]' "$STATEFILE"; then
                  printf 't_success=%s\n' "$(now)" >> "$STATEFILE"
                fi
                ;;
              *)
                # 例: pulling <digest> / progress 行などは download 区間として扱うので個別処理不要
                :
                ;;
            esac
            ;;
          *) : ;;  # status が無い行はスキップ
        esac
      done
  set -e

  END_TIME=$(now)

  # 記録読み込み
  # shellcheck disable=SC1090
  . "$STATEFILE"

  # フォールバック（見逃し時）
  # - manifest が無い → start を manifest に
  # - verify が無い → write or success 直前を verify に（= verify 0）
  # - write が無い → success 直前を write に（= write 0）
  # - success が無い → END_TIME を success に（異常系）
  : "${t_manifest:=$t_start}"
  : "${t_verify:=${t_write:-${t_success:-$END_TIME}}}"
  : "${t_write:=${t_success:-$t_verify}}"
  : "${t_success:=$END_TIME}"

  # 時間算出（秒.ミリ秒）
  manifest_time=$(elapsed "$t_start"    "$t_manifest")
  download_time=$(elapsed "$t_manifest" "$t_verify")
  verify_time=$(elapsed   "$t_verify"   "$t_write")
  write_time=$(elapsed    "$t_write"    "$t_success")
  complete_time=$(elapsed "$t_success"  "$END_TIME")
  total_time=$(elapsed    "$t_start"    "$END_TIME")

  sum_stage=$(awk -v m="$manifest_time" -v d="$download_time" -v v="$verify_time" -v w="$write_time" -v c="$complete_time" \
              'BEGIN{printf "%.3f", m+d+v+w+c}')

  # 誤差 ±0.1s 許容
  diff=$(awk -v t="$total_time" -v s="$sum_stage" 'BEGIN{d=t-s; if(d<0)d=-d; printf "%.3f", d}')
  if awk -v d="$diff" 'BEGIN{exit(d>0.1)}'; then check="OK"; else check="NG"; fi

  echo "$HOSTNAME,$MODEL,$manifest_time,$download_time,$verify_time,$write_time,$complete_time,$total_time,$sum_stage,$check" >> "$CSV_FILE"

done < models.txt

