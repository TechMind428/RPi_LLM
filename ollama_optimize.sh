#!/bin/bash

echo "=========================================="
echo " Ollama サービス設定の最適化"
echo "=========================================="

# Ollama設定ディレクトリ作成
echo ">>> Ollama設定ディレクトリ作成..."
sudo mkdir -p /etc/systemd/system/ollama.service.d

# 設定ファイル作成
echo ">>> Ollama環境変数設定..."
sudo tee /etc/systemd/system/ollama.service.d/override.conf <<'EOF'
[Service]
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_KEEP_ALIVE=30s"
Environment="OLLAMA_NUM_THREADS=4"
EOF

# 設定反映
echo ">>> 設定反映中..."
sudo systemctl daemon-reload
sudo systemctl restart ollama

# 設定確認
echo ""
echo ">>> 設定確認..."
systemctl show ollama | grep Environment

echo ""
echo "✓ Ollama設定の最適化完了"
echo ""
echo "設定内容:"
echo "  - 並列処理数: 1"
echo "  - 最大ロードモデル数: 1"
echo "  - モデル保持時間: 30秒"
echo "  - スレッド数: 4"
