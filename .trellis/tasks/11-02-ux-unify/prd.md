# 统一信息架构与导航骨架(再统一视觉)
前置:`account-auth`、`pairing-simplify`(页面集合确定后再做)。
## Requirements
- 手机端单一导航骨架:底部导航 电脑 / 会话 / 设置;未登录只是“电脑”页的空状态,不再是另一套页面
- 会话、herdr、终端、codex 在同一骨架内跳转,返回路径一致,去掉嵌套 Navigator 的特例
- Windows 端:总览合并登录状态与电脑,配对并入“添加设备”,去掉独立配对页
- 两端共享设计 token(色板、圆角、间距、字号、mono 栈),单一来源
- 统一空状态、加载、错误提示的样式与文案
## Acceptance Criteria
- [ ] 任一页面到任一功能不超过 2 次点击
- [ ] 两端主题 / 组件无重复定义
- [ ] `flutter analyze` 与 widget 测试通过;并排截图确认
