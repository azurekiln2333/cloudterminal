# Implement — Herdr pane 输出保真

先读父任务 `10-13-herdr-mobile-render/design.md`，再读本目录 `design.md`。

## 前置检查

```powershell
cd D:\MyNewProjects\cloudterminal
Select-String -Path lib,test -Pattern "\.display\b" -Recurse
```

先拿到 `display` 的完整引用清单，再动手。

## 步骤

- [ ] **1. 复现问题**：在 `test/herdr_test.dart` 写一个临时断言，证明当前
      `HerdrOutput` 会丢掉行尾空白与结尾换行。确认失败后再改代码。

- [ ] **2. 改 `lib/models/herdr.dart`**
  - 移除 `display` 的 `RegExp(r'\s+$')` 改写
  - 引入 `isBlank`（基于 `text.trim().isEmpty`）
  - 按 `design.md` §1 决定 `display` / `isEmpty` 的最终形态
  - 给 `text` 补文档注释，说明"唯一真源，不得改写"

- [ ] **3. 迁移消费者**
  - `lib/screens/herdr_pane_screen.dart`：渲染处改用 `output.text`，
    空判断改用 `output.isBlank`
  - `test/herdr_test.dart`：更新 `trims the trailing newline` 用例为
    `preserves the trailing newline`；新增保真与 blank 用例

- [ ] **4. 刷新不清屏**（`design.md` §2）
  - 确认 `_load()` 不清空 `_output`
  - 新增"有内容时的细进度条"，与已有 `_sending` 进度条并列
  - 补 widget 测试：刷新中旧内容仍在

- [ ] **5. `HerdrScroll` 回看提示**（`design.md` §3）
  - 在 `_sourceBar` 与视口之间插入条件标签
  - 文案必须写明"电脑端"
  - 点击触发 `_load()`
  - 补 widget 测试覆盖 `>0` / `==0` / `null` 三种情况

- [ ] **6. 跑验证**

```powershell
flutter analyze
flutter test test/herdr_test.dart
flutter test
```

## 输出契约（交给子任务 2）

完成后必须明确记录：

1. `HerdrOutput` 的最终字段与方法（`text` / `isBlank` / 是否保留 `display`）
2. `herdr_pane_screen.dart` 中当前传入渲染的表达式是什么
3. 空状态判断用什么

这三条是子任务 2 设计视口输入的前提，写入本目录 `notes.md`。

## 回滚

改动限于 `lib/models/herdr.dart`、`lib/screens/herdr_pane_screen.dart`、
`test/herdr_test.dart`。回滚即恢复这三处。

## 完成标准

- `flutter analyze` 无警告
- `flutter test` 全部通过
- 保真断言（行尾空白 / 空行 / 结尾换行 / ANSI）存在且通过
- 回看提示三种情况的测试存在且通过
