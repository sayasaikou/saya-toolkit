# comfy-pipeline —— ComfyUI 本地出图流水线（多底模 + 随机场景）

给 **ComfyUI** 加一层更适合"批量出图 + 自己筛"的命令行外壳。

## 文件

| 文件 | 作用 |
| --- | --- |
| `comfygen.py` | 出图主工具：`--family flux\|illustrious\|anima`、`--batch`、`--prompt`、`--out`；输出 TSV「秒/张 + 路径」便于上层批量筛图 |
| `promptbox.py` | 随机提示词生成器：按角色档案 + **场景池**（时间/天气/地点/氛围/光照/镜头/动作/神态）组合，**避免"白底站姿"** |
| `promptbox-pools.json` | 场景池。每条都写两套语法：`natural`（给 Anima/Flux 这类自然语言模型）与 `tags`（给 Illustrious 这类 tag 模型） |

## 用法

```bash
# 单张
python comfygen.py --family illustrious --prompt "1girl, ..." --out out/

# 批量抽卡（同一提示词 N 张，输出 TSV 便于筛）
python comfygen.py --family anima --prompt-file p.txt --batch 8 --out out/test

# 按角色随机场景
python promptbox.py --character saya --count 10 --seed 42 --family illustrious
```

## 三条踩出来的经验

1. **引擎参数是最大杠杆**：同一角色/场景/种子只换引擎 —— 快模型 8 步约 7.8 分、慢模型 28 步约 9.0 分（发丝、耳饰、纽扣这类细节才出来）。
   **抽卡档只适合探路，给人看的东西必须用质量档。**
2. **"模型不认识的角色"靠文字掰不出来**：没有 LoRA 之前，冷门角色基本是"猜"；先解决"认识角色"（参考图 → 精确档案 → LoRA），再做批量。
3. **`--disable-pinned-memory --disable-async-offload`**：某些 ComfyUI 版本的新内存快速路径会直接崩进程，这两个开关绕开它（写进启动配置里最稳）。

## 依赖

- 本仓**不带模型权重**（各自遵循其原始许可，自行下载）；
- ComfyUI 本体、Python 3.10+、`requests`。

## License

MIT（脚本原创；模型与素材的许可请自行确认）。
