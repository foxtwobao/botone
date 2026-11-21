import { ProbeCard } from '../spike/probe-card';

@Entry
@ComponentV2
struct Index {
  build() {
    Column() {
      ProbeCard()
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }
}
