#!/usr/bin/env python3
import argparse, csv, datetime, os, platform, socket, subprocess, time, json
import psutil

# === HW情報取得 ===
def get_hw_info():
    cpu_model = platform.processor() or platform.machine()
    return {
        "cpu_model": cpu_model,
        "cpu_cores": psutil.cpu_count(logical=False),
        "cpu_threads": psutil.cpu_count(logical=True),
        "cpu_freq_MHz": psutil.cpu_freq().max if psutil.cpu_freq() else None,
        "mem_total_MB": psutil.virtual_memory().total // (1024**2),
        "swap_total_MB": psutil.swap_memory().total // (1024**2),
    }

# === CPU温度取得 (Raspberry Pi のみ) ===
def get_cpu_temp():
    if platform.system() == "Linux":
        try:
            with open("/sys/class/thermal/thermal_zone0/temp") as f:
                return float(f.read().strip())/1000
        except:
            return None
    return None  # macOSは未対応

# === モデルサイズ取得 (ollama list パース) ===
def get_model_size_bytes(model_name):
    try:
        out = subprocess.check_output(["ollama", "list"], text=True)
        for line in out.splitlines():
            if line.startswith(model_name):
                parts = line.split()
                if len(parts) >= 4:
                    size_str, unit = parts[2], parts[3]
                    num = float(size_str)
                    unit = unit.upper()
                    if unit.startswith("KB"):
                        return int(num * 1024)
                    elif unit.startswith("MB"):
                        return int(num * 1024**2)
                    elif unit.startswith("GB"):
                        return int(num * 1024**3)
                    elif unit.startswith("TB"):
                        return int(num * 1024**4)
                    else:
                        return int(num)
    except Exception:
        return None
    return None

# === 指定モデルがpull済みか確認 ===
def check_model_exists(model):
    try:
        out = subprocess.check_output(["ollama", "list"], text=True)
        if not any(line.startswith(model) for line in out.splitlines()):
            print(f"モデル '{model}' は pull されていません。")
            print("先に `ollama pull {}` を実行してください。".format(model))
            exit(1)
    except Exception as e:
        print("`ollama list` の実行に失敗しました。ollama がインストールされているか確認してください。")
        print(e)
        exit(1)

# === ollama serve プロセスを特定 ===
def find_ollama_proc():
    candidates = []
    for p in psutil.process_iter(attrs=["pid", "name", "cmdline"]):
        try:
            name = (p.info.get("name") or "").lower()
            cmd = " ".join(p.info.get("cmdline") or []).lower()
            if "ollama" in name or "ollama" in cmd:
                if "serve" in cmd or name == "ollama":
                    candidates.append(p)
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue
    if not candidates:
        return None
    # CPU使用率が高いものを優先（ヒューリスティック）
    best = None
    best_cpu = -1.0
    for p in candidates:
        try:
            c = p.cpu_percent(interval=0.0)
            if c > best_cpu:
                best_cpu = c
                best = p
        except psutil.NoSuchProcess:
            continue
    return best or candidates[0]

# === 子プロセスを含めたCPU/メモリ使用量 ===
def sample_resources(root_proc, prime=False):
    if root_proc is None:
        return 0.0, 0
    try:
        procs = [root_proc] + root_proc.children(recursive=True)
        cpu = 0.0
        mem = 0
        for p in procs:
            if not p.is_running():
                continue
            try:
                # 最初のプライミング呼び出しでは基準化だけ行う
                if prime:
                    _ = p.cpu_percent(None)
                    continue
                cpu += p.cpu_percent(None)
                mem += p.memory_info().rss
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                continue
        if prime:
            return 0.0, 0
        return cpu, mem // (1024**2)
    except psutil.NoSuchProcess:
        return 0.0, 0

# === /api/generate を curl -N でストリーム読取し、正確に時刻を取得 ===
def run_prompt_via_api(model, prompt):
    # curl コマンドを使ってストリーミングJSONを1行ずつ取得
    url = "http://127.0.0.1:11434/api/generate"
    payload = json.dumps({"model": model, "prompt": prompt, "stream": True})
    cmd = ["curl", "-sS", "-N", "-H", "Content-Type: application/json", "-d", payload, url]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)

    # 監視対象は ollama serve
    ollama_proc = find_ollama_proc()
    # プライミング
    _ = sample_resources(ollama_proc, prime=True)

    cpu_samples, mem_samples, temp_samples = [], [], []

    t_start = time.time()
    first_token_time = None
    last_token_time = None
    response_text = []
    eval_count = None
    eval_duration_ns = None  # API が返す場合あり

    # 行単位でJSONチャンクを読む
    for line in iter(proc.stdout.readline, ''):
        now = time.time()
        line = line.strip()
        if not line:
            # リソースはサンプリングし続ける
            cpu, mem = sample_resources(ollama_proc)
            cpu_samples.append(cpu)
            mem_samples.append(mem)
            t = get_cpu_temp()
            if t is not None:
                temp_samples.append(t)
            continue

        try:
            data = json.loads(line)
        except json.JSONDecodeError:
            # JSONでない出力は無視
            cpu, mem = sample_resources(ollama_proc)
            cpu_samples.append(cpu)
            mem_samples.append(mem)
            t = get_cpu_temp()
            if t is not None:
                temp_samples.append(t)
            continue

        # 最初のトークン検出
        chunk = data.get("response", "")
        if chunk:
            if first_token_time is None:
                first_token_time = now
            last_token_time = now
            response_text.append(chunk)

        # 進捗中もリソースを採取
        cpu, mem = sample_resources(ollama_proc)
        cpu_samples.append(cpu)
        mem_samples.append(mem)
        t = get_cpu_temp()
        if t is not None:
            temp_samples.append(t)

        # 最終チャンク
        if data.get("done"):
            eval_count = data.get("eval_count", None)
            eval_duration_ns = data.get("eval_duration", None)
            break

    proc.stdout.close()
    proc.wait()
    _out, _err = proc.communicate()

    t_end = time.time()

    # 時間算出
    thinking_time = (first_token_time - t_start) if first_token_time else None
    if first_token_time and last_token_time:
        generation_time = max(0.0, last_token_time - first_token_time)
    else:
        generation_time = t_end - t_start  # フォールバック

    # 応答
    resp_text = "".join(response_text)

    # トークン統計（APIで返っていればそれを優先）
    if eval_count is not None and eval_duration_ns:
        tokens_generated = int(eval_count)
        # eval_duration はナノ秒のことが多いので秒に変換
        gen_time_for_rate = max(generation_time, eval_duration_ns / 1e9)
        tokens_per_sec = tokens_generated / max(gen_time_for_rate, 0.5)
    else:
        tokens_generated = len(resp_text)  # 文字数換算
        tokens_per_sec = tokens_generated / max(generation_time, 0.5)

    return {
        "thinking_time": thinking_time,
        "generation_time": generation_time,
        "response_text": resp_text,
        "tokens_generated": tokens_generated,
        "tokens_per_sec": tokens_per_sec,
        "cpu_percent_avg": (sum(cpu_samples)/len(cpu_samples)) if cpu_samples else None,
        "cpu_percent_max": (max(cpu_samples) if cpu_samples else None),
        "mem_MB": (max(mem_samples) if mem_samples else None),
        "cpu_temp_avg": (sum(temp_samples)/len(temp_samples)) if temp_samples else None,
        "cpu_temp_max": (max(temp_samples) if temp_samples else None),
    }

# === メインの1試行 ===
def run_prompt(model, prompt, phase, run_id, hwinfo):
    start_time = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    api_result = run_prompt_via_api(model, prompt)

    return {
        "timestamp": start_time,
        "hostname": socket.gethostname(),
        "phase": phase,
        "model_name": model,
        "model_size_bytes": get_model_size_bytes(model),
        "prompt": prompt,
        "run_id": run_id,
        "thinking_time": api_result["thinking_time"],
        "generation_time": api_result["generation_time"],
        "tokens_generated": api_result["tokens_generated"],
        "tokens_per_sec": api_result["tokens_per_sec"],
        "cpu_percent_avg": api_result["cpu_percent_avg"],
        "cpu_percent_max": api_result["cpu_percent_max"],
        "mem_MB": api_result["mem_MB"],
        "cpu_temp_avg": api_result["cpu_temp_avg"],
        "cpu_temp_max": api_result["cpu_temp_max"],
        "num_threads": os.getenv("OLLAMA_NUM_THREADS", "unset"),
        "keep_alive": os.getenv("OLLAMA_KEEP_ALIVE", "unset"),
        "exit_code": 0,
        "response_text": api_result["response_text"],
        **hwinfo
    }

# === エントリポイント ===
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, help="Model name (e.g. llama2:7b)")
    parser.add_argument("--prompts", required=True, help="Prompt file path")
    parser.add_argument("--runs", type=int, default=1, help="Number of runs (max 5)")
    parser.add_argument("--coldish", action="store_true", help="Treat first run as cold-ish instead of cold")
    args = parser.parse_args()

    # 事前チェック
    check_model_exists(args.model)

    # CSVファイル名
    hwinfo = get_hw_info()
    ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    outfile = f"{socket.gethostname()}_ollama_benchmark_{ts}.csv"

    # CSV書き込み
    with open(outfile, "w", newline="", encoding="utf-8-sig") as f:
        writer = csv.DictWriter(f, fieldnames=[
            "timestamp","hostname","phase","model_name","model_size_bytes","prompt","run_id",
            "thinking_time","generation_time","tokens_generated","tokens_per_sec",
            "cpu_percent_avg","cpu_percent_max","mem_MB","cpu_temp_avg","cpu_temp_max",
            "num_threads","keep_alive","exit_code","response_text",
            "cpu_model","cpu_cores","cpu_threads","cpu_freq_MHz","mem_total_MB","swap_total_MB"
        ])
        writer.writeheader()

        with open(args.prompts, encoding="utf-8") as pf:
            for prompt in pf:
                prompt = prompt.strip()
                if not prompt:
                    continue
                for run_id in range(1, min(5, max(1, args.runs)) + 1):
                    if run_id == 1:
                        phase = "cold-ish" if args.coldish else "cold"
                    else:
                        phase = "warm"
                    result = run_prompt(args.model, prompt, phase, run_id, hwinfo)
                    writer.writerow(result)

    print(f"結果を {outfile} に保存しました (UTF-8 BOM付き)")

if __name__ == "__main__":
    main()
