# AI 协作规则

- iOS 端使用 [ios-ci-workflows](https://github.com/wenjinliuu/ios-ci-workflows) 编译和测试；本地不跑 Xcode。改完 `ios/` 代码并 push，读 Build & Test 的测试报告再修。
- 服务端 `bridge/` 与 `worker/` 为 TypeScript（Node.js 24），改动前需通过 `npm run check`（`tsc --noEmit` + `node --test`）。
- 仓库为公开仓库（Public）：严禁在代码、配置、日志或工作流中提交任何真实密钥、Token、私有域名、`.workers.dev` 实例地址、Team ID 硬编码或对话记录。
- 新功能必须带测试；能用逻辑测试验证的不写成 UI 测试；UI 测试按条件等待，不用固定 `sleep`。
- 删测试或改断言预期值必须在提交说明里写明理由。
- 更多 iOS CI 规范见 `wenjinliuu/ios-ci-workflows` 的 `skills/ios-ci-workflows/SKILL.md`。
