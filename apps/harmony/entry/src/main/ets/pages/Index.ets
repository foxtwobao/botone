@Entry
@Component
struct Index {
  build() {
    Column() {
      Text('BotONE')
        .fontSize(20)
        .fontColor($r('sys.color.ohos_id_color_text_primary'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }
}
