@Entry
@Component
struct Index {
  build() {
    Column() {
      Text('Tests')
        .fontSize(20)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }
}
