// The device advertises its supported schemas. These instructions tell the voice bot
// when to use the corresponding action in the current conversation.
export const peripheralVoiceDescriptions = new Map([
  [
    "pod_end_conversation",
    "用户向你告别、让你退下、休息或结束当前对话时必须调用此工具，让发话的 Pod 播放告别语并进入待机。按整句话判断，包括带口头语的命令和“今天就聊到这里吧”“回头再聊”等间接告别。用户否定、转述或讨论告别说法时继续正常交谈。设备自行播报告别。",
  ],
  [
    "pod_play_music",
    "这是 Pod 的唱歌和音乐播放功能。听到直接的表演或播放请求（例如“随便唱一首给我听呗”“想听点音乐”）必须调用此工具，让设备出声。指定了歌名就传 song，没有歌名直接用空对象 {} 调用，设备会随机选歌。不要用拟声词、歌词或口头承诺代替播放。讨论歌曲、查询歌词和拒绝播放时无需调用。",
  ],
]);
