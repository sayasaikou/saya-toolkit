# blender-headless：Blender 无头渲染脚本集

用于在命令行环境中执行 Blender 渲染与诊断任务的脚本集。脚本独立运行，不需要安装到 Blender 内部。

```powershell
$bl   = "$env:STEAM_HOME\steamapps\common\Blender\blender.exe"
$proj = "$env:DSH_WORKSPACE\<project>\<project>.blend"
```

## 脚本

| 脚本 | 作用 |
| --- | --- |
| `bl-rendersettings.py` | 读取或导出工程渲染设置（分辨率、采样、引擎、输出路径） |
| `bl-npr-preview.py` | 非真实感（NPR）预览渲染 |
| `bl-pbr-rebuild.py` | 重建 PBR 材质节点连接 |
| `bl-closeup.py` | 指定对象的近景渲染 |
| `vmd-length.py` | 读取 VMD 动作文件的帧长度 |
| 其余脚本 | 场景体检、对象统计、贴图路径检查等诊断用途 |

统一调用方式：

```powershell
& $bl -b "<工程路径>" -P "<脚本路径>" -- <脚本参数>
```

## 已验证的注意事项

1. **`-o` 参数必须位于 `-a` / `-f` 之前。** 写在之后会被忽略，渲染结果将输出到工程内保存的旧路径，且不产生任何报错。
2. **PowerShell 5.1 传参时，路径末尾的反斜杠会吞掉闭合引号**（例如 `-o "...\frames\"`）。表现为工程读取后直接退出、退出码为 0、不输出任何帧。应使用正斜杠或 `[IO.Path]::DirectorySeparatorChar` 构造路径。
3. **添加扩展时不要使用 `--factory-startup`。** 该参数会加载出厂设置，存在覆盖用户现有配置的风险。
4. **分辨率会影响效果判断。** 按像素扩散的效果在低分辨率下更模糊，最终质量判断应在目标分辨率下进行，不能以低分辨率试渲结果作为依据。

## 性能参考

无头渲染 4 个视角的耗时约为 5.3 秒（测试环境：独立显卡 16 GB 显存）。该数据用于评估批量渲染的可行性，实际耗时取决于场景复杂度与采样设置。

## 许可

MIT。Blender 及其扩展的版权归各自权利人所有。
