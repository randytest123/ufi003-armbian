# build-armbian-ufi003.yml 修复说明

## 改了什么（三句话总结）

1. **消灭了所有 heredoc 顶格导致的 YAML 解析失败**：`run: |` 块里的 `sudo tee ... << EXT` 和 `<< FSTAB` 改成了 `printf '%s\n' ... | sudo tee`，extlinux.conf / etc/fstab 内容由 printf 精确输出（保留 lk2nd 需要的无多余缩进的原文）。
2. **修跨 job 产物传递**：`build-armbian` job 新增 `outputs:` block 暴露 `exit_code`，并新增步骤上传完整 Armbian build output（rootfs.img* + compile.log）为 artifact；`assemble` job 用 `actions/download-artifact` 匹配下载。`Find_and_decompress_Armbian_img` 步骤加了 `id: decompress`，后续 `${{ steps.decompress.outputs.ROOTFS }}` 正确引用。
3. **顺手修了 ARMHIAN→ARMBIAN 拼写、清理无用步骤、PR 触发时 prepare 外全跳过**。

## 用户下一步

1. 打开 GitHub 上那个仓库（run 41578076177 失败的那个）
2. 进入 `.github/workflows/build-armbian-ufi003.yml` → 点铅笔图标编辑
3. **全选 → 粘贴下面这份完整 yml 覆盖**（也在本目录下）
4. Commit message 随便写 → 点 **Commit changes**
5. 自动触发一次（push event），或者手动 Actions → Run workflow → Run

## 已知仍可能挂的点（提前预警）

| 点 | 概率 | 说明 |
|----|------|------|
| kernel patch apply 冲突 | **高** (~80%) | prepare job 会提前检测。冲突了就看 prepare job 的日志，手动改 patch 里的 modem.dtsi include 位置，或走路线 B (dtc 直接编 DTS) |
| runner 7GB RAM make -j2 OOM | 低 | 改 env MAKEFLAGS="-j1" 重试 |
| rootfs.img 1GB < artifact 2GB 限制 | 不影响 | 全 OK |
| WiFi firmware 不在 rootfs 里 | 必然 | 刷机后手动从 D 盘复制 wcnss.* 到 /lib/firmware/qcom/ |
