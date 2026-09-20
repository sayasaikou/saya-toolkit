# comfy-pipeline：ComfyUI 批量出图流水线

为 ComfyUI 提供统一的命令行入口与提示词生成能力，适用于批量生成与人工筛选的工作流。

## 文件说明

| 文件 | 作用 |
| --- | --- |
| `comfygen.py` | 出图主工具。支持 `--family flux\|illustrious\|anima`、`--batch`、`--prompt`、`--out`；输出为 TSV 格式（每张耗时与文件路径），便于上层批量筛选 |
| `promptbox.py` | 提示词生成器。依据角色档案与场景池（时间、天气、地点、氛围、光照、镜头、动作、神态）组合生成提示词 |
| `promptbox-pools.json` | 场景池数据。每条场景包含两套语法：`natural`（适用于自然语言模型）与 `tags`（适用于标签模型） |

## 使用方法

```bash
# 单张生成
python comfygen.py --family illustrious --prompt "1girl, ..." --out out/

# 批量生成（同一提示词多张，输出 TSV 便于筛选）
python comfygen.py --family anima --prompt-file p.txt --batch 8 --out out/test

# 按角色生成随机场景
python promptbox.py --character saya --count 10 --seed 42 --family illustrious
```

## 工程经验

1. **采样步数是影响质量的主要参数。** 在角色、场景、随机种子均相同的条件下，仅更换采样配置的结果差异显著：8 步配置的细节完整度明显低于 28 步配置（发丝、耳饰、纽扣等细节在高步数下才稳定出现）。快速低步数配置适用于流程验证，交付用途应使用常规质量配置。
2. **模型不具备先验知识的角色无法通过提示词可靠还原。** 在缺少 LoRA 的情况下，冷门角色的生成结果偏差较大。正确顺序是先解决「模型认识该角色」的问题（参考图 → 精确特征档案 → LoRA），再进行批量生成。
3. **部分 ComfyUI 版本需要禁用特定内存优化路径。** 参数 `--disable-pinned-memory` 与 `--disable-async-offload` 可规避该类版本中导致进程崩溃的问题，建议写入启动配置。

## 依赖

- 本仓库不包含模型权重，模型遵循各自许可，需自行获取；
- ComfyUI 本体、Python 3.10 及以上、`requests`。

## 许可

MIT。脚本为原创实现；模型与素材的许可需自行确认。
