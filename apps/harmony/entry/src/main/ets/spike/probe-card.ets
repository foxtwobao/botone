// S1 probe: the minimal V2-state component (@ComponentV2 + @Local) the design mandates.
// It is also the M0 shell's only content.

@ComponentV2
export struct ProbeCard {
  @Local label: string = 'BotONE';

  build() {
    Text(this.label)
      .fontSize(20)
      .fontColor($r('sys.color.ohos_id_color_text_primary'))
  }
}
