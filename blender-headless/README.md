# blender-tools —— 本鱼给 Blender 活配的工具箱（2026-09-14 立）

都是**独立小脚本**，用命令行跑，不装进 Blender：

```powershell
$bl = '$env:STEAM_HOME\steamapps\common\Blender\blender.exe'
$proj = '$env:DSH_WORKSPACE\洛茜-庭中望月\洛茜-庭中望月-工程.blend'
```

| 脚本 | 干什么 | 用法要点 |
| --- | --- | --- |
| `bl-closeup.py` | **胸像特写相机 + 渲染**（临时相机，不保存进工程）——比材质/看脸必备 | `blender -b $proj --python bl-closeup.py -- <输出.png> [距离=1.9] [镜头=50]` |
| `bl-nodedump.py` | dump 指定材质的**完整节点图**（节点参数 + 连线）——查"线到底接没接上" | 直接 `--python`，结果看 `ND\|` 行 |
| `bl-lightdump.py` | dump 所有灯光/世界观/色彩管理（能量、位置、world strength） | `--python` |
| `bl-meter.py` | **测光表**：逐灯估算角色头/胸/胯三点的辐照度，判断"过曝几倍" | `--python`；经验值：PBR 角色总辐照度 ≈ 3 W/m² 才不过曝 |
| `bl-texstats.py` | 逐张贴图统计通道分布（min/mean/max/unique）——判 P/RS/RD/ST/M 用途 | 改脚本顶部的 `SRC` 路径 |
| `bl-texsheet.py` | 把一目录的贴图拼成**带文件名的总览图** | 改顶部 `SRC`/`OUT` |
| `bl-pbr-rebuild.py` | 把 MMD 材质（mmd_shader 卡通）**重建为 Principled PBR**（底色/法线/粗糙度/次表面） | 见文件顶部 `PARAMS` 表；**先备份工程** |
| `bl-dim-render.py` | 灯光整体乘一个系数后**两连拍**（MV 第 0 帧 + 特写），只在内存改 | `-- <前缀> <系数>` |
| `bl-npr-preview.py` | **材质路线单帧预览**：A 二次元（阶梯 Ramp）／ B 写实（平滑 + 高光 + AO + 边缘光）／ **C 灵动（= B 的细节机制 + 二次元高调光，皮肤几乎不打阴影）**；都用"归一化链路"顶住这套 MMD 灯阵的超曝光 | `-- A\|B\|C <输出前缀> [宽=3840] [高=2160]`；产物 `<前缀>-全景.png` + `<前缀>-特写.png`，**不保存工程**；排查开关 `PV_NOAO` / `PV_NOSPEC` / `PV_NORIM` |
| `png-montage.py` | 多图拼**带中文标签**的对比条（用微软雅黑，PIL 默认字体渲染不了中文） | `python png-montage.py <输出.png> "标签=路径" ...` |

## 踩过的坑（别再踩）

- **`bpy.ops.wm.save_as_mainfile()` 之前抛异常 = 白改**：脚本里任何一行报错都会让整轮修改作废（Blender 不会自动保存）。
- **`ShaderNodeNormalMap` 没有 `.image`**：要看它用的贴图得顺着 `inputs['Color'].links[0].from_node` 找。
- **mmd_tools 导入的模型 = 每个材质一个 `mmd_shader` 组**：材质输出接的是它，**另建的 Principled BSDF 默认是悬空的死节点**——改 Principled 的参数不会有任何效果（2026-09-14 踩过，见交接档案）。
- **本机 pwsh 里跑 Python 打印中文会乱码**（控制台 ANSI），但文件内容正常，别被吓到。
- **Blender 5 的 Material Output 节点没有 `Alpha` 输入**（老教程里的接法会报 `key "Alpha" not found`）→ 透明要用 **Mix Shader 混 Transparent BSDF**，Fac 接贴图的 Alpha。
- **"归一化链路"**（`BSDF → Shader to RGB → Map Range(0..K) → 用响应乘底色 → 自发光`）是在**不动场景灯光**的前提下给角色控制曝光的标准做法：这套 MMD 灯阵总辐照度 ≈39 W/m²，K 取 12.4（≈39/π）刚好把漫反射归一到 0~1。
- ⚠️ **写实路线（B）别把 Ramp 暗部压太低**：这个角色的脸**天生就在阴影里**（兜帽 + 刘海 + MMD 的 `发影`/`目影` 半透明面片），暗部压到 0.10 会渲出**一张黑脸**（2026-09-14 实际翻车，用户一眼就看出来了）；实测**暗部抬到 0.24 + 中段 0.58**（皮肤用暖色 0.34/0.26/0.23）才正常。
- ⚠️ **高光是最容易"发白雾"的一项**：`高粗糙度 + 偏大的高光强度` = 一层白纱糊在角色上（红斗篷会变粉白）。判据用**数值**别看眼睛：量脸部区域均值，2026-09-14 实测 旧=78.6 → 糊版=91.9（+17%）→ **把高光收到 头发 0.35@rough0.20、布料 0.08@rough0.62、皮肤 0** 之后回到 79.3 ✓。
- **AO 很便宜但很弱**：`AmbientOcclusion(距离 0.06) → MapRange(0→0.40, 1→1.0)` 乘到着色上；实测对整体亮度几乎没影响（+1.5 以内），想要缝隙细节就继续压 `To Min`。
- **低分辨率试渲会骗人**：合成器里的 `FogGlow` 是按像素扩散的 → 1080p 的雾光比 4K 大一倍，**看起来更糊更白**；定稿判断一律用 4K（或至少同分辨率对比）。
