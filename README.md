# pz-nev-mods

新能源车（NEV）系列《僵尸毁灭工程》（Project Zomboid，Build 42）mod 的源代码。
Source code of the NEV (new-energy vehicle) mods for Project Zomboid (Build 42).

[中文](#中文) · [English](#english)

## 中文

### 这是什么
这里放的是下面几个 mod 每次正式发布时的代码快照：

| mod | 版本 | 创意工坊 |
|---|---|---|
| NEV Lib（核心库，其他车型都依赖它） | 1.5.0 | https://steamcommunity.com/sharedfiles/filedetails/?id=3818326067 |
| 理想 L6（NEV - Li Auto L6） | 1.5.0 | https://steamcommunity.com/sharedfiles/filedetails/?id=3818327486 |
| 特斯拉 Cybertruck（NEV - Tesla Cybertruck） | 1.1.0 | https://steamcommunity.com/sharedfiles/filedetails/?id=3823960349 |

每发布一版，这里就多一个提交，并打上和 mod 版本同名的 tag（例如 `NEVLib-v1.5.0`）。开发不在这个仓库里做，所以这里没有日常的提交历史。

### 这里没有的
- **没有美术文件**：模型、贴图、图标、界面图都不在这里，只用这个仓库拼不出能玩的 mod。**完整的 mod 请从创意工坊订阅。**
- 代码注释里提到的设计文档、测试和工具（例如「DESIGN 5.4」）不公开；注释里的 `#123` 这类编号是我们内部的问题编号，不是这个仓库的 issue。

### 协议
- **代码**（Lua、游戏脚本、翻译、mod.info）：Mozilla Public License 2.0，见 [LICENSE](LICENSE)。可以使用、修改、放进你自己的 mod（包括商用）；改过的我们的文件要同样以 MPL-2.0 公开。
- **美术**：作者保留所有权利，见 [LICENSE-ART.md](LICENSE-ART.md)。可以在游戏里用、录视频截图（可以盈利）、在合集里链接我们的条目；不允许把模型、贴图、图标或整个 mod 重新上传或放进整合包。欢迎做皮肤 / 痛车附加 mod，条件见 LICENSE-ART.md。
- 从游戏本体来的部分归 The Indie Stone，不在上面两份许可之内，见 [NOTICE.md](NOTICE.md)。
- 与任何汽车厂商无关，车名只用来指明参照的真车。

### 修改版和官方版本
- **对修改版的请求**：协议（MPL-2.0）要求改过的我们的文件继续以 MPL-2.0 公开源代码。除此之外，我们**请求**（协议不强制）：发布修改版时，请注明它基于本作（附上本仓库或创意工坊的链接），并标出改动之处，例如在改过的文件开头写一行说明，或者附一份改动清单。这样万一某个修改版出了问题、甚至带了恶意代码，大家也能分清问题是不是出自原版。
- **怎么认官方版本**：官方版本以创意工坊上的官方条目（上面表格里的链接）和本仓库的 tag 为准。每一版的根目录都有 `SHA256SUMS.txt`，列出这一版每个文件的 SHA-256，可以拿来核对手里的文件是不是官方原样，例如在本仓库的 clone 里运行 `sha256sum -c SHA256SUMS.txt`；创意工坊下载的 mod 文件夹里的代码文件，对应本仓库同名 mod 文件夹下同一路径的那一行。

### 反馈问题
- 欢迎在 [Issues](https://github.com/PTAbabybearR/pz-nev-mods/issues) 报 bug、提建议、提翻译意见。报 bug 请写：mod 版本、游戏版本、单机还是联机、怎么复现，附上 `console.txt` 里的报错。
- **不接受 Pull Request**：开发在别处进行，外部代码合不进来。想改什么请开 issue 说明，我们会排进后面的版本。
- 也可以在创意工坊页面留言。

### 更新日志
按 mod 分开，见 [CHANGELOG](CHANGELOG) 目录。

## English

### What this is
Release snapshots of the code of these mods:

| Mod | Version | Steam Workshop |
|---|---|---|
| NEV Lib (core library, every car needs it) | 1.5.0 | https://steamcommunity.com/sharedfiles/filedetails/?id=3818326067 |
| NEV - Li Auto L6 | 1.5.0 | https://steamcommunity.com/sharedfiles/filedetails/?id=3818327486 |
| NEV - Tesla Cybertruck | 1.1.0 | https://steamcommunity.com/sharedfiles/filedetails/?id=3823960349 |

Every release adds one commit here, tagged with the mod's version (for example `NEVLib-v1.5.0`). Development happens elsewhere, so there is no day-to-day history in this repository.

### What is not here
- **No art**: models, textures, icons and interface images are not in this repository, so it cannot be built into a playable mod on its own. **Subscribe on the Steam Workshop for the complete mods.**
- The design documents, tests and tools that code comments refer to (such as "DESIGN 5.4") are not public, and numbers like `#123` in comments are our internal issue numbers, not issues of this repository.

### Licences
- **Code** (Lua, game scripts, translations, mod.info): Mozilla Public License 2.0, see [LICENSE](LICENSE). You may use it, change it and put it into your own mods (commercial use included); files of ours that you change must stay under MPL-2.0 and be published.
- **Art**: all rights reserved, see [LICENSE-ART.md](LICENSE-ART.md). You may use it in the game, make videos and screenshots (and earn money with them) and link our items in collections; you may not re-upload the models, textures, icons or the mods, or ship them in a modpack. Skin / livery add-ons are welcome under the conditions in LICENSE-ART.md.
- Parts that come from the game itself remain The Indie Stone's and are covered by neither licence, see [NOTICE.md](NOTICE.md).
- Not affiliated with any vehicle manufacturer; vehicle names only identify the real vehicles the mods are modelled after.

### Modified versions and the official version
- **A request for modified versions**: the licence (MPL-2.0) requires files of ours that you change to stay under MPL-2.0 with their source published. Beyond that, we **ask** (the licence does not require it): when you publish a modified version, please say that it is based on this work (with a link to this repository or the Workshop items) and mark what you changed, for example with a line at the top of each changed file or a list of changes. Then, should a modified version have a problem or even malicious code, everyone can tell whether it comes from the original.
- **How to recognise the official version**: the official version is what the official Workshop items (linked in the table above) and the tags of this repository carry. Every release has `SHA256SUMS.txt` in the root folder with the SHA-256 of each of its files, so you can check whether a file you have is the official one, for example with `sha256sum -c SHA256SUMS.txt` in a clone of this repository; a code file in a mod folder downloaded from the Workshop corresponds to the line with the same path under that mod's folder here.

### Reporting problems
- Bug reports, suggestions and translation feedback are welcome in [Issues](https://github.com/PTAbabybearR/pz-nev-mods/issues). For a bug, please give the mod version, the game version, single player or multiplayer, the steps to reproduce it and the error from `console.txt`.
- **Pull requests are not accepted**: development happens elsewhere and outside code cannot be merged back. Please open an issue describing the change instead; we will plan it into a later release.
- Comments on the Workshop pages work too.

### Change logs
One per mod, in the [CHANGELOG](CHANGELOG) folder (in Chinese).
