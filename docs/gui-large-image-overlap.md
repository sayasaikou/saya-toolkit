# 前端大图遮挡文字：一个没结案的定位过程

> 对象：Electron 应用内的 Markdown 消息流。现象：消息里的图片会盖住它下面的文字，窗口化与全屏都复现，resize 后不消失。
> 状态：**未定案**。本文只记录已经排除的假设和可复用的定位手法，不冒充结论。

## 一、先做减法：图片到底有没有尺寸约束

第一步不是看布局，是确认图片是不是「无约束撑爆容器」。

```js
const img = document.querySelector('img.inline-img');
img.getBoundingClientRect();
getComputedStyle(img).maxWidth;   // 期望有值
```

本案实测：图片有 `max-width: min(100%, 560px)`、`max-height: 420px`、`display: block`、`object-fit: contain`，是正常流内元素。

⇒ 排除「图片没约束把自己撑出容器」。

## 二、再看承载链

逐层取父元素的 `overflow` / `position` / `height`：

```js
let el = img;
while (el && el !== document.body) {
  const cs = getComputedStyle(el);
  console.log(el.className, cs.position, cs.overflow, cs.height, el.getBoundingClientRect().height);
  el = el.parentElement;
}
```

本案实测：Markdown 容器 `min-width: 0; overflow-wrap: anywhere`，无 `overflow` 限制；附件缩略图组件才有 `height: 180px; overflow: hidden`，与消息内大图不是同一组件。

⇒ 排除「容器把块截断」。

## 三、还排除了什么

| 假设 | 判据 | 结果 |
| --- | --- | --- |
| 虚拟列表高度估算错误 | resize 后重排仍复现 | 排除 |
| 全局 `img` 规则干扰 | 全量 CSS 里只有 katex 的图规则 | 排除 |
| 图片脱流（`position: absolute`） | 计算样式为 static | 排除 |
| 缓存导致的旧样式 | 强刷 + 重启后仍复现 | 排除 |

## 四、下一步该量的两个数

现在缺的不是假设，是数据：

1. **图片的 `getBoundingClientRect().height`**（实际渲染高度）；
2. **父级消息气泡的 `offsetHeight`**（占位高度）。

两者不相等 ⇒ 是「渲染高度没被计入布局」，往 `contain`、`transform`、`will-change` 方向查。
两者相等但文字仍被盖 ⇒ 是层叠顺序问题（`z-index` / 定位上下文），往堆叠方向查。

## 五、可复用的判断顺序

1. 先看元素本身有没有尺寸约束，别一上来读布局代码；
2. 再看承载链的 `overflow` / `height` / `position`，逐层取实际矩形；
3. 再排除全局样式与缓存；
4. 最后才是「渲染高度 vs 占位高度」这一对核心数字。

这个顺序能避免最常见的浪费：花两小时读框架布局算法，最后发现是某条 `height: 180px` 的组件规则串到了消息流上。
